import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let polishPadThemeChanged = Notification.Name("PolishPad.themeChanged")
    static let polishPadLanguageChanged = Notification.Name("PolishPad.languageChanged")
    static let polishPadPanelSizeChanged = Notification.Name("PolishPad.panelSizeChanged")
    static let polishPadResetPanelPosition = Notification.Name("PolishPad.resetPanelPosition")
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
    /// 改动强度（1-5 格，0=隐藏）与文字标签
    @Published var changeIntensity = 0
    @Published var changeLabel = ""
    /// 动态智能 chips：基于本轮结果生成的针对性修改建议（空=用固定四个）
    @Published var smartChips: [String] = []
    private var chipsRound = 0
    /// 语气调音台：正式度/详尽度（50=中性跟随场景，偏离即注入提示词）
    @Published var toneFormality: Double = 50
    @Published var toneDetail: Double = 50
    /// 面板空态流程卡：完成/跳过引导前显示
    @Published var showFirstUseHint =
        !UserDefaults.standard.bool(forKey: "onboardingCompleted")
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
        // 引导完成/跳过：空态流程卡消失
        NotificationCenter.default.addObserver(
            forName: .polishPadOnboardingDone, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showFirstUseHint = false }
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

    /// 改动强度：按相似度映射为 1-5 格
    static func changeIntensity(from old: String, to new: String)
        -> (level: Int, zh: String, en: String) {
        guard !old.isEmpty, !new.isEmpty else { return (0, "", "") }
        let similarity = DiffRenderer.similarity(between: old, and: new)
        switch similarity {
        case 0.9...: return (1, "轻润色", "Light polish")
        case 0.75..<0.9: return (2, "小修改", "Small edits")
        case 0.55..<0.75: return (3, "中等改写", "Moderate rewrite")
        case 0.35..<0.55: return (4, "较大改写", "Major rewrite")
        default: return (5, "大幅重写", "Full rewrite")
        }
    }

    /// 智能 chips 响应解析：剥围栏取方括号，逐条清洗（可自检）
    static func parseSuggestions(_ raw: String) -> [String]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst()
                .joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
        }
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"), start < end,
              let items = try? JSONDecoder().decode(
                  [String].self, from: Data(String(text[start...end]).utf8))
        else { return nil }
        let cleaned = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 20 }
        return cleaned.isEmpty ? nil : Array(cleaned.prefix(3))
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

    /// 场景专属点缀色：内置固定配色；自定义场景按 id 稳定取色
    func scenarioColor(_ scenario: Scenario) -> Color {
        switch scenario {
        case .builtin(.polish): return Color(red: 0.43, green: 0.62, blue: 1.0)
        case .builtin(.slackEnglish): return Color(red: 0.73, green: 0.55, blue: 1.0)
        case .builtin(.formal): return Color(red: 0.48, green: 0.66, blue: 0.85)
        case .builtin(.concise): return Color(red: 0.94, green: 0.70, blue: 0.37)
        case .builtin(.custom): return .accentColor
        case .user(let id):
            let palette: [Color] = [
                Color(red: 0.37, green: 0.88, blue: 0.72),
                Color(red: 1.0, green: 0.62, blue: 0.69),
                Color(red: 0.56, green: 0.79, blue: 1.0),
                Color(red: 0.85, green: 0.80, blue: 0.46),
                Color(red: 0.80, green: 0.65, blue: 1.0),
            ]
            let seed = id.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 9973 }
            return palette[seed % palette.count]
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
        // 听写中的停顿≠成句：不预取（半截句子费 token 且无意义）
        guard phase == .composing, !isLoading, !isRecording else { return }
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
            + toneBlock()
    }

    /// 语气调音台注入：仅在偏离中性时附加（50±2 视作默认）
    private func toneBlock() -> String {
        let deviates = abs(toneFormality - 50) > 2 || abs(toneDetail - 50) > 2
        guard deviates else { return "" }
        if outputEnglish {
            return "\n\nAdditional tone calibration (overrides scenario defaults): "
                + "formality \(Int(toneFormality))/100 (0 = very casual, 100 = very formal); "
                + "verbosity \(Int(toneDetail))/100 (0 = extremely concise, 100 = fully elaborated)."
        }
        return "\n\n附加语气要求（优先级高于场景默认）：正式程度 \(Int(toneFormality))/100"
            + "（0=非常口语，100=非常正式）；详尽程度 \(Int(toneDetail))/100"
            + "（0=极度精简，100=充分展开）。请按此校准输出风格。"
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

    /// 重新生成：用产生上一轮结果的同一请求再跑一遍，结果追加为新版本。
    /// 系统消息按当前语言/场景/语气重建——调完语气调音台再按 ⌘R 即可用新语气重出
    func regenerate() {
        guard !isLoading, phase == .reviewing, !messages.isEmpty else { return }
        stopDictation()
        let config: AppConfig
        do {
            config = try ConfigStore.load()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var base = messages
        if base.last?.role == "assistant" { base.removeLast() }
        if let first = base.first, first.role == "system" {
            base[0] = ChatMessage(role: "system", content: systemContent(config))
        }
        run(requestMessages: base, config: config)
    }

    /// 动态智能 chips：轻量二次调用，预测用户最可能想要的后续修改。
    /// 静默失败（保留固定四个 chips 兜底）；跨轮次作废
    private func generateSmartChips(original: String, output: String) {
        guard var config = try? ConfigStore.load() else { return }
        config.maxTokens = 150
        config.temperature = 0.5
        let round = chipsRound
        let system = """
        你是修改建议生成器。用户刚用 AI 把原文改写成了结果。请预测用户最可能想要的后续修改，输出 2-3 条祈使句式的修改指令。
        要求：只输出一个 JSON 字符串数组（无其他文字、无代码围栏）；每条不超过 12 个字；与结果语言一致；必须针对内容本身、具体可执行，不要"改得更好"这类空话。
        """
        let user = "原文：\(String(original.prefix(600)))\n\n改写结果：\(String(output.prefix(600)))"
        Task { [weak self] in
            guard let text = try? await LLMClient.complete(
                messages: [
                    ChatMessage(role: "system", content: system),
                    ChatMessage(role: "user", content: user),
                ], config: config),
                let chips = Self.parseSuggestions(text) else { return }
            guard let self, round == self.chipsRound,
                  self.phase == .reviewing, !self.isLoading else { return }
            self.smartChips = chips
        }
    }

    private func run(requestMessages: [ChatMessage], config: AppConfig) {
        isLoading = true
        awaitingFirstChunk = true
        changeIntensity = 0
        smartChips = []
        chipsRound += 1
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

        // 改动强度（首轮=对比草稿，纠偏轮=对比上一版）
        let intensity = Self.changeIntensity(from: morphSource, to: output)
        changeIntensity = intensity.level
        changeLabel = t(intensity.zh, intensity.en)

        generateSmartChips(original: morphSource, output: output)

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

        if Tutorial.active {
            // 教学模式：结果直接写入引导窗口的演示框，不发任何合成按键
            hasAutoPasted = true
            NotificationCenter.default.post(
                name: .polishPadTutorialResult, object: nil,
                userInfo: ["text": output])
            bumpFocus()
        } else if ConfigStore.loadRaw()?.autoPaste ?? true {
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

    /// 版本圆点：直接跳转到第 n 版（1-based）
    func showVersion(_ target: Int) {
        switchVersion(target - shownVersion)
    }

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
        // 场景创建卡开着时：Esc 只关卡片，不关面板
        if showScenarioCreator {
            showScenarioCreator = false
            scenarioDescription = ""
            return
        }
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
        changeIntensity = 0
        smartChips = []
        chipsRound += 1
        toneFormality = 50
        toneDetail = 50
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
