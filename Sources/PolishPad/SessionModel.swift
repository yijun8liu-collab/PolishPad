import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let polishPadThemeChanged = Notification.Name("PolishPad.themeChanged")
    static let polishPadLanguageChanged = Notification.Name("PolishPad.languageChanged")
    static let polishPadPanelSizeChanged = Notification.Name("PolishPad.panelSizeChanged")
}

/// 面板尺寸：UserDefaults 记忆（拖拽调整或设置预设都会更新）
enum PanelSize {
    static let presets: [(name: String, w: CGFloat, h: CGFloat)] = [
        ("small", 560, 340), ("medium", 680, 400), ("large", 820, 500),
    ]
    static var current: NSSize {
        let w = UserDefaults.standard.double(forKey: "panelWidth")
        let h = UserDefaults.standard.double(forKey: "panelHeight")
        return NSSize(width: w > 0 ? w : 680, height: h > 0 ? h : 400)
    }
    static func store(_ size: NSSize) {
        UserDefaults.standard.set(Double(size.width), forKey: "panelWidth")
        UserDefaults.standard.set(Double(size.height), forKey: "panelHeight")
    }
}

@MainActor
final class SessionModel: ObservableObject {
    enum Phase {
        case composing   // 组稿：还没有任何结果
        case reviewing   // 审阅：有结果，可继续纠偏
    }

    enum FeedbackMode {
        case append   // 追加：输入的是新内容，优化后并入全文（默认）
        case revise   // 修改：输入的是对当前版本的修改意见
    }

    @Published var phase: Phase = .composing
    @Published var feedbackMode: FeedbackMode = .append
    @Published var isLoading = false
    @Published var draft = ""
    @Published var feedback = ""
    @Published var currentResult = ""
    @Published var statusText = ""
    @Published var errorMessage: String?
    /// 变化时对应编辑框抢焦点（0 表示不抢）
    @Published var focusToken = 0
    @Published var isRecording = false
    /// 本会话使用的场景预设（底栏可随手切换）
    @Published var activeScenario: Scenario = .builtin(.polish)
    /// 用户自定义场景列表（供面板菜单显示；设置保存后刷新）
    @Published var customScenarios: [CustomScenario] = []
    /// 应用感知自动选择的提示（手动切换后清除）
    @Published var autoPresetNote: String?
    /// 当前显示第几版（1-based）
    @Published var shownVersion = 0
    /// 改动对比视图开关
    @Published var showDiff = false
    /// 本轮已发出请求但首个流式块还没到（骨架占位/旧文变暗的依据）
    @Published var awaitingFirstChunk = false
    /// 面板是否可见（由 PanelController 维护）：粒子层只在可见时渲染，
    /// 否则 TimelineView 在隐藏窗口里空转耗电
    @Published var panelVisible = false
    /// 本轮蜕变动画的旧文字（首轮=草稿，纠偏轮=上一版结果）
    @Published var morphSource = ""
    /// 一句话生成场景：创建器开关 / 描述 / 生成中
    @Published var showScenarioCreator = false
    @Published var scenarioDescription = ""
    @Published var isGeneratingScenario = false
    /// 输出语言开关：false 保持原文语言，true 输出英文（记住上次选择）
    @Published var outputEnglish = UserDefaults.standard.bool(forKey: "outputEnglish") {
        didSet {
            UserDefaults.standard.set(outputEnglish, forKey: "outputEnglish")
            NotificationCenter.default.post(name: .polishPadLanguageChanged, object: nil)
        }
    }
    /// 明亮主题开关（默认暗色玻璃；记住上次选择，面板/HUD/设置窗一起跟随）
    @Published var lightTheme = UserDefaults.standard.bool(forKey: "lightTheme") {
        didSet {
            UserDefaults.standard.set(lightTheme, forKey: "lightTheme")
            NotificationCenter.default.post(name: .polishPadThemeChanged, object: nil)
        }
    }

    /// 会话内全部版本
    private(set) var versions: [String] = []
    var version: Int { versions.count }
    /// 已提交成功的完整对话（system + input + 每轮 feedback/assistant）
    private var messages: [ChatMessage] = []
    private var task: Task<Void, Never>?

    /// 停顿预取：组稿停顿 2s 且成句时后台静默跑一轮；回车时输入与
    /// 提示词都精确匹配才命中（改过字/切过场景或语言自动作废）
    private struct Prefetch {
        let input: String
        let system: String
        let output: String
        let requestMessages: [ChatMessage]
    }
    private var prefetchCache: Prefetch?
    private var prefetchTask: Task<Void, Never>?
    private var draftDebounce: AnyCancellable?
    private var focusCounter = 0
    private let speech = SpeechRecorder()
    /// 听写开始时输入框里已有的文字，识别结果追加在其后
    private var dictationBase = ""
    private var sessionID = UUID()

