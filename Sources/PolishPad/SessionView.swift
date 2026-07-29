import SwiftUI

/// Spotlight 式极简面板：输入即界面，控件收进一条纤细底栏
struct SessionView: View {
    @ObservedObject var model: SessionModel

    @State private var hoveringClose = false
    @State private var showTonePopover = false
    @State private var checkVisible = true

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
                // 垫色层：暗色把 HUD 玻璃提到炭灰；明亮只留薄纱（模糊靠材质）
                LinearGradient(
                    colors: model.lightTheme
                        ? [Color.white.opacity(0.26), Color.white.opacity(0.10)]
                        : [Color.white.opacity(0.11), Color.white.opacity(0.045)],
                    startPoint: .top, endPoint: .bottom
                )
                // 明亮模式顶部镜面高光：光落在玻璃上缘的质感
                if model.lightTheme {
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), .clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.18)
                    )
                }
                // 神经脉冲氛围层：待机低透明度漂移，等待首字时亮起发脉冲
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: model.lightTheme
                            // 明亮：顶部白高光渐入场景色细描边
                            ? [Color.white.opacity(0.65),
                               model.scenarioColor(model.activeScenario).opacity(0.4)]
                            : [Color.white.opacity(0.28),
                               model.scenarioColor(model.activeScenario).opacity(0.35)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .overlay(hiddenShortcuts)
        .overlay {
            if model.showScenarioCreator { scenarioCreatorCard }
        }
        // G 入场（内容层）：94% 缩放 + 4px 模糊聚焦成型，与窗口淡入同步
        .scaleEffect(model.panelVisible ? 1 : 0.94)
        .blur(radius: model.panelVisible ? 0 : 4)
        .animation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.16),
                   value: model.panelVisible)
    }

    // MARK: - 一句话创建场景

    private var scenarioCreatorCard: some View {
        VStack(spacing: 12) {
            Text(model.t("用一句话描述你的场景", "Describe your scenario in a sentence"))
                .font(.system(size: 13, weight: .semibold))
            TextField(
                model.t("例如：把技术方案翻译成给老板看的大白话汇报",
                        "e.g. turn technical plans into plain-language updates for my boss"),
                text: $model.scenarioDescription,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
            .frame(width: 330)
            .disabled(model.isGeneratingScenario)
            .onSubmit { model.generateScenario() }
            HStack(spacing: 10) {
                Button(model.t("取消", "Cancel")) {
                    model.showScenarioCreator = false
                    model.scenarioDescription = ""
                }
                .disabled(model.isGeneratingScenario)
                Button {
                    model.generateScenario()
                } label: {
                    if model.isGeneratingScenario {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text(model.t("生成中…", "Generating…"))
                        }
                    } else {
                        Text(model.t("生成场景", "Generate"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isGeneratingScenario || model.scenarioDescription
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(model.t("AI 会生成场景名与提示词，多轮纠偏协议自动附加；生成后可在设置中查看和修改",
                         "AI generates the name & prompt; the multi-round protocol is appended automatically. Edit later in Settings."))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 330)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(model.lightTheme
                    ? Color.white.opacity(0.97)
                    : Color(red: 0.13, green: 0.14, blue: 0.16).opacity(0.98))
                .shadow(radius: 24, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .onExitCommand {
            model.showScenarioCreator = false
            model.scenarioDescription = ""
        }
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
            Button {
                NotificationCenter.default.post(
                    name: .polishPadOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.secondary.opacity(0.65))
            }
            .buttonStyle(.plain)
            .help(model.t("设置", "Settings"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
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

            // 首次使用流程卡：完成/跳过引导前显示（按使用顺序讲一遍流程）
            if model.showFirstUseHint, model.draft.isEmpty {
                VStack { Spacer(); firstUseHintCard }
            }
        }
    }

    private var firstUseHintCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(model.t("第一次使用？三步就会：", "First time? Three steps:"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(model.t("知道了", "Got it")) {
                    UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                    NotificationCenter.default.post(
                        name: .polishPadOnboardingDone, object: nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundColor(.accentColor)
            }
            hintLine("1", model.t("把想说的话直接打进来，多口语、多凌乱都行",
                                  "Type whatever you want to say — rough is fine"))
            HStack(spacing: 4) {
                Text("2").font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(model.t("按", "Press"))
                keycap("↩")
                Text(model.t("——优化好的文字会自动粘贴回你刚才的应用",
                             "— the polished text pastes back into your app automatically"))
            }
            .font(.system(size: 11))
            .foregroundColor(Color.secondary)
            HStack(spacing: 4) {
                Text("3").font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(model.t("想补充就继续打字，想改就提意见（", "Keep typing to add, or give feedback ("))
                keycap("⇥")
                Text(model.t("切换）；满意了直接按", "toggles); when happy just press"))
                keycap("↩")
                Text(model.t("关闭面板", "to close"))
            }
            .font(.system(size: 11))
            .foregroundColor(Color.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18))
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func hintLine(_ n: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(n).font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundColor(Color.secondary)
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
                    output: model.awaitingFirstChunk ? "" : model.currentResult,
                    tint: model.scenarioColor(model.activeScenario))
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

    private var intensityColor: Color {
        switch model.changeIntensity {
        case ...2: return Color.green.opacity(0.75)
        case 3: return Color(red: 0.91, green: 0.70, blue: 0.29)
        default: return Color(red: 1.0, green: 0.54, blue: 0.4)
        }
    }

    private var toneActive: Bool {
        abs(model.toneFormality - 50) > 2 || abs(model.toneDetail - 50) > 2
    }

    private var tonePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t("语气调音台", "Tone controls"))
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                Text(model.t("口语", "Casual")).font(.system(size: 10))
                    .foregroundColor(.secondary)
                Slider(value: $model.toneFormality, in: 0...100)
                    .frame(width: 150)
                Text(model.t("正式", "Formal")).font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Text(model.t("精简", "Brief")).font(.system(size: 10))
                    .foregroundColor(.secondary)
                Slider(value: $model.toneDetail, in: 0...100)
                    .frame(width: 150)
                Text(model.t("详尽", "Full")).font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            HStack {
                Text(model.t("作用于下一轮生成；新会话恢复默认",
                             "Applies to the next round; resets each session"))
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                Spacer()
                if toneActive {
                    Button(model.t("恢复默认", "Reset")) {
                        model.toneFormality = 50
                        model.toneDetail = 50
                    }
                    .controlSize(.mini)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    /// 状态行：成功态只留一个几秒后自动淡出的绿勾（悬停看详情），
    /// 进行中/警告类文字照常显示——版本信息由圆点表达，不再重复念一遍
    private var statusLine: some View {
        var text = model.statusText
        let success = text.hasPrefix("✅")
        if success { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let prefetched = text.hasSuffix("⚡")
        if prefetched { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        let warning = text.contains("比上一版短") || text.contains("much shorter")
        return HStack(spacing: 4) {
            if success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color.green.opacity(0.75))
                    .opacity(checkVisible ? 1 : 0)
                    .help(text)
                    .task(id: model.statusText) {
                        checkVisible = true
                        guard !warning else { return }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        withAnimation(.easeOut(duration: 0.8)) { checkVisible = false }
                    }
                if prefetched {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Color.orange.opacity(0.85))
                        .opacity(checkVisible ? 1 : 0)
                        .help(model.t("停顿预取命中，即时出结果",
                                      "Served instantly from idle prefetch"))
                }
                if warning {
                    Text(text)
                        .font(.caption)
                        .foregroundColor(Color.orange.opacity(0.9))
                }
            } else {
                Text(text)
                    .font(.caption)
                    .foregroundColor(Color.secondary.opacity(0.85))
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
            // 版本时间线：可点小圆点，hover 预览该版本开头（⌘[ / ⌘] 同效）
            if !model.versions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(model.versions.enumerated()), id: \.offset) { index, version in
                        Button {
                            model.showVersion(index + 1)
                        } label: {
                            // 固定 14×14 命中框：点得中，且当前点放大时不挤动相邻圆点
                            Circle()
                                .fill(index + 1 == model.shownVersion
                                    ? model.scenarioColor(model.activeScenario)
                                    : Color.secondary.opacity(0.3))
                                .frame(width: index + 1 == model.shownVersion ? 8 : 6,
                                       height: index + 1 == model.shownVersion ? 8 : 6)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isLoading)
                        .help("v\(index + 1) · " + String(version.prefix(24))
                              + model.t("　⌘[ ⌘] 切换", "　⌘[ ⌘]"))
                    }
                }
                .padding(.leading, 2)
            }

            statusLine
                .lineLimit(1)

            Spacer()

            // 重新生成本轮（应用当前语气/场景/语言）
            if model.version >= 1, !model.isLoading {
                Button {
                    model.regenerate()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.secondary.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .help(model.t("重新生成本轮（⌘R，应用当前语气）",
                              "Regenerate this round (⌘R, applies current tone)"))
            }

            // 强度刻度即改动入口：点刻度打开/关闭与上一版的对比
            if model.version >= 1, !model.isLoading {
                Button {
                    model.showDiff.toggle()
                } label: {
                    HStack(spacing: 5) {
                        HStack(spacing: 2.5) {
                            ForEach(0..<5, id: \.self) { index in
                                Capsule()
                                    .fill(index < model.changeIntensity
                                        ? intensityColor : Color.primary.opacity(0.12))
                                    .frame(width: 8, height: 4.5)
                            }
                        }
                        if !model.changeLabel.isEmpty {
                            Text(model.changeLabel)
                                .font(.system(size: 9))
                                .foregroundColor(Color.secondary.opacity(0.65))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(
                        model.showDiff ? Color.accentColor.opacity(0.22) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.t("改动强度；点击对比与上一版的差异",
                              "Change intensity — click to compare with the previous version"))
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
            if !model.smartChips.isEmpty {
                ForEach(model.smartChips, id: \.self) { suggestion in
                    quickChip(suggestion, note: suggestion)
                }
                Spacer()
            } else {
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
            ? model.t("补充新内容…", "Add more content…")
            : model.t("想怎么改，直接说…", "Describe the change…")
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

            Button {
                showTonePopover.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundColor(toneActive
                        ? model.scenarioColor(model.activeScenario)
                        : Color.secondary.opacity(0.75))
            }
            .buttonStyle(.plain)
            .help(model.t("语气调音台", "Tone controls"))
            .popover(isPresented: $showTonePopover, arrowEdge: .top) {
                tonePopover
            }

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
        return []
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
            ForEach(PromptPreset.allCases.filter { $0 != .custom },
                    id: \.rawValue) { preset in
                scenarioItem(.builtin(preset))
            }
            if !model.customScenarios.isEmpty {
                Divider()
                ForEach(model.customScenarios) { scenario in
                    scenarioItem(.user(scenario.id))
                }
            }
            Divider()
            Button {
                model.showScenarioCreator = true
            } label: {
                Label(model.t("描述创建新场景…", "Describe a new scenario…"),
                      systemImage: "sparkles")
            }
        } label: {
            HStack(spacing: 3) {
                Text(scenarioShortLabel(model.activeScenario))
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
            }
            .foregroundColor(model.lightTheme
                ? model.scenarioColor(model.activeScenario).opacity(0.95)
                : .primary.opacity(0.85))
            .brightness(model.lightTheme ? -0.28 : 0)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(
                model.scenarioColor(model.activeScenario)
                    .opacity(model.lightTheme ? 0.16 : 0.22)))
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
                Button(model.t("粘贴并替换（↩，留空完成）", "Paste & Replace (↩)")) {
                    model.requestCloseAndPaste()
                }
                Button(model.t("再次复制", "Copy Again")) { model.copyResultAgain() }
                Button(model.t("重新生成（⌘R）", "Regenerate (⌘R)")) { model.regenerate() }
                Button(model.t("上一版（⌘[）", "Previous Version (⌘[)")) { model.switchVersion(-1) }
                Button(model.t("下一版（⌘]）", "Next Version (⌘])")) { model.switchVersion(1) }
                Divider()
            }
            Button(model.lightTheme
                   ? model.t("切换为暗色主题", "Switch to Dark Theme")
                   : model.t("切换为明亮主题", "Switch to Light Theme")) {
                model.lightTheme.toggle()
            }
            Button(model.t("重新开始（⌘N）", "Restart (⌘N)")) { model.resetSession() }
            Button(model.t("恢复默认位置", "Reset panel position")) {
                NotificationCenter.default.post(
                    name: .polishPadResetPanelPosition, object: nil)
            }
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
        // 明亮：popover 材质（重模糊强扩散，磨砂感）；暗色：hudWindow
        view.material = light ? .popover : .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = light ? .popover : .hudWindow
    }
}
