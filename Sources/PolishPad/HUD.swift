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

/// 光标旁的悬浮状态提示：不抢焦点、不响应鼠标，用于划词优化的过程反馈
@MainActor
final class HUD {
    static let shared = HUD()

    private let panel: NSPanel
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
        present(HUDView(text: text, style: .working))
    }

    func flashSuccess(_ text: String) {
        sessionToken += 1
        let token = sessionToken
        present(HUDView(text: text, style: .success))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.sessionToken == token else { return }
            self.panel.orderOut(nil)
        }
    }

    func hide() {
        sessionToken += 1
        panel.orderOut(nil)
    }

    private func present(_ view: HUDView) {
        let hosting = NSHostingView(rootView: view)
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
        panel.orderFrontRegardless()
    }
}

struct HUDView: View {
    enum Style { case working, success }

    let text: String
    let style: Style

    var body: some View {
        HStack(spacing: 8) {
            switch style {
            case .working:
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
    }
}
