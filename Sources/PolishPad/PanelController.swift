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
    /// 本会话上一轮实际粘贴进目标应用的文本（原地替换时按其长度退格删除）
    private var lastPastedText: String?

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
        // 暗夜玻璃：面板固定深色外观（不随系统主题），保证深玻璃 + 浅色文字的稳定对比
        panel.appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingView(rootView: SessionView(model: model))
        panel.contentView = hosting

        model.onRequestClose = { [weak self] in self?.hide() }
        model.onRequestCloseAndPaste = { [weak self] in self?.hideAndPaste() }
        model.onAutoPaste = { [weak self] replacePrevious in
            self?.pasteAndReturn(replacePrevious: replacePrevious)
        }
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
        // 每次唤起都是全新会话（关窗即结束上一次对话）
        model.resetSession()
        lastPastedText = nil
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

    /// 面板保持打开：激活原应用 → 粘贴（纠偏轮先 ⌘Z 撤销上一版）→ 焦点回到面板，
    /// 用户可以立即输入下一轮纠偏
    func pasteAndReturn(replacePrevious: Bool) {
        guard let app = previousApp, !app.isTerminated else {
            HUD.shared.hide()
            model.bumpFocus()
            return
        }
        guard KeySimulator.ensureAccessibilityPermission() else {
            model.bumpFocus()
            return
        }

        app.activate()
        Task { @MainActor in
            var activated = false
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == app.processIdentifier {
                    activated = true
                    break
                }
                app.activate()
            }
            if activated {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await self.deletePreviousPasteIfNeeded(replacePrevious)
                KeySimulator.postCommandKey(KeySimulator.keyV)
                self.lastPastedText = NSPasteboard.general.string(forType: .string)
                HUD.shared.flashSuccess(replacePrevious
                    ? UILang.t("已替换", "Replaced")
                    : UILang.t("已粘贴", "Pasted"))
                try? await Task.sleep(nanoseconds: 250_000_000)
            } else {
                HUD.shared.flashSuccess(UILang.t(
                    "已复制（未能切回原应用，请手动粘贴）",
                    "Copied (couldn't reactivate the app — paste manually)"
                ))
            }
            // 焦点回到面板，随时输入下一轮纠偏
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            model.bumpFocus()
        }
    }

    /// 用精确数量的退格删除上一轮粘贴的文本。
    /// 终端类应用不支持 ⌘Z 文本撤销（会变成追加而不是替换），退格是普适行为
    private func deletePreviousPasteIfNeeded(_ replacePrevious: Bool) async {
        guard replacePrevious, let previous = lastPastedText, !previous.isEmpty else { return }
        HUD.shared.showWorking(UILang.t("替换中…", "Replacing…"))
        await KeySimulator.postBackspaces(previous.count)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// 关窗 → 激活原应用 → 自动粘贴（结果已在剪贴板）。
    /// replacePrevious 为 true 时先 ⌘Z 撤销上一次粘贴，实现原地替换
    func hideAndPaste(replacePrevious: Bool = false) {
        let target = previousApp
        model.stopDictation()
        panel.orderOut(nil)
        previousApp = nil

        guard let app = target, !app.isTerminated else {
            HUD.shared.hide()
            return
        }
        guard KeySimulator.ensureAccessibilityPermission() else { return }

        app.activate()
        Task { @MainActor in
            // 轮询确认原应用真的回到前台（最多 2s），而不是赌一个固定延迟
            var activated = false
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == app.processIdentifier {
                    activated = true
                    break
                }
                app.activate()
            }
            guard activated else {
                HUD.shared.flashSuccess(UILang.t(
                    "已复制（未能切回原应用，请手动粘贴）",
                    "Copied (couldn't reactivate the app — paste manually)"
                ))
                return
            }
            // 再留一点时间让焦点落回输入框
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.deletePreviousPasteIfNeeded(replacePrevious)
            KeySimulator.postCommandKey(KeySimulator.keyV)
            self.lastPastedText = NSPasteboard.general.string(forType: .string)
            HUD.shared.flashSuccess(replacePrevious
                ? UILang.t("已替换", "Replaced")
                : UILang.t("已粘贴", "Pasted"))
        }
    }
}
