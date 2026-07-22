import AppKit
import ApplicationServices

/// 模拟按键（需要辅助功能权限）
enum KeySimulator {
    static let keyA: CGKeyCode = 0
    static let keyC: CGKeyCode = 8
    static let keyV: CGKeyCode = 9
    static let keyDelete: CGKeyCode = 51

    /// 发送 count 次退格。用于删除上一轮粘贴的文本——比 ⌘Z 可靠：
    /// 终端类应用（iTerm/Claude Code）不支持文本撤销，⌘Z 是空操作
    static func postBackspaces(_ count: Int) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        for i in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyDelete, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyDelete, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            // 分批喘口气，避免事件洪峰压垮目标应用
            if i % 40 == 39 {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    /// 检查辅助功能权限，未授权时弹出系统引导框
    static func ensureAccessibilityPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 在屏幕坐标发一次真实左键点击
    static func postClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static func postCommandKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

/// 剪贴板完整快照：抓取/回贴借用了用户剪贴板，用完必须原样恢复（含图片等非文本内容）
struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture() -> ClipboardSnapshot {
        let snapshot = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy[type] = data
                }
            }
            return copy
        }
        return ClipboardSnapshot(items: snapshot)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

/// 流式进度节流：跨线程回调安全，每累积约 40 字放行一次
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReported = 0

    func shouldReport(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count - lastReported >= 40 else { return false }
        lastReported = count
        return true
    }
}

/// 划词优化：抓取前台应用的选中文本（或全选），优化后原地替换
@MainActor
final class QuickPolishController {
    enum Mode {
        case selection  // 优化当前选中文本
        case all        // 先模拟 ⌘A 全选再优化
    }

    enum State {
        case idle, working, success
    }

    private(set) var isBusy = false
    /// 状态变化回调（菜单栏图标反馈）
    var onStateChange: ((State) -> Void)?

    func trigger(_ mode: Mode) {
        guard !isBusy else {
            NSSound.beep()
            return
        }
        guard KeySimulator.ensureAccessibilityPermission() else {
            // 系统已弹出授权引导框；授权后重按快捷键即可
            return
        }
        isBusy = true
        Task {
            await run(mode)
            isBusy = false
        }
    }

    private func run(_ mode: Mode) async {
        onStateChange?(.working)
        let targetApp = NSWorkspace.shared.frontmostApplication
        let focusTarget = FocusTracker.captureFocused()
        HUD.shared.showWorking(mode == .all
            ? UILang.t("全选优化中…", "Refining all…")
            : UILang.t("优化中…", "Refining…"))

        // 用户触发快捷键时修饰键（⌃⌥）往往还按着，此时模拟 ⌘A/⌘C 会被
        // 叠加成 ⌘⌃⌥A 导致目标应用不响应——先等所有修饰键物理松开
        await waitForModifierRelease()

        let snapshot = ClipboardSnapshot.capture()
        let pasteboard = NSPasteboard.general

        if mode == .all {
            KeySimulator.postCommandKey(KeySimulator.keyA)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // 模拟 ⌘C 并轮询等待剪贴板变化（最多 1.5s）
        let countBefore = pasteboard.changeCount
        KeySimulator.postCommandKey(KeySimulator.keyC)
        var captured: String?
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if pasteboard.changeCount != countBefore {
                captured = pasteboard.string(forType: .string)
                break
            }
        }

        let input = captured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !input.isEmpty else {
            snapshot.restore()
            finishWithError(mode == .selection
                ? "没有捕获到选中文本。请确认已选中文字；如果刚授予辅助功能权限，请重启 PolishPad 后再试。"
                : "没有捕获到文本。目标输入框可能为空；如果刚授予辅助功能权限，请重启 PolishPad 后再试。")
            return
        }

        do {
            // 流式进度：每多收到约 40 字更新一次气泡，长文本下能看到进展
            let progress = ProgressThrottle()
            let output = try await LLMClient.polishOnce(input) { partial in
                let count = partial.count
                guard progress.shouldReport(count) else { return }
                Task { @MainActor in
                    HUD.shared.updateWorking(UILang.t("优化中… \(count) 字", "Refining… \(count) chars"))
                }
            }
            // 等 API 的这几秒里用户可能切走了窗口：先确认目标应用和输入框
            if let app = targetApp,
               NSWorkspace.shared.frontmostApplication?.processIdentifier
                   != app.processIdentifier {
                app.activate()
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier
                        == app.processIdentifier { break }
                    app.activate()
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            pasteboard.clearContents()
            pasteboard.setString(output, forType: .string)
            guard await FocusTracker.ensureFocus(focusTarget) else {
                // 回不到原输入框：结果留在剪贴板，绝不盲贴（不恢复快照）
                onStateChange?(.idle)
                HUD.shared.flashSuccess(UILang.t(
                    "已复制（原输入框不可用，请手动粘贴）",
                    "Copied (original field unavailable — paste manually)"))
                return
            }
            KeySimulator.postCommandKey(KeySimulator.keyV)
            ReplacementUndo.shared.record(
                pasted: output, replaced: input, app: targetApp, target: focusTarget)
            // 等目标应用完成粘贴后，恢复用户原来的剪贴板
            try? await Task.sleep(nanoseconds: 600_000_000)
            snapshot.restore()
            onStateChange?(.success)
            HUD.shared.flashSuccess(UILang.t("已替换", "Replaced"))
            NSSound(named: "Glass")?.play()
        } catch {
            snapshot.restore()
            finishWithError(error.localizedDescription)
        }
    }

    /// 等待用户松开全部修饰键（最多 1.5s）
    private func waitForModifierRelease() async {
        let modifierMask: CGEventFlags = [
            .maskCommand, .maskControl, .maskAlternate, .maskShift,
        ]
        for _ in 0..<30 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(modifierMask).isEmpty { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func finishWithError(_ message: String) {
        onStateChange?(.idle)
        HUD.shared.hide()
        NSSound(named: "Basso")?.play()
        let alert = NSAlert()
        alert.messageText = "优化替换失败"
        alert.informativeText = message + "\n\n原文未被修改，剪贴板已恢复原有内容。"
        alert.runModal()
    }
}
