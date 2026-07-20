import AppKit
import SwiftUI

extension Notification.Name {
    /// 录制期间暂停全局热键，避免按到当前组合时触发功能
    static let polishPadSuspendHotkeys = Notification.Name("PolishPad.suspendHotkeys")
    static let polishPadResumeHotkeys = Notification.Name("PolishPad.resumeHotkeys")
    /// 开始新录制前让其他录制框退出录制态
    static let polishPadStopRecorders = Notification.Name("PolishPad.stopRecorders")
}

/// 快捷键录制框：点击后直接按下组合键完成设置
struct HotkeyRecorderField: View {
    let label: String
    @Binding var spec: String
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording
                     ? UILang.t("按下快捷键…（Esc 取消）", "Press shortcut… (Esc cancels)")
                     : prettify(spec))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isRecording ? .accentColor : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isRecording ? Color.accentColor : Color.clear)
                    )
                    // .plain 按钮默认只有文字字形可点击，把整个胶囊（含内边距和背景）变成热区
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .onReceive(NotificationCenter.default.publisher(for: .polishPadStopRecorders)) { _ in
            if isRecording { stopRecording() }
        }
        .onDisappear {
            if isRecording { stopRecording() }
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

    private func startRecording() {
        // 先让别的录制框退出（此时自己还未进入录制态，不受影响）
        NotificationCenter.default.post(name: .polishPadStopRecorders, object: nil)
        NotificationCenter.default.post(name: .polishPadSuspendHotkeys, object: nil)
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyEvent(event)
            return nil // 吞掉事件，不让它落到界面上
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        NotificationCenter.default.post(name: .polishPadResumeHotkeys, object: nil)
    }

    private func handleKeyEvent(_ event: NSEvent) {
        // Esc 取消录制
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        guard let keyName = GlobalHotKey.keyName(forCode: UInt32(event.keyCode)) else {
            NSSound.beep() // 不支持的按键
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
        spec = (mods + [keyName]).joined(separator: "+")
        stopRecording()
    }
}
