import AppKit
import SwiftUI

/// 可成为 key window 的无边框浮动面板
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController {
    private let panel: KeyablePanel
    private let model = SessionModel()
    /// 唤起前的前台应用，关窗后把焦点还回去
    private var previousApp: NSRunningApplication?

    init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: SessionView(model: model))
        panel.contentView = hosting

        model.onRequestClose = { [weak self] in self?.hide() }
        model.onRequestCloseAndPaste = { [weak self] in self?.hideAndPaste() }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication

        // 出现在鼠标所在屏幕，类 Spotlight 位置（水平居中，偏上）
        panel.layoutIfNeeded()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            let x = frame.midX - size.width / 2
            let y = frame.minY + frame.height * 0.72 - size.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.bumpFocus()
    }

    func hide() {
        model.stopDictation()
        panel.orderOut(nil)
        // 焦点还给唤起前的应用，方便直接 ⌘V
        if let app = previousApp, !app.isTerminated {
            app.activate()
        }
        previousApp = nil
    }

    /// 关窗 → 激活原应用 → 自动粘贴（结果已在剪贴板）
    func hideAndPaste() {
        let target = previousApp
        model.stopDictation()
        panel.orderOut(nil)
        previousApp = nil

        guard let app = target, !app.isTerminated else { return }
        app.activate()
        // 等原应用完成激活、焦点回到输入框后再粘贴
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard KeySimulator.ensureAccessibilityPermission() else { return }
            KeySimulator.postCommandKey(KeySimulator.keyV)
            HUD.shared.flashSuccess("已粘贴")
        }
    }
}
