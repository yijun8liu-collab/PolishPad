import AppKit
import SwiftUI

/// 基于 NSTextView 的多行输入框：
/// - Enter 提交（IME 组字中的 Enter 交给输入法，不会误触发）
/// - Shift+Enter 换行
/// - Esc 通过 onCancel 回调
struct SubmitTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var fontSize: CGFloat = 14
    var inset: NSSize = NSSize(width: 6, height: 8)
    /// 非零且变化时抢占键盘焦点
    var focusToken: Int = 0
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    /// 提供时，Tab 键触发回调而不是插入制表符/移动焦点
    var onTab: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: fontSize)
        textView.textContainerInset = inset
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.isSelectable = true

        if focusToken != 0, focusToken != context.coordinator.lastFocusedToken {
            context.coordinator.lastFocusedToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SubmitTextEditor
        var lastFocusedToken = 0

        init(_ parent: SubmitTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // IME 正在组字：Enter 是确认候选词，交回给输入法
                if textView.hasMarkedText() { return false }
                // Shift+Enter：普通换行
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                if let onTab = parent.onTab {
                    onTab()
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}
