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
    /// 唤起时聚焦的具体输入框元素（粘贴前精确恢复焦点，防止盲贴）
    private var focusTarget: FocusTracker.Target?
    /// 本会话上一轮实际粘贴进目标应用的文本（原地替换时按其长度退格删除）
    private var lastPastedText: String?
    /// 面板打开期间轮询焦点：用户点进新输入框时切换粘贴目标
    private var focusPollTimer: Timer?
    /// 最后被激活的外部应用（提交时向它查询真实焦点元素）
    private var lastExternalApp: NSRunningApplication?

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
        model.onWillSubmit = { [weak self] in self?.refreshTargetFromLastApp() }
        // 事件驱动记录"最后使用的外部应用"：零遗漏，不依赖轮询抓拍
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.lastExternalApp = app }
        }
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
        pasteMemory = []
        previousApp = NSWorkspace.shared.frontmostApplication
        lastExternalApp = previousApp
        focusTarget = nil
        // AX 捕获放后台（Chromium 慢 AX 会卡住面板弹出），完成后回填
        Task.detached(priority: .userInitiated) { [weak self] in
            let captured = FocusTracker.captureFocused()
            await MainActor.run {
                guard let self else { return }
                self.focusTarget = captured
                // 唤起时焦点明确在非文本控件上：明示"完成后仅复制"。
                // 容器类（Chromium 常态）不提示——应用级粘贴仍会正确路由
                if ConfigStore.loadRaw()?.autoPaste ?? true,
                   captured != nil, FocusTracker.kind(of: captured) == .control {
                    self.model.pasteTargetNote = self.model.t(
                        "未检测到输入框 · 完成后仅复制",
                        "No text field · will copy only")
                }
            }
        }
        // 应用感知：按唤起前的前台应用自动选场景
        model.applyAutoPreset(
            bundleID: previousApp?.bundleIdentifier,
            appName: previousApp?.localizedName
        )

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
        startFocusTracking()
    }

    /// 本会话内"哪个输入框贴过什么"的记忆：切回旧框恢复替换语义，防止重复文本
    private var pasteMemory: [(target: FocusTracker.Target, pasted: String)] = []

    /// 面板打开期间跟踪焦点：用户点进别的输入框 = 切换粘贴目标
    private func startFocusTracking() {
        focusPollTimer?.invalidate()
        focusPollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollFocusedTarget() }
        }
    }

    private func stopFocusTracking() {
        focusPollTimer?.invalidate()
        focusPollTimer = nil
    }

    /// 防重入：AX 采集可能比轮询间隔还慢
    private var pollInFlight = false

    private func pollFocusedTarget() {
        guard panel.isVisible else { return }
        // 请求进行中冻结目标：本轮贴到提交时的输入框
        guard !model.isLoading, !pollInFlight else { return }
        pollInFlight = true
        // AX 采集放后台线程：慢应用的 AX 调用会逐个顶满超时，不能占主线程
        Task.detached(priority: .utility) { [weak self] in
            let captured = FocusTracker.captureFocused()
            await MainActor.run {
                self?.pollInFlight = false
                self?.handlePolledTarget(captured)
            }
        }
    }

    private func handlePolledTarget(_ captured: FocusTracker.Target?) {
        guard panel.isVisible, !model.isLoading else { return }
        guard let now = captured else { return }
        // 面板自身的编辑框不算目标
        guard now.pid != ProcessInfo.processInfo.processIdentifier else { return }
        // 只认有效输入框：点到桌面/按钮/菜单/密码框不切换、不丢失原目标
        guard FocusTracker.isTextLike(now) else { return }
        if let current = focusTarget, FocusTracker.sameTarget(current, now) {
            // 同一逻辑输入槽但元素对象已更换（web/Electron 重建 DOM）：刷新引用，
            // 否则后续 ensureFocus 拿着失效元素操作
            if !CFEqual(current.element, now.element) {
                focusTarget = now
            }
            return
        }
        switchTarget(to: now)
    }

    /// 提交那一刻确认真实目标：查询最后使用的外部应用"内部聚焦的元素"。
    /// 应用即使不在前台也记着自己的焦点，这个查询不依赖轮询能否抓到瞬时状态，
    /// 彻底解决"点了新输入框马上回面板打字"导致的目标未切换
    func refreshTargetFromLastApp() {
        guard let app = lastExternalApp, !app.isTerminated else { return }
        let pid = app.processIdentifier
        Task.detached(priority: .userInitiated) { [weak self] in
            // Chromium 的焦点报告会在容器/输入框之间摆动，单次采样可能
            // 恰好撞上容器态——重试直到问到真正的输入框（API 等待期内完成）
            var found: FocusTracker.Target?
            for attempt in 0..<4 {
                if let captured = FocusTracker.focusedElement(inAppWithPID: pid),
                   FocusTracker.isTextLike(captured) {
                    found = captured
                    break
                }
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            guard let now = found else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let current = self.focusTarget, FocusTracker.sameTarget(current, now) {
                    if !CFEqual(current.element, now.element) {
                        self.focusTarget = now
                    }
                    return
                }
                self.switchTarget(to: now)
            }
        }
    }

    /// 切换粘贴目标（会话上下文不动，只改结果去向）
    private func switchTarget(to now: FocusTracker.Target) {
        focusTarget = now
        let app = NSRunningApplication(processIdentifier: now.pid)
        previousApp = app
        // 恢复该输入框的粘贴记忆：贴过 → 替换语义；没贴过 → 插入语义
        if let memory = pasteMemory.first(where: { FocusTracker.sameTarget($0.target, now) }) {
            lastPastedText = memory.pasted
            model.hasAutoPasted = true
        } else {
            lastPastedText = nil
            model.hasAutoPasted = false
        }
        model.pasteTargetNote = model.t(
            "粘贴目标：\(app?.localizedName ?? "新输入框")",
            "Paste target: \(app?.localizedName ?? "new field")")
    }

    /// 记录/更新"当前目标贴了什么"
    private func rememberPaste(_ text: String?) {
        guard let text, let target = focusTarget else { return }
        if let index = pasteMemory.firstIndex(where: { FocusTracker.sameTarget($0.target, target) }) {
            pasteMemory[index] = (target, text)
        } else {
            pasteMemory.append((target, text))
        }
    }

    func hide() {
        stopFocusTracking()
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
                // 精确恢复到唤起时的输入框；恢复不了就不盲贴
                guard await FocusTracker.ensureFocus(self.focusTarget) else {
                    self.model.statusText = self.model.t(
                        "✅ 已复制（未检测到可用输入框，请手动粘贴）",
                        "✅ Copied (no usable text field — paste manually)")
                    HUD.shared.flashSuccess(UILang.t("已复制", "Copied"))
                    self.panel.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    self.model.bumpFocus()
                    return
                }
                let replacedOld = replacePrevious ? self.lastPastedText : nil
                await self.deletePreviousPasteIfNeeded(replacePrevious)
                KeySimulator.postCommandKey(KeySimulator.keyV)
                self.lastPastedText = NSPasteboard.general.string(forType: .string)
                self.rememberPaste(self.lastPastedText)
                ReplacementUndo.shared.record(
                    pasted: self.lastPastedText, replaced: replacedOld,
                    app: app, target: self.focusTarget)
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
            guard await FocusTracker.ensureFocus(self.focusTarget) else {
                HUD.shared.flashSuccess(UILang.t(
                    "已复制（未检测到可用输入框，请手动粘贴）",
                    "Copied (no usable text field — paste manually)"))
                return
            }
            let replacedOld = replacePrevious ? self.lastPastedText : nil
            await self.deletePreviousPasteIfNeeded(replacePrevious)
            KeySimulator.postCommandKey(KeySimulator.keyV)
            self.lastPastedText = NSPasteboard.general.string(forType: .string)
            ReplacementUndo.shared.record(
                pasted: self.lastPastedText, replaced: replacedOld,
                app: app, target: self.focusTarget)
            HUD.shared.flashSuccess(replacePrevious
                ? UILang.t("已替换", "Replaced")
                : UILang.t("已粘贴", "Pasted"))
        }
    }
}
