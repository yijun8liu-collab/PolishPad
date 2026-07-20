import SwiftUI

/// Spotlight 式极简面板：输入即界面，控件收进一条纤细底栏
struct SessionView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(spacing: 0) {
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
            .frame(height: 190)

            if model.draft.isEmpty {
                Text(model.t("输入要润色的内容…", "Type what you want polished…"))
                    .font(.system(size: 15))
                    .foregroundColor(Color.secondary.opacity(0.5))
                    .padding(.top, 18)
                    .padding(.leading, 20)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 审阅态：状态行 + 结果 + 纠偏行

    private var reviewArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("v\(model.version)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Text(model.statusText)
                    .font(.caption)
                    .foregroundColor(Color.secondary.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 4)

            SubmitTextEditor(
                text: $model.currentResult,
                isEditable: false,
                fontSize: 14.5,
                inset: NSSize(width: 16, height: 8),
                onCancel: { model.handleEscape() }
            )
            .frame(height: 270)

            Divider()
                .opacity(0.4)
                .padding(.horizontal, 16)

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

    private var feedbackPlaceholder: String {
        model.feedbackMode == .append
            ? model.t("补充新内容，润色后并入上文；回车完成…", "Add new content to merge in; Enter to finish…")
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

            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer()

            Text(hintText)
                .font(.system(size: 11))
                .foregroundColor(Color.secondary.opacity(0.6))

            overflowMenu

            Button {
                model.forceClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(model.t("关闭（Esc）", "Close (Esc)"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var hintText: String {
        if model.isRecording {
            return model.t("正在听写 · ⌘D 停止", "Dictating · ⌘D to stop")
        }
        if model.isLoading {
            return model.t("润色中 · Esc 取消", "Polishing · Esc to cancel")
        }
        return model.phase == .composing
            ? model.t("↩ 润色 · ⇧↩ 换行", "↩ polish · ⇧↩ newline")
            : model.t("↩ 替换 · ⇥ 追加/修改 · 空↩ 完成", "↩ replace · ⇥ add/edit · empty ↩ done")
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
        }
        .buttonStyle(.plain)
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

    /// 不可见但保持快捷键可用
    private var hiddenShortcuts: some View {
        Button("") { model.resetSession() }
            .keyboardShortcut("n", modifiers: .command)
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
