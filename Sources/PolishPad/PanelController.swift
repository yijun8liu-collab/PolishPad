import AppKit
import ApplicationServices
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
    /// 面板可见期间阻止 App Nap：否则在别的应用里输入时（本应用后台）
    /// 粒子/蜕变动画的渲染定时器会被系统冻结
    private var activityToken: NSObjectProtocol?
    /// 程序化定位期间不记录位置（区分用户拖动）
    private var positioningProgrammatically = false
    /// 淡出代际：快速再唤起时作废进行中的淡出，避免把新面板隐藏
    private var fadeGeneration = 0

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
        panel.contentMinSize = NSSize(width: 440, height: 280)
        // 拖拽调整后记住尺寸（下次唤起沿用）
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                PanelSize.store(self.panel.frame.size)
            }
        }
        // 用户拖动面板后记住位置（下次唤起沿用）
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.positioningProgrammatically,
                      self.panel.isVisible else { return }
                self.storeRelativeOrigin()
            }
        }
        // ⋯ 菜单「恢复默认位置」
        NotificationCenter.default.addObserver(
            forName: .polishPadResetPanelPosition, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                UserDefaults.standard.removeObject(forKey: "panelOriginX")
                UserDefaults.standard.removeObject(forKey: "panelOriginY")
                UserDefaults.standard.removeObject(forKey: "panelRelX")
                UserDefaults.standard.removeObject(forKey: "panelRelY")
                guard let self, self.panel.isVisible else { return }
                self.positioningProgrammatically = true
                self.positionAtDefault(on: self.activeScreen())
                self.positioningProgrammatically = false
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

    /// 唤起瞬间读取原应用焦点元素的选中文本（U1）。
    /// 密码框不读；超长选区不带入；0.25s 超时防止繁忙应用卡住唤起
    private static func capturedSelection(from app: NSRunningApplication?) -> String? {
        guard let pid = app?.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focusedAny = focusedRef,
            CFGetTypeID(focusedAny) == AXUIElementGetTypeID() else { return nil }
        let element = focusedAny as! AXUIElement
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == "AXSecureTextField" { return nil }
        var selectionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selectionRef) == .success,
            let text = selectionRef as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4000 else { return nil }
        return trimmed
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
        panel.layoutIfNeeded()
        positioningProgrammatically = true
        let screen = activeScreen()
        if let origin = savedRelativeOrigin(on: screen) {
            panel.setFrameOrigin(origin) // 用户习惯的相对位置，应用到当前工作屏
        } else {
            positionAtDefault(on: screen)
        }
        positioningProgrammatically = false

        // 教学模式：预填示例草稿，用户只需按回车
        if Tutorial.active, model.draft.isEmpty {
            model.draft = model.t(
                "帮我看下周三下午的会议室还有没有空的想约三点开个评审会",
                "hey can u check if theres any meeting room free next wed afternoon, wanna book 3pm for a review, like an hour, 8 ppl")
        } else if model.draft.isEmpty,
                  let selection = Self.capturedSelection(from: previousApp) {
            // 原应用有选中文本：自动带入草稿——「选中→唤起→回车」三步完成改写
            model.draft = selection
        }
        model.panelVisible = true
        // G 入场：窗口从透明淡入（150ms ease-out），内容层同步缩放聚焦
        fadeGeneration += 1
        panel.alphaValue = 0
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "PolishPad panel visible — keep animations running")
        }
        panel.makeKeyAndOrderFront(nil)
        // 默认开启语音：唤起面板即进入听写（教学模式除外）
        if !Tutorial.active, !model.isRecording,
           ConfigStore.loadRaw()?.autoStartDictation ?? false {
            model.toggleDictation()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.2, 0.8, 0.3, 1)
            panel.animator().alphaValue = 1
        }
        NSApp.activate(ignoringOtherApps: true)
        model.bumpFocus()
    }

    /// 退场：120ms 淡出后再真正隐藏；期间若重新唤起则作废
    private func fadeOutAndOrderOut() {
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                guard generation == self.fadeGeneration else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    private func endVisibilityActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    /// 当前"工作屏"：前台应用焦点窗口所在屏（打字/粘贴发生地）优先，
    /// 取不到退回鼠标所在屏，再退回主屏
    private func activeScreen() -> NSScreen? {
        if let app = previousApp ?? NSWorkspace.shared.frontmostApplication {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString,
                                             &winRef) == .success,
               let win = winRef, CFGetTypeID(win) == AXUIElementGetTypeID() {
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                var pos = CGPoint.zero
                var size = CGSize.zero
                let winEl = win as! AXUIElement
                if AXUIElementCopyAttributeValue(winEl, kAXPositionAttribute as CFString,
                                                 &posRef) == .success,
                   AXUIElementCopyAttributeValue(winEl, kAXSizeAttribute as CFString,
                                                 &sizeRef) == .success,
                   let p = posRef, let s2 = sizeRef,
                   CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s2) == AXValueGetTypeID() {
                    AXValueGetValue(p as! AXValue, .cgPoint, &pos)
                    AXValueGetValue(s2 as! AXValue, .cgSize, &size)
                    // AX 坐标系：原点在主屏左上、y 向下；AppKit：原点在主屏
                    // 左下、y 向上。用主屏高度换算（副屏坐标随主屏基准平移）
                    let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
                    let center = NSPoint(x: pos.x + size.width / 2,
                                         y: primaryHeight - (pos.y + size.height / 2))
                    if let screen = NSScreen.screens.first(where: {
                        NSMouseInRect(center, $0.frame, false)
                    }) {
                        return screen
                    }
                }
            }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
    }

    /// 拖动后记忆：面板中心在所在屏 visibleFrame 内的相对比例——
    /// 同一个"位置感"适用于任何尺寸的屏幕
    private func storeRelativeOrigin() {
        let frame = panel.frame
        guard let screen = NSScreen.screens.first(where: {
            $0.visibleFrame.intersects(frame)
        }) else { return }
        let visible = screen.visibleFrame
        let relX = (frame.midX - visible.minX) / visible.width
        let relY = (frame.midY - visible.minY) / visible.height
        UserDefaults.standard.set(Double(relX), forKey: "panelRelX")
        UserDefaults.standard.set(Double(relY), forKey: "panelRelY")
        // 老的绝对坐标记忆退役
        UserDefaults.standard.removeObject(forKey: "panelOriginX")
        UserDefaults.standard.removeObject(forKey: "panelOriginY")
    }

    /// 相对位置记忆套用到指定屏幕（含出界夹紧）；兼容迁移旧绝对坐标
    private func savedRelativeOrigin(on screen: NSScreen?) -> NSPoint? {
        guard let screen else { return nil }
        let defaults = UserDefaults.standard
        // 一次性迁移：旧绝对坐标 → 换算相对值
        if defaults.object(forKey: "panelRelX") == nil,
           defaults.object(forKey: "panelOriginX") != nil {
            let old = NSRect(x: defaults.double(forKey: "panelOriginX"),
                             y: defaults.double(forKey: "panelOriginY"),
                             width: panel.frame.width, height: panel.frame.height)
            if let oldScreen = NSScreen.screens.first(where: {
                $0.visibleFrame.intersects(old)
            }) {
                let v = oldScreen.visibleFrame
                defaults.set(Double((old.midX - v.minX) / v.width), forKey: "panelRelX")
                defaults.set(Double((old.midY - v.minY) / v.height), forKey: "panelRelY")
            }
            defaults.removeObject(forKey: "panelOriginX")
            defaults.removeObject(forKey: "panelOriginY")
        }
        guard defaults.object(forKey: "panelRelX") != nil else { return nil }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        var origin = NSPoint(
            x: visible.minX + visible.width * defaults.double(forKey: "panelRelX")
                - size.width / 2,
            y: visible.minY + visible.height * defaults.double(forKey: "panelRelY")
                - size.height / 2)
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        return origin
    }

    /// 默认位置：指定屏幕上类 Spotlight（水平居中，偏上）
    private func positionAtDefault(on screen: NSScreen?) {
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + frame.height * 0.72 - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func hide() {
        model.panelVisible = false
        endVisibilityActivity()
        model.stopDictation()
        // 与 Esc/红点语义一致：关窗即取消进行中的请求——
        // 否则请求在后台跑完会静默覆盖用户剪贴板
        model.cancelRequest()
        fadeOutAndOrderOut()
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
        model.panelVisible = false
        endVisibilityActivity()
        model.stopDictation()
        fadeOutAndOrderOut()
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
