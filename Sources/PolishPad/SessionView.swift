import SwiftUI

/// Spotlight 式极简面板：输入即界面，控件收进一条纤细底栏
struct SessionView: View {
    @ObservedObject var model: SessionModel

    @State private var hoveringClose = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if model.phase == .composing {
                composerArea
            } else {
                reviewArea
            }

            if let error = model.errorMessage {
                errorRow(error)
            }

            Divider()
                .opacity(0.4)

            bottomBar
        }
        .frame(minWidth: 440, maxWidth: .infinity,
               minHeight: 280, maxHeight: .infinity)
        .background(
            ZStack {
                VisualEffectBackground(light: model.lightTheme)
                // 垫色层：暗色把 HUD 玻璃提到炭灰；明亮加厚成乳白磨砂
                LinearGradient(
                    colors: model.lightTheme
                        ? [Color.white.opacity(0.32), Color.white.opacity(0.14)]
                        : [Color.white.opacity(0.11), Color.white.opacity(0.045)],
                    startPoint: .top, endPoint: .bottom
                )
                // 神经脉冲氛围层：待机低透明度漂移，等待首字时亮起发脉冲
                // 明亮模式不用粒子（等待动画为逐字蜕变）；暗色保留 Neural 氛围
                NeuralBackgroundView(
                    surge: model.isLoading && model.awaitingFirstChunk,
                    light: model.lightTheme,
                    active: model.panelVisible && !model.lightTheme)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: model.lightTheme
                            // 明亮：顶部白色内高光渐入黑色细描边
                            ? [Color.white.opacity(0.65), Color.black.opacity(0.10)]
                            : [Color.white.opacity(0.28), Color.white.opacity(0.1)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .overlay(hiddenShortcuts)
    }

    // MARK: - 头栏：左上角关闭（mac 习惯），兼作拖动区

    private var headerBar: some View {
        HStack {
            Button {
                model.forceClose()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.15)))
                        .frame(width: 12, height: 12)
                    if hoveringClose {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(Color.black.opacity(0.55))
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .help(model.t("关闭（Esc）", "Close (Esc)"))
            Spacer()
        }
        .padding(.leading, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    // MARK: - 组稿态：一整块无边框输入区

    private var composerArea: some View {
        ZStack(alignment: .topLeading) {
            SubmitTextEditor(
                text: $model.draft,
                isEditable: !model.isLoading && !model.isRecording,
                fontSize: 15,
                inset: NSSize(width: 16, height: 18),
                focusToken: model.focusToken,
                onSubmit: { model.submitDraft() },
                onCancel: { model.handleEscape() }
            )
            .frame(maxHeight: .infinity)

            if model.draft.isEmpty {
                Text(composerPlaceholder)
                    .font(.system(size: 15))
                    .foregroundColor(Color.secondary.opacity(0.5))
                    .padding(.top, 18)
                    .padding(.leading, 20)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 审阅态：状态行 + 结果/diff + chips + 纠偏行

    private var reviewArea: some View {
        VStack(spacing: 0) {
            statusRow

            if model.showDiff {
                diffView
                    .frame(maxHeight: .infinity)
            } else if model.isLoading,
                      model.morphSource.count + model.currentResult.count < 700 {
                // 原地逐字蜕变：等待期旧文字飘舞，流式到达后从左往右逐字定稿。
                // 超长文本（视图数过多）回退到普通流式显示
                TransmuteView(
                    source: model.morphSource,
                    output: model.awaitingFirstChunk ? "" : model.currentResult)
                    .frame(maxHeight: .infinity)
            } else {
                // 结果区支持直接点击快速编辑（流式/录音期间锁定）；
                // 回车在这里是普通换行，不触发提交
                SubmitTextEditor(
                    text: streamingResultText,
                    isEditable: !model.isLoading && !model.isRecording,
                    fontSize: 14.5,
                    inset: NSSize(width: 16, height: 8),
                    onCancel: { model.handleEscape() },
                    submitOnEnter: false
                )
                .frame(maxHeight: .infinity)
            }

            Divider()
                .opacity(0.4)
                .padding(.horizontal, 16)

            quickChipsRow

            HStack(spacing: 0) {
                feedbackModeToggle
                    .padding(.leading, 14)

                ZStack(alignment: .topLeading) {
                    SubmitTextEditor(
                        text: $model.feedback,
                        isEditable: !model.isLoading && !model.isRecording,
                        fontSize: 14,
                        inset: NSSize(width: 10, height: 13),
                        focusToken: model.focusToken,
                        onSubmit: { model.submitFeedback() },
                        onCancel: { model.handleEscape() },
                        onTab: { model.toggleFeedbackMode() }
                    )
                    .frame(height: 58)

                    if model.feedback.isEmpty {
                        Text(feedbackPlaceholder)
                            .font(.system(size: 14))
                            .foregroundColor(Color.secondary.opacity(0.5))
                            .padding(.top, 13)
                            .padding(.leading, 14)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    /// 状态文字里的 ✅/⚡ 标记转成 SF Symbol：原生质感、随主题适配
    private var statusLine: some View {
        var text = model.statusText
        let success = text.hasPrefix("✅")
        if success { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let prefetched = text.hasSuffix("⚡")
        if prefetched { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        return HStack(spacing: 4) {
            if success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color.green.opacity(0.75))
            }
            Text(text)
                .font(.caption)
                .foregroundColor(Color.secondary.opacity(0.85))
            if prefetched {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundColor(Color.orange.opacity(0.85))
                    .help(model.t("停顿预取命中，即时出结果", "Served instantly from idle prefetch"))
            }
        }
    }

    /// 流式期间在文字末尾跟一个插入符：token 间停顿时也能看出"还在写"
    private var streamingResultText: Binding<String> {
        model.isLoading && !model.awaitingFirstChunk
            ? .constant(model.currentResult + " ▍")
            : $model.currentResult
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            // 版本切换（⌘[ / ⌘] 同效）
            if model.versions.count > 1 {
                Button {
                    model.switchVersion(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(model.shownVersion <= 1 || model.isLoading)
                .foregroundColor(Color.secondary.opacity(model.shownVersion <= 1 ? 0.3 : 0.9))
            }
            Text(model.versions.count > 1
                 ? "v\(model.shownVersion)/\(model.versions.count)"
                 : "v\(model.shownVersion)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            if model.versions.count > 1 {
                Button {
                    model.switchVersion(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(model.shownVersion >= model.versions.count || model.isLoading)
                .foregroundColor(Color.secondary.opacity(
                    model.shownVersion >= model.versions.count ? 0.3 : 0.9))
            }

            statusLine
                .lineLimit(1)

            Spacer()

            // 改动对比开关
            if model.version >= 1, !model.isLoading {
                Button {
                    model.showDiff.toggle()
                } label: {
                    Text(model.t("改动", "Diff"))
                        .font(.system(size: 10, weight: model.showDiff ? .semibold : .regular))
                        .foregroundColor(model.showDiff ? .primary : Color.secondary.opacity(0.8))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(
                            model.showDiff ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(model.t("对比当前版本与上一版的改动", "Compare with the previous version"))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// 增删高亮的对比视图（v1 对比原始输入）
    private var diffView: some View {
        ScrollView {
            if let attributed = DiffRenderer.attributedString(
                from: model.diffBaseText, to: model.currentResult) {
                Text(attributed)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else {
                Text(model.t("文本过长，已跳过逐字对比", "Text too long for character diff"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(16)
            }
        }
    }

    /// 快捷反馈 chips：一键发送高频纠偏意见
    private var quickChipsRow: some View {
        HStack(spacing: 6) {
            quickChip(model.t("更短", "Shorter"),
                      note: model.t("把内容压缩得更短、更精炼一些",
                                    "Make it shorter and tighter"))
            quickChip(model.t("更正式", "Formal"),
                      note: model.t("语气改得更正式、更书面一些",
                                    "Make the tone more formal"))
            quickChip(model.t("更口语", "Casual"),
                      note: model.t("语气改得更口语、更自然一些",
                                    "Make the tone more casual and natural"))
            quickChip(model.t("展开", "Expand"),
                      note: model.t("把内容展开得更详细、更具体一些",
                                    "Expand with more detail"))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func quickChip(_ label: String, note: String) -> some View {
        Button {
            model.sendQuickFeedback(note)
        } label: {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isLoading)
        .help(note)
    }

    private var feedbackPlaceholder: String {
        model.feedbackMode == .append
            ? model.t("补充新内容，优化后并入上文；回车完成…",
                      "Add new content to merge in; Enter to finish…")
            : model.t("说怎么改；回车完成…", "Describe changes; Enter to finish…")
    }

    /// 追加/修改 模式切换（Tab 键同效）
    private var feedbackModeToggle: some View {
        HStack(spacing: 1) {
            feedbackModeOption(model.t("追加", "Add"), .append)
            feedbackModeOption(model.t("修改", "Edit"), .revise)
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help(model.t("追加 = 输入新内容并入全文；修改 = 对当前版本提意见（⇥ 切换）",
                      "Add = merge new content; Edit = revise current version (⇥ toggles)"))
    }

    private func feedbackModeOption(_ label: String, _ mode: SessionModel.FeedbackMode) -> some View {
        let selected = model.feedbackMode == mode
        return Button {
            model.feedbackMode = mode
        } label: {
            Text(label)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .primary : Color.secondary.opacity(0.8))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 错误行

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(2)
            Spacer()
            if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(model.t("复制原文", "Copy Original")) { model.copyOriginal() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09))
    }

    // MARK: - 底栏：所有控件收在一条线里

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                model.toggleDictation()
            } label: {
                Image(systemName: model.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 12.5))
                    .foregroundColor(model.isRecording ? .red : Color.secondary.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("d", modifiers: .command)
            .disabled(model.isLoading)
            .help(model.t("语音输入 ⌘D", "Voice input ⌘D"))

            languageToggle

            presetMenu

            if let note = model.autoPresetNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(Color.secondary.opacity(0.65))
                    .lineLimit(1)
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer()

            ViewThatFits(in: .horizontal) {
                hintView
                Color.clear.frame(width: 1, height: 1)
            }

            Button {
                model.lightTheme.toggle()
            } label: {
                Image(systemName: model.lightTheme ? "moon.stars" : "sun.max")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.secondary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(model.lightTheme
                  ? model.t("切换为暗色", "Switch to dark")
                  : model.t("切换为明亮", "Switch to light"))

            overflowMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 快捷键提示：键帽徽章 + 浅色说明

    private struct HintItem {
        let keys: [String]
        let label: String
    }

    private var hintItems: [HintItem] {
        if model.isRecording {
            return [HintItem(keys: ["⌘D"], label: model.t("停止听写", "stop dictation"))]
        }
        if model.isLoading {
            return [HintItem(keys: ["esc"], label: model.t("取消", "cancel"))]
        }
        if model.phase == .composing {
            return [
                HintItem(keys: ["↩"], label: submitVerb),
                HintItem(keys: ["⇧↩"], label: model.t("换行", "newline")),
            ]
        }
        return [
            HintItem(keys: ["↩"], label: model.t("替换 · 留空完成", "replace · empty = done")),
            HintItem(keys: ["⌘[", "⌘]"], label: model.t("版本", "versions")),
        ]
    }

    /// 草稿框占位提示跟随当前场景
    private var composerPlaceholder: String {
        guard case .builtin(let preset) = model.activeScenario else {
            return model.t("输入要处理的内容…", "Type what you want processed…")
        }
        switch preset {
        case .polish:
            return model.t("输入要优化的内容…", "Type what you want refined…")
        case .slackEnglish:
            return model.t("输入要翻译成 Slack 英文的内容…",
                           "Type the message to turn into Slack English…")
        case .formal:
            return model.t("输入要改为正式表达的内容…",
                           "Type what to make formal…")
        case .concise:
            return model.t("输入要精简的内容…", "Type what to condense…")
        case .custom:
            return model.t("输入要处理的内容…", "Type what to process…")
        }
    }

    /// 回车动作的动词跟随当前场景（Slack=翻译、正式/精简各有其名）
    private var submitVerb: String {
        guard case .builtin(let preset) = model.activeScenario else {
            return model.t("处理", "process")
        }
        switch preset {
        case .polish: return model.t("优化", "refine")
        case .slackEnglish: return model.t("翻译", "translate")
        case .formal: return model.t("正式化", "formalize")
        case .concise: return model.t("精简", "condense")
        case .custom: return model.t("处理", "process")
        }
    }

    private var hintView: some View {
        HStack(spacing: 12) {
            ForEach(Array(hintItems.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    ForEach(item.keys, id: \.self) { keycap($0) }
                    Text(item.label)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color.secondary.opacity(0.55))
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func keycap(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .foregroundColor(Color.secondary.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.13))
            )
    }

    private var languageToggle: some View {
        HStack(spacing: 1) {
            languageOption("中", isEnglish: false)
            languageOption("EN", isEnglish: true)
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help(model.t("输出与界面语言", "Output & UI language"))
    }

    private func languageOption(_ label: String, isEnglish: Bool) -> some View {
        let selected = model.outputEnglish == isEnglish
        return Button {
            model.outputEnglish = isEnglish
        } label: {
            Text(label)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .primary : Color.secondary.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 场景快切：内置预设 + 用户自定义场景
    private var presetMenu: some View {
        Menu {
            ForEach(PromptPreset.allCases, id: \.rawValue) { preset in
                scenarioItem(.builtin(preset))
            }
            if !model.customScenarios.isEmpty {
                Divider()
                ForEach(model.customScenarios) { scenario in
                    scenarioItem(.user(scenario.id))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(scenarioShortLabel(model.activeScenario))
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
            }
            .foregroundColor(model.lightTheme
                ? Color(red: 0.14, green: 0.34, blue: 0.77)
                : .primary.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(
                Color.accentColor.opacity(model.lightTheme ? 0.13 : 0.16)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(scenarioHelp)
    }

    private func scenarioItem(_ scenario: Scenario) -> some View {
        Button {
            model.selectScenario(scenario)
        } label: {
            if scenario == model.activeScenario {
                Label(model.scenarioName(scenario), systemImage: "checkmark")
            } else {
                Text(model.scenarioName(scenario))
            }
        }
    }

    private var scenarioHelp: String {
        if case .builtin(let preset) = model.activeScenario {
            return model.t(preset.descriptionZH, preset.descriptionEN)
        }
        return model.scenarioName(model.activeScenario)
    }

    private func scenarioShortLabel(_ scenario: Scenario) -> String {
        guard case .builtin(let preset) = scenario else {
            let name = model.scenarioName(scenario)
            return name.count > 8 ? String(name.prefix(8)) + "…" : name
        }
        switch preset {
        case .polish: return model.t("优化", "Refine")
        case .slackEnglish: return "Slack"
        case .formal: return model.t("正式", "Formal")
        case .concise: return model.t("精简", "Brief")
        case .custom: return model.t("自定义", "Custom")
        }
    }

    private var overflowMenu: some View {
        Menu {
            if model.phase == .reviewing {
                Button(model.t("粘贴回原应用", "Paste to App")) { model.requestCloseAndPaste() }
                Button(model.t("再次复制", "Copy Again")) { model.copyResultAgain() }
                Divider()
            }
            Button(model.t("重新开始（⌘N）", "Restart (⌘N)")) { model.resetSession() }
            Divider()
            Button(model.t("设置…", "Settings…")) {
                NotificationCenter.default.post(name: .polishPadOpenSettings, object: nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.secondary.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
    }

    /// 不可见但保持快捷键可用（⌘N 重开、⌘[/⌘] 版本切换）
    private var hiddenShortcuts: some View {
        Group {
            Button("") { model.resetSession() }
                .keyboardShortcut("n", modifiers: .command)
            Button("") { model.switchVersion(-1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("") { model.switchVersion(1) }
                .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}

/// 暗夜玻璃背景（HUD 材质，配合面板的固定深色外观）
struct VisualEffectBackground: NSViewRepresentable {
    var light = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow  // aqua 外观下即浅色通透玻璃
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
