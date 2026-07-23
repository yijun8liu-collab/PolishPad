import AppKit
import SwiftUI

/// 可成为 key window 的无边框浮动面板
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController {
    private let panel: KeyablePanel
    let model = SessionModel()
    /// 唤起前的前台应用，关窗后把焦点还回去
    private var previousApp: NSRunningApplication?
    /// 本会话上一轮实际粘贴进目标应用的文本（原地替换时按其长度退格删除）
    private var lastPastedText: String?

    init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
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
        panel.contentMinSize = NSSize(width: 520, height: 320)
        // 拖拽调整后记住尺寸（下次唤起沿用）
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                PanelSize.store(self.panel.frame.size)
            }
        }
        // 设置里选了预设档位：立即应用（可见时锚定顶边变化）
        NotificationCenter.default.addObserver(
            forName: .polishPadPanelSizeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyStoredSize() }
        }
        // 玻璃主题：暗色（默认）或明亮，由面板按钮切换、UserDefaults 记忆
        applyTheme()
        NotificationCenter.default.addObserver(
            forName: .polishPadThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyTheme() }
        }

        let hosting = NSHostingView(rootView: SessionView(model: model))
        panel.contentView = hosting

        model.onRequestClose = { [weak self] in self?.hide() }
        model.onRequestCloseAndPaste = { [weak self] in self?.hideAndPaste() }
        model.onCloseWithShownVersion = { [weak self] in
            guard let self else { return }
            if let pasted = self.lastPastedText, !pasted.isEmpty,
               pasted != self.model.currentResult {
                // 回退/前进过版本：目标里还是旧版，替换成当前显示的版本再关窗
                self.model.copyResultAgain()
                self.hideAndPaste(replacePrevious: true)
            } else {
                self.hide()
            }
        }
        model.onAutoPaste = { [weak self] replacePrevious in
            self?.pasteAndReturn(replacePrevious: replacePrevious)
        }
    }

    private func applyStoredSize() {
        let size = PanelSize.current
        guard panel.isVisible else { return }
        let frame = panel.frame
        panel.setFrame(
            NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                   width: size.width, height: size.height),
            display: true, animate: true)
    }

    private func applyTheme() {
        let light = UserDefaults.standard.bool(forKey: "lightTheme")
        panel.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
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
        // 应用感知：按唤起前的前台应用自动选场景
        model.applyAutoPreset(
            bundleID: previousApp?.bundleIdentifier,
            appName: previousApp?.localizedName
        )

        // 应用记忆的尺寸（拖拽或设置预设），再定位
        panel.setContentSize(PanelSize.current)
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
        // 与 Esc/红点语义一致：关窗即取消进行中的请求——
        // 否则请求在后台跑完会静默覆盖用户剪贴板
        model.cancelRequest()
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
            model.autoPasteFailed()
            HUD.shared.hide()
            model.bumpFocus()
            return
        }
        guard KeySimulator.ensureAccessibilityPermission() else {
            model.autoPasteFailed()
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
                let replacedOld = replacePrevious ? self.lastPastedText : nil
                await self.deletePreviousPasteIfNeeded(replacePrevious)
                KeySimulator.postCommandKey(KeySimulator.keyV)
                self.lastPastedText = NSPasteboard.general.string(forType: .string)
                ReplacementUndo.shared.record(
                    pasted: self.lastPastedText, replaced: replacedOld, app: app)
                HUD.shared.flashSuccess(replacePrevious
                    ? UILang.t("已替换", "Replaced")
                    : UILang.t("已粘贴", "Pasted"))
                try? await Task.sleep(nanoseconds: 250_000_000)
            } else {
                self.model.autoPasteFailed()
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
            let replacedOld = replacePrevious ? self.lastPastedText : nil
            await self.deletePreviousPasteIfNeeded(replacePrevious)
            KeySimulator.postCommandKey(KeySimulator.keyV)
            self.lastPastedText = NSPasteboard.general.string(forType: .string)
            ReplacementUndo.shared.record(
                pasted: self.lastPastedText, replaced: replacedOld, app: app)
            HUD.shared.flashSuccess(replacePrevious
                ? UILang.t("已替换", "Replaced")
                : UILang.t("已粘贴", "Pasted"))
        }
    }
}