    var onRequestClose: (() -> Void)?
    /// 关窗并自动粘贴回原应用
    var onRequestCloseAndPaste: (() -> Void)?
    /// 已粘贴过的会话收工：由 PanelController 判断显示版本是否与已贴入
    /// 版本一致——用户回退过版本时，先原地替换成当前显示版再关窗
    var onCloseWithShownVersion: (() -> Void)?
    /// 优化成功即自动贴回；replacePrevious 为 true 时先删除上一次粘贴
    var onAutoPaste: ((_ replacePrevious: Bool) -> Void)?
    /// 本会话是否已经自动粘贴过（决定下次是否先删除）
    private var hasAutoPasted = false

    init() {
        speech.onStateChange = { [weak self] recording in
            self?.isRecording = recording
        }
        speech.onError = { [weak self] message in
            self?.errorMessage = message
        }
        // 设置保存后刷新用户场景列表（面板开着时菜单同步最新）；
        // 当前选中的场景被删除时回退到配置的默认场景
        NotificationCenter.default.addObserver(
            forName: .polishPadSettingsSaved, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.customScenarios = ConfigStore.loadRaw()?.customScenarios ?? []
                if case let .user(id) = self.activeScenario,
                   !self.customScenarios.contains(where: { $0.id == id }) {
                    self.activeScenario = Scenario.from(
                        key: ConfigStore.loadRaw()?.promptPreset ?? "polish",
                        in: self.customScenarios)
                }
            }
        }
        // 设置窗口里的语言开关与面板开关是同一份状态：外部改动时跟随
        NotificationCenter.default.addObserver(
            forName: .polishPadLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let value = UserDefaults.standard.bool(forKey: "outputEnglish")
                if value != self.outputEnglish { self.outputEnglish = value }
            }
        }
        draftDebounce = $draft
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.maybePrefetch() }
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

    // MARK: - Preset

    /// 手动切换场景（清除自动选择提示）。
    /// 审阅态下切换 = 把当前文本按新场景重新生成一版——否则新场景
    /// 对已有文本毫无作用（追加/修改轮次都以旧文本为锚）
    func selectScenario(_ scenario: Scenario) {
        let previous = activeScenario
        activeScenario = scenario
        autoPresetNote = nil
        guard scenario != previous, phase == .reviewing,
              !currentResult.isEmpty, !isLoading else { return }
        reRenderCurrentResult()
    }

    /// 用当前场景把当前文本重新生成（开启全新对话链，保留版本历史可回退）
    private func reRenderCurrentResult() {
        let config: AppConfig
        do {
            config = try ConfigStore.load()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let requestMessages = [
            ChatMessage(role: "system", content: systemContent(config)),
            ChatMessage(role: "user", content: "<input>\n\(currentResult)\n</input>"),
        ]
        run(requestMessages: requestMessages, config: config)
    }

    /// 应用感知：唤起时按前台应用自动选场景（内置或用户场景均可）
    func applyAutoPreset(bundleID: String?, appName: String?) {
        guard let bundleID,
              let mapping = ConfigStore.loadRaw()?.appPresets,
              let raw = mapping[bundleID] else { return }
        activeScenario = Scenario.from(key: raw, in: customScenarios)
        let name = appName ?? bundleID
        autoPresetNote = t("已按 \(name) 自动选择", "Auto-selected for \(name)")
    }

    /// 一句话生成场景：成功后立即选用
    func generateScenario() {
        let description = scenarioDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, !isGeneratingScenario else { return }
        isGeneratingScenario = true
        HUD.shared.showWorking(t("场景生成中…", "Generating scenario…"))
        Task { [weak self] in
            defer { self?.isGeneratingScenario = false }
            do {
                let scenario = try await ScenarioGenerator.generateAndSave(description)
                guard let self else { return }
                self.customScenarios = ConfigStore.loadRaw()?.customScenarios
                    ?? self.customScenarios
                self.activeScenario = .user(scenario.id)
                self.showScenarioCreator = false
                self.scenarioDescription = ""
                self.autoPresetNote = nil
                let shownName = self.scenarioName(.user(scenario.id))
                self.statusText = self.t("场景「\(shownName)」已创建并选用",
                                         "Scenario \"\(shownName)\" created & selected")
                HUD.shared.flashSuccess(self.t("场景已创建", "Scenario created"))
            } catch {
                HUD.shared.hide()
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// 当前场景的显示名
    func scenarioName(_ scenario: Scenario) -> String {
        switch scenario {
        case .builtin(let preset):
            return t(preset.labelZH, preset.labelEN)
        case .user(let id):
            guard let scenario = customScenarios.first(where: { $0.id == id }) else {
                return t("未命名场景", "Unnamed")
            }
            return outputEnglish ? (scenario.nameEN ?? scenario.name) : scenario.name
        }
    }

    // MARK: - 停顿预取

    private func maybePrefetch() {
        guard ConfigStore.loadRaw()?.idlePrefetch ?? true else { return }
        guard phase == .composing, !isLoading else { return }
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.count >= 8 else { return }
        guard input != prefetchCache?.input else { return }
        guard let config = try? ConfigStore.load() else { return }
        let system = systemContent(config)
        let requestMessages = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: "<input>\n\(input)\n</input>"),
        ]
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let output = try? await LLMClient.completeStreaming(
                messages: requestMessages, config: config, onPartial: nil
            ) else { return }
            guard !Task.isCancelled, let self else { return }
            self.prefetchCache = Prefetch(
                input: input, system: system,
                output: output, requestMessages: requestMessages)
        }
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
        // 停顿预取命中：输入与提示词都未变，直接采用缓存结果（秒出）
        if let cached = prefetchCache, cached.input == input,
           cached.system == systemContent(config) {
            prefetchCache = nil
            if phase == .composing { phase = .reviewing }
            handleSuccess(output: cached.output,
                          requestMessages: cached.requestMessages)
            statusText += " ⚡"
            return
        }
        let requestMessages = [
            ChatMessage(role: "system", content: systemContent(config)),
            ChatMessage(role: "user", content: "<input>\n\(input)\n</input>"),
        ]
        run(requestMessages: requestMessages, config: config)
    }

    private func systemContent(_ config: AppConfig) -> String {
        config.resolvedSystemPrompt(english: outputEnglish, scenario: activeScenario)
    }

    /// 自动粘贴未能执行（目标应用没激活/权限缺失）：回滚"已粘贴"标记，
    /// 否则空回车会按"已粘贴过→仅关窗"处理，用户以为完成了其实什么都没贴
    func autoPasteFailed() {
        hasAutoPasted = false
    }

    /// 满意收工：关窗并把结果粘贴回原应用（结果已在剪贴板）
    func requestCloseAndPaste() {
        guard !currentResult.isEmpty else {
            onRequestClose?()
            return
        }
        // 极速模式下结果已经贴回去了；但用户可能 ⌘[ 回退过版本——
        // 收工前由控制器校准目标内容为当前显示的版本
        if hasAutoPasted {
            (onCloseWithShownVersion ?? onRequestClose)?()
            return
        }
        if ConfigStore.loadRaw()?.autoPaste ?? true {
            onRequestCloseAndPaste?()
        } else {
            onRequestClose?()
        }
    }

    func submitFeedback() {
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空反馈按 Enter = 对结果满意，直接贴回原应用
        guard !note.isEmpty else {
            guard !isLoading, phase == .reviewing else { return }
            requestCloseAndPaste()
            return
        }
        let tag = feedbackMode == .append ? "append" : "feedback"
        sendFeedback(note: note, tag: tag)
    }

    /// 快捷反馈 chips：固定按「修改」语义发送
    func sendQuickFeedback(_ note: String) {
        sendFeedback(note: note, tag: "feedback")
    }

    private func sendFeedback(note: String, tag: String) {
        guard !isLoading, phase == .reviewing else { return }
        stopDictation()
        let config: AppConfig
        do {
            config = try ConfigStore.load()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // 失败时不污染已有会话：本轮消息成功后才提交进 messages
        // 系统消息按当前语言/场景重建，中途切换也即时生效
        var base = messages
        if let first = base.first, first.role == "system" {
            base[0] = ChatMessage(role: "system", content: systemContent(config))
        }
        // 用户回退到旧版本后发反馈：以当前显示的版本为基准
        if let lastIndex = base.indices.last, base[lastIndex].role == "assistant",
           base[lastIndex].content != currentResult {
            base[lastIndex] = ChatMessage(role: "assistant", content: currentResult)
        }
        let requestMessages = base + [
            ChatMessage(role: "user", content: "<\(tag)>\n\(note)\n</\(tag)>")
        ]
        run(requestMessages: requestMessages, config: config)
    }

    private func run(requestMessages: [ChatMessage], config: AppConfig) {
        isLoading = true
        awaitingFirstChunk = true
        // 蜕变动画的源文本：旧文字将逐字变成流式到达的新文字
        morphSource = currentResult.isEmpty
            ? draft.trimmingCharacters(in: .whitespacesAndNewlines)
            : currentResult
        errorMessage = nil
        showDiff = false
        statusText = t("优化中…（Esc 取消）", "Refining… (Esc to cancel)")
        // 回车即切审阅态：骨架占位先出现，首字到达后无缝替换（不再干等）
        if phase == .composing { phase = .reviewing }
        // 慢网络安抚：首字 5 秒未到，明确告知仍在等待而不是卡死
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.isLoading, self.awaitingFirstChunk else { return }
            self.statusText = self.t("网络较慢，仍在等待…（Esc 取消）",
                                     "Slow network — still waiting… (Esc cancels)")
        }
        // 流式期间结果区实时刷新；取消/失败时恢复本轮开始前的版本
        let resultBeforeRound = currentResult
        previousResultLength = currentResult.count
        task = Task { [weak self] in
            do {
                let output = try await LLMClient.completeStreaming(
                    messages: requestMessages,
                    config: config
                ) { [weak self] partial in
                    Task { @MainActor in
                        guard let self, self.isLoading else { return }
                        self.awaitingFirstChunk = false
                        self.currentResult = partial
                    }
                }
                guard !Task.isCancelled else { return }
                self?.awaitingFirstChunk = false
                self?.handleSuccess(output: output, requestMessages: requestMessages)
            } catch is CancellationError {
                self?.awaitingFirstChunk = false
                self?.currentResult = resultBeforeRound
                if resultBeforeRound.isEmpty { self?.phase = .composing }
            } catch {
                guard !Task.isCancelled else { return }
                self?.awaitingFirstChunk = false
                self?.currentResult = resultBeforeRound
                if resultBeforeRound.isEmpty { self?.phase = .composing }
                self?.handleFailure(error)
            }
        }
    }

    /// 本轮开始前的结果长度，用于疑似截断检测（流式期间 currentResult 已被覆盖）
    private var previousResultLength = 0

    private func handleSuccess(output: String, requestMessages: [ChatMessage]) {
        let previousLength = previousResultLength
        versions.append(output)
        shownVersion = versions.count
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

        // 每轮成功即写入历史（应用退出也不丢）
        HistoryStore.shared.upsert(
            id: sessionID, original: draft, versions: versions,
            preset: activeScenario.keyString
        )

        if ConfigStore.loadRaw()?.autoPaste ?? true {
            // 极速模式：出结果直接贴回原应用；纠偏轮次先删除上一版再贴
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
        awaitingFirstChunk = false
        statusText = version > 0
            ? t("已取消，剪贴板仍是 v\(version)", "Cancelled — clipboard still has v\(version)")
            : t("已取消", "Cancelled")
    }

    // MARK: - Version switching（⌘[ / ⌘]）

    func switchVersion(_ delta: Int) {
        guard !isLoading, versions.count > 1 else { return }
        let target = shownVersion + delta
        guard target >= 1, target <= versions.count else { return }
        shownVersion = target
        currentResult = versions[target - 1]
        showDiff = false
        copyToClipboard(currentResult)
        statusText = t("✅ v\(target)/\(versions.count) 已复制到剪贴板",
                       "✅ v\(target)/\(versions.count) copied to clipboard")
    }

    // MARK: - Diff

    /// 对比基准：v1 对比原始输入，vN 对比 v(N-1)
    var diffBaseText: String {
        shownVersion >= 2 ? versions[shownVersion - 2] : draft
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

    func toggleFeedbackMode() {
        feedbackMode = feedbackMode == .append ? .revise : .append
    }

    /// ⌘N 重新开始
    func resetSession() {
        stopDictation()
        task?.cancel()
        task = nil
        phase = .composing
        feedbackMode = .append
        isLoading = false
        draft = ""
        feedback = ""
        currentResult = ""
        statusText = ""
        errorMessage = nil
        versions = []
        shownVersion = 0
        showDiff = false
        messages = []
        hasAutoPasted = false
        prefetchCache = nil
        prefetchTask?.cancel()
        sessionID = UUID()
        autoPresetNote = nil
        customScenarios = ConfigStore.loadRaw()?.customScenarios ?? []
        activeScenario = Scenario.from(
            key: ConfigStore.loadRaw()?.promptPreset ?? "polish",
            in: customScenarios)
        bumpFocus()
    }

    func copyOriginal() {
        copyToClipboard(draft)
        statusText = t("已复制原文（未优化）", "Original copied (not refined)")
        errorMessage = nil
    }

    func copyResultAgain() {
        guard !currentResult.isEmpty else { return }
        copyToClipboard(currentResult)
        statusText = t("✅ v\(shownVersion) 已复制到剪贴板", "✅ v\(shownVersion) copied to clipboard")
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
