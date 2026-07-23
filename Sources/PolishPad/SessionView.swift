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
        .frame(width: 680)
        .background(
            ZStack {
                VisualEffectBackground()
                // 提亮层：把 HUD 玻璃从近黑拉到炭灰，同时保留透出的壁纸色
                LinearGradient(
                    colors: [Color.white.opacity(0.11), Color.white.opacity(0.045)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.1)],
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
            .frame(height: 176)

            if model.draft.isEmpty {
                Text(model.t("输入要优化的内容…", "Type what you want refined…"))
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
                    .frame(height: 270)
            } else {
                SubmitTextEditor(
                    text: $model.currentResult,
                    isEditable: false,
                    fontSize: 14.5,
                    inset: NSSize(width: 16, height: 8),
                    onCancel: { model.handleEscape() }
                )
                .frame(height: 270)
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

            Text(model.statusText)
                .font(.caption)
                .foregroundColor(Color.secondary.opacity(0.85))
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

            Text(hintText)
                .font(.system(size: 11))
                .foregroundColor(Color.secondary.opacity(0.6))

            overflowMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var hintText: String {
        if model.isRecording {
            return model.t("正在听写 · ⌘D 停止", "Dictating · ⌘D to stop")
        }
        if model.isLoading {
            return model.t("优化中 · Esc 取消", "Refining · Esc to cancel")
        }
        return model.phase == .composing
            ? model.t("↩ 优化 · ⇧↩ 换行", "↩ refine · ⇧↩ newline")
            : model.t("↩ 替换 · ⌘[⌘] 版本 · 空↩ 完成", "↩ replace · ⌘[⌘] versions · empty ↩ done")
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

    /// 场景快切：逐条消息级的场景选择
    private var presetMenu: some View {
        Menu {
            ForEach(PromptPreset.allCases, id: \.rawValue) { preset in
                Button {
                    model.selectPreset(preset)
                } label: {
                    if preset == model.activePreset {
                        Label(model.t(preset.labelZH, preset.labelEN), systemImage: "checkmark")
                    } else {
                        Text(model.t(preset.labelZH, preset.labelEN))
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(presetShortLabel(model.activePreset))
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
            }
            .foregroundColor(.primary.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.t((model.activePreset).descriptionZH, (model.activePreset).descriptionEN))
    }

    private func presetShortLabel(_ preset: PromptPreset) -> String {
        switch preset {
        case .polish: return model.t("优化", "Refine")
        case .slackEnglish: return "Slack"
        case .formal: return model.t("正式", "Formal")
        case .concise: return model.t("精简", "Brief")
        case .custom: return model.t("自定", "Custom")
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
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
