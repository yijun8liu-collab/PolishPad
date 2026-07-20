import SwiftUI

struct SessionView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.phase == .composing {
                composingBody
            } else {
                reviewingBody
            }

            if let error = model.errorMessage {
                errorBanner(error)
            }

            footer
        }
        .padding(16)
        .frame(width: 640)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.25), Color.primary.opacity(0.1)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.purple],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                )

            Text("PolishPad")
                .font(.system(size: 14, weight: .semibold))

            if model.version > 0 {
                Text("v\(model.version)")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }

            Spacer()

            if model.isRecording {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                    Text(model.t("正在听写…（⌘D 停止）", "Dictating… (⌘D to stop)"))
                }
                .font(.caption)
                .foregroundColor(.red)
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            // 输出语言 + 界面语言开关
            Picker("", selection: $model.outputEnglish) {
                Text("中").tag(false)
                Text("EN").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 84)
            .labelsHidden()
            .help(model.t("中 = 保持原文语言，EN = 输出英文（界面语言同步切换）",
                          "中 = keep original language, EN = English output (UI language follows)"))

            Button {
                model.forceClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(model.t("关闭（Esc）", "Close (Esc)"))
        }
    }

    // MARK: - Body sections

    private var composingBody: some View {
        ZStack(alignment: .topLeading) {
            SubmitTextEditor(
                text: $model.draft,
                isEditable: !model.isLoading && !model.isRecording,
                focusToken: model.focusToken,
                onSubmit: { model.submitDraft() },
                onCancel: { model.handleEscape() }
            )
            .frame(height: 170)

            if model.draft.isEmpty {
                Text(model.t("输入要润色的内容，Enter 提交…",
                             "Type what you want polished, Enter to submit…"))
                    .foregroundColor(Color.secondary.opacity(0.7))
                    .padding(.top, 8)
                    .padding(.leading, 8)
                    .allowsHitTesting(false)
            }
        }
        .background(inputBackground)
    }

    private var reviewingBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.statusText.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10))
                    Text(model.statusText)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            SubmitTextEditor(
                text: $model.currentResult,
                isEditable: false,
                onCancel: { model.handleEscape() }
            )
            .frame(height: 260)
            .background(resultBackground)

            ZStack(alignment: .topLeading) {
                SubmitTextEditor(
                    text: $model.feedback,
                    isEditable: !model.isLoading && !model.isRecording,
                    fontSize: 13,
                    focusToken: model.focusToken,
                    onSubmit: { model.submitFeedback() },
                    onCancel: { model.handleEscape() }
                )
                .frame(height: 64)

                if model.feedback.isEmpty {
                    Text(model.t("说怎么改，Enter 原地替换；留空 Enter 或 Esc 结束",
                                 "Describe changes — Enter replaces in place; empty Enter or Esc to finish"))
                        .font(.system(size: 13))
                        .foregroundColor(Color.secondary.opacity(0.7))
                        .padding(.top, 8)
                        .padding(.leading, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(inputBackground)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(3)
            Spacer()
            if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(model.t("复制原文", "Copy Original")) { model.copyOriginal() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25))
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.toggleDictation()
            } label: {
                Image(systemName: model.isRecording ? "mic.fill" : "mic")
                    .foregroundColor(model.isRecording ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("d", modifiers: .command)
            .disabled(model.isLoading)
            .help(model.t("语音输入 ⌘D", "Voice input ⌘D"))

            Text(model.phase == .composing
                 ? model.t("Enter 提交 · ⌘D 语音 · Esc 关闭",
                           "Enter submit · ⌘D voice · Esc close")
                 : model.t("Enter 发送纠偏 · ⌘D 语音 · Esc 关闭",
                           "Enter refine · ⌘D voice · Esc close"))
                .font(.caption2)
                .foregroundColor(Color.secondary.opacity(0.8))

            Spacer()

            if model.phase == .reviewing {
                Button(model.t("再次复制", "Copy Again")) { model.copyResultAgain() }
                    .controlSize(.small)
                    .disabled(model.isLoading)
                Button(model.t("粘贴回原应用", "Paste to App")) { model.requestCloseAndPaste() }
                    .controlSize(.small)
                    .disabled(model.isLoading)
            }
            Button(model.t("重新开始 ⌘N", "Restart ⌘N")) { model.resetSession() }
                .controlSize(.small)
                .keyboardShortcut("n", modifiers: .command)
        }
    }

    // MARK: - Backgrounds

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }

    /// 结果区带一点强调色，和输入区区分开
    private var resultBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.15))
            )
    }
}

/// 毛玻璃背景
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
