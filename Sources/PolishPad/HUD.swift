import AppKit
import SwiftUI

/// 面板外组件（HUD/控制器）的文案本地化，跟随 中/EN 开关
enum UILang {
    static var isEnglish: Bool {
        UserDefaults.standard.bool(forKey: "outputEnglish")
    }

    static func t(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }
}

/// HUD 内容模型：更新文字时不重建视图、不改窗口几何——实时字幕稳定不跳
@MainActor
final class HUDModel: ObservableObject {
    @Published var text = ""
    @Published var style: HUDView.Style = .working
    @Published var light = false
}

/// 光标旁的悬浮状态提示：不抢焦点、不响应鼠标，用于划词优化的过程反馈
@MainActor
final class HUD {
    static let shared = HUD()

    private let panel: NSPanel
    private let model = HUDModel()
    /// 防止旧的自动隐藏计时器关掉新一轮的提示
    private var sessionToken = 0

    private init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
    }

    func showWorking(_ text: String) {
        sessionToken += 1
        present(text: text, style: .working)
    }

    /// 更新进行中的文字：同一视图原地换字，窗口几何纹丝不动（流式字幕稳定）
    func updateWorking(_ text: String) {
        guard panel.isVisible else { return }
        model.text = text
        model.style = .working
    }

    func flashSuccess(_ text: String) {
        sessionToken += 1
        let token = sessionToken
        present(text: text, style: .success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.sessionToken == token else { return }
            self.fadeOut()
        }
    }

    func hide() {
        sessionToken += 1
        fadeOut()
    }

    private func fadeOut() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    private func present(text: String, style: HUDView.Style) {
        model.text = text
        model.style = style
        model.light = UserDefaults.standard.bool(forKey: "lightTheme")
        let hosting = NSHostingView(rootView: HUDView(model: model))
        panel.contentView = hosting
        let size = hosting.fittingSize
        panel.setContentSize(size)

        // 显示在鼠标右下方，出界时夹回屏幕内
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y - size.height - 16)
        if let frame = screen?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
        // 淡入登场（120ms），不再瞬间蹦出
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }
}

struct HUDView: View {
    enum Style { case working, success }

    @ObservedObject var model: HUDModel

    var body: some View {
        let light = model.light
        HStack(spacing: 8) {
            switch model.style {
            case .working:
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(light ? .light : .dark)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
            // 尾部截断 + 单行：实时字幕始终显示最新内容，宽度恒定不跳
            Text(model.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(light ? Color.black.opacity(0.85) : .white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(minWidth: 60, maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(light ? Color.white.opacity(0.94) : Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(light ? 0.12 : 0))
        )
    }
}
