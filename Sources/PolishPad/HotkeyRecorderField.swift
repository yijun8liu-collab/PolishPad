import AppKit
import SwiftUI

extension Notification.Name {
    /// 录制期间暂停全局热键，避免按到当前组合时触发功能
    static let polishPadSuspendHotkeys = Notification.Name("PolishPad.suspendHotkeys")
    static let polishPadResumeHotkeys = Notification.Name("PolishPad.resumeHotkeys")
}

/// 录制状态协调器。状态必须放在行视图之外：
/// 分组 Form 底层是 List，行视图会被重建，行内 @State 会丢失。
@MainActor
final class HotkeyRecorderCoordinator: ObservableObject {
    @Published private(set) var activeLabel: String?
    private var monitor: Any?
    private var onCapture: ((String) -> Void)?
    private var startedAt = Date.distantPast

    func toggle(_ label: String, onCapture: @escaping (String) -> Void) {
        if activeLabel == label {
            // 一次点击可能触发两次动作（List 行的已知行为），300ms 内的重复触发忽略
            guard Date().timeIntervalSince(startedAt) > 0.3 else { return }
            stop()
        } else {
            start(label, onCapture: onCapture)
        }
    }

    private func start(_ label: String, onCapture: @escaping (String) -> Void) {
        stop()
        NotificationCenter.default.post(name: .polishPadSuspendHotkeys, object: nil)
        self.onCapture = onCapture
        activeLabel = label
        startedAt = Date()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil // 录制期间吞掉按键
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if activeLabel != nil {
            activeLabel = nil
            onCapture = nil
            NotificationCenter.default.post(name: .polishPadResumeHotkeys, object: nil)
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { // Esc 取消
            stop()
            return
        }
        guard let keyName = GlobalHotKey.keyName(forCode: UInt32(event.keyCode)) else {
            NSSound.beep()
            return
        }
        var mods: [String] = []
        if event.modifierFlags.contains(.control) { mods.append("ctrl") }
        if event.modifierFlags.contains(.option) { mods.append("option") }
        if event.modifierFlags.contains(.shift) { mods.append("shift") }
        if event.modifierFlags.contains(.command) { mods.append("cmd") }
        guard !mods.isEmpty else {
            NSSound.beep() // 全局快捷键至少要一个修饰键
            return
        }
        let spec = (mods + [keyName]).joined(separator: "+")
        onCapture?(spec)
        stop()
    }
}

/// 快捷键录制行：点击按钮后直接按下组合键完成设置
struct HotkeyRecorderField: View {
    let label: String
    @Binding var spec: String
    @ObservedObject var coordinator: HotkeyRecorderCoordinator

    private var isRecording: Bool {
        coordinator.activeLabel == label
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Button(isRecording
                   ? UILang.t("按下快捷键…（Esc 取消）", "Press shortcut… (Esc cancels)")
                   : prettify(spec)) {
                coordinator.toggle(label) { spec = $0 }
            }
            .controlSize(.small)
            .tint(isRecording ? Color.accentColor : nil)
        }
    }

    /// "ctrl+option+p" → "⌃⌥P"
    private func prettify(_ spec: String) -> String {
        let symbols: [String: String] = [
            "ctrl": "⌃", "control": "⌃",
            "option": "⌥", "opt": "⌥", "alt": "⌥",
            "shift": "⇧",
            "cmd": "⌘", "command": "⌘",
        ]
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return spec }
        let mods = parts.dropLast().compactMap { symbols[$0] }.joined()
        let key = parts.last == "space" ? "Space" : parts.last!.uppercased()
        return mods + key
    }
}
