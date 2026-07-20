import AppKit
import SwiftUI

@MainActor
final class SessionModel: ObservableObject {
    enum Phase {
        case composing   // 组稿：还没有任何结果
        case reviewing   // 审阅：有结果，可继续纠偏
    }

    @Published var phase: Phase = .composing
    @Published var isLoading = false
    @Published var draft = ""
    @Published var feedback = ""
    @Published var currentResult = ""
    @Published var statusText = ""
    @Published var errorMessage: String?
    /// 变化时对应编辑框抢焦点（0 表示不抢）
    @Published var focusToken = 0
    @Published var isRecording = false
    /// 输出语言开关：false 保持原文语言，true 输出英文（记住上次选择）
    @Published var outputEnglish = UserDefaults.standard.bool(forKey: "outputEnglish") {
        didSet { UserDefaults.standard.set(outputEnglish, forKey: "outputEnglish") }
    }

    private(set) var version = 0
    /// 已提交成功的完整对话（system + input + 每轮 feedback/assistant）
    private var messages: [ChatMessage] = []
    private var task: Task<Void, Never>?
    private var focusCounter = 0
    private let speech = SpeechRecorder()
    /// 听写开始时输入框里已有的文字，识别结果追加在其后
    private var dictationBase = ""

    var onRequestClose: (() -> Void)?
    /// 关窗并自动粘贴回原应用
    var onRequestCloseAndPaste: (() -> Void)?
    /// 润色成功即自动贴回；replacePrevious 为 true 时先 ⌘Z 撤销上次粘贴
    var onAutoPaste: ((_ replacePrevious: Bool) -> Void)?
    /// 本会话是否已经自动粘贴过（决定下次是否先撤销）
    private var hasAutoPasted = false

    init() {
        speech.onStateChange = { [weak self] recording in
            self?.isRecording = recording
        }
        speech.onError = { [weak self] message in
            self?.errorMessage = message
        }
        speech.onPartial = { [weak self] text in
            guard let self else { return }
            let combined = self.dictationBase + text
            if self.phase == .composing {
                self.draft = combined
            } else {
                self.feedback = combined
            }
        }
    }

    // MARK: - Dictation

    func toggleDictation() {
        if isRecording {
            speech.stop()
            return
        }
        guard !isLoading else { return }
        errorMessage = nil
        dictationBase = phase == .composing ? draft : feedback
        let localeId = ConfigStore.loadRaw()?.speechLocale ?? "zh-CN"
        speech.start(localeId: localeId)
    }

    func stopDictation() {
        speech.stop()
    }

    func bumpFocus() {
        focusCounter += 1
        focusToken = focusCounter
    }

    /// 界面文案随 中/EN 开关切换
    func t(_ zh: String, _ en: String) -> String {
        outputEnglish ? en : zh
    }

    /// 关闭按钮：无条件收尾并关窗
    func forceClose() {
        stopDictation()
        task?.cancel()
        task = nil
        isLoading = false
        onRequestClose?()
    }

    // MARK: - Actions

    func submitDraft() {
        guard !isLoading else { return }
        stopDictation()
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            errorMessage = t("请输入内容", "Please enter some text")
            return
        }
        let config: AppConfig
        do {
            config = try ConfigStore.load()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let requestMessages = [
            ChatMessage(role: "system", content: systemContent(config)),
            ChatMessage(role: "user", content: "<input>\n\(input)\n</input>"),
        ]
        run(requestMessages: requestMessages, config: config)
    }

    private func systemContent(_ config: AppConfig) -> String {
        config.resolvedSystemPrompt(english: outputEnglish)
    }

    /// 满意收工：关窗并把结果粘贴回原应用（结果已在剪贴板）
    func requestCloseAndPaste() {
        guard !currentResult.isEmpty else {
            onRequestClose?()
            return
        }
        // 极速模式下结果已经贴回去了，空 Enter 只需关窗
        if hasAutoPasted {
            onRequestClose?()
            return
        }
        if ConfigStore.loadRaw()?.autoPaste ?? true {
            onRequestCloseAndPaste?()
        } else {
            onRequestClose?()
        }
    }

