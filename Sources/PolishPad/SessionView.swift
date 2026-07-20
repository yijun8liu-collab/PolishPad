import SwiftUI

struct SessionView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .foregroundColor(.accentColor)
            Text("PolishPad")
                .font(.headline)
            Spacer()
            if model.isRecording {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                    Text("正在听写…（⌘D 停止）")
                }
                .font(.caption)
                .foregroundColor(.red)
            }
            if model.version > 0 {
                Text("v\(model.version)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var composingBody: some View {
        ZStack(alignment: .topLeading) {
            SubmitTextEditor(
                text: $model.draft,
                isEditable: !model.isLoading && !model.isRecording,
                focusToken: model.focusToken,
                onSubmit: { model.submitDraft() },
                onCancel: { model.handleEscape() }
            )
            .frame(height: 160)

            if model.draft.isEmpty {
                Text("输入要润色的内容…")
                    .foregroundColor(.secondary)
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
                Text(model.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SubmitTextEditor(
                text: $model.currentResult,
                isEditable: false,
                onCancel: { model.handleEscape() }
            )
            .frame(height: 260)
            .background(inputBackground)

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
                    Text("说怎么改，Enter 发送并替换已粘贴的内容")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
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
                Button("复制原文") { model.copyOriginal() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
    }

    private var footer: some View {
        HStack {
            Button {
                model.toggleDictation()
            } label: {
                Image(systemName: model.isRecording ? "mic.fill" : "mic")
                    .foregroundColor(model.isRecording ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("d", modifiers: .command)
            .disabled(model.isLoading)
            .help("语音输入 ⌘D")

            Text(model.phase == .composing
                 ? "Enter 提交 · ⌘D 语音 · Esc 关闭"
                 : "Enter 发送纠偏 · ⌘D 语音 · Esc 关闭")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            if model.phase == .reviewing {
                Button("再次复制") { model.copyResultAgain() }
                    .controlSize(.small)
                    .disabled(model.isLoading)
                Button("粘贴回原应用") { model.requestCloseAndPaste() }
                    .controlSize(.small)
                    .disabled(model.isLoading)
            }
            Button("重新开始 ⌘N") { model.resetSession() }
                .controlSize(.small)
                .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.05))
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