    func submitFeedback() {
        guard !isLoading, phase == .reviewing else { return }
        stopDictation()
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空反馈按 Enter = 对结果满意，直接贴回原应用
        guard !note.isEmpty else {
            requestCloseAndPaste()
            return
        }
        let config: AppConfig
        do {
            config = try ConfigStore.load()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // 失败时不污染已有会话：本轮消息成功后才提交进 messages
        // 系统消息按当前语言开关重建，中途切换 中/EN 也能即时生效
        var base = messages
        if let first = base.first, first.role == "system" {
            base[0] = ChatMessage(role: "system", content: systemContent(config))
        }
        let requestMessages = base + [
            ChatMessage(role: "user", content: "<feedback>\n\(note)\n</feedback>")
        ]
        run(requestMessages: requestMessages, config: config)
    }

    private func run(requestMessages: [ChatMessage], config: AppConfig) {
        isLoading = true
        errorMessage = nil
        statusText = t("润色中…（Esc 取消）", "Polishing… (Esc to cancel)")
        task = Task { [weak self] in
            do {
                let output = try await LLMClient.complete(messages: requestMessages, config: config)
                guard !Task.isCancelled else { return }
                self?.handleSuccess(output: output, requestMessages: requestMessages)
            } catch is CancellationError {
                // 用户主动取消，静默返回
            } catch {
                guard !Task.isCancelled else { return }
                self?.handleFailure(error)
            }
        }
    }

    private func handleSuccess(output: String, requestMessages: [ChatMessage]) {
        let previousLength = currentResult.count
        version += 1
        messages = requestMessages + [ChatMessage(role: "assistant", content: output)]
        currentResult = output

        // 疑似不完整输出检测：新版明显短于上一版时提醒（不拦截）
        var warning = ""
        if version > 1, output.count * 10 < previousLength * 3 {
            warning = t("（比上一版短很多，请检查是否完整）",
                        " (much shorter than the last version — check completeness)")
        }

        copyToClipboard(output)
        statusText = t("✅ v\(version) 已复制到剪贴板", "✅ v\(version) copied to clipboard") + warning
        feedback = ""
        isLoading = false
        phase = .reviewing

        if ConfigStore.loadRaw()?.autoPaste ?? true {
            // 极速模式：出结果直接贴回原应用；纠偏轮次先撤销上一版再贴
            let replacePrevious = hasAutoPasted
            hasAutoPasted = true
            onAutoPaste?(replacePrevious)
        } else {
            bumpFocus()
        }
    }

    private func handleFailure(_ error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
        statusText = version > 0
            ? t("✅ v\(version) 仍在剪贴板中", "✅ v\(version) still on clipboard")
            : ""
    }

    func cancelRequest() {
        task?.cancel()
        task = nil
        isLoading = false
        statusText = version > 0
            ? t("已取消，剪贴板仍是 v\(version)", "Cancelled — clipboard still has v\(version)")
            : t("已取消", "Cancelled")
    }

    /// Esc：听写中先停止听写；请求中先取消请求；否则关窗
    func handleEscape() {
        if isRecording {
            stopDictation()
        } else if isLoading {
            cancelRequest()
        } else {
            onRequestClose?()
        }
    }

    /// ⌘N 重新开始
    func resetSession() {
        stopDictation()
        task?.cancel()
        task = nil
        phase = .composing
        isLoading = false
        draft = ""
        feedback = ""
        currentResult = ""
        statusText = ""
        errorMessage = nil
        version = 0
        messages = []
        hasAutoPasted = false
        bumpFocus()
    }

    func copyOriginal() {
        copyToClipboard(draft)
        statusText = t("已复制原文（未润色）", "Original copied (unpolished)")
        errorMessage = nil
    }

    func copyResultAgain() {
        guard !currentResult.isEmpty else { return }
        copyToClipboard(currentResult)
        statusText = t("✅ v\(version) 已复制到剪贴板", "✅ v\(version) copied to clipboard")
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
