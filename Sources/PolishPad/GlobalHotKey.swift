import AppKit
import Carbon.HIToolbox

/// Carbon 全局快捷键（不需要辅助功能权限），支持多个实例：
/// 共享一个事件处理器，按 EventHotKeyID 分发到对应实例
final class GlobalHotKey {
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextId: UInt32 = 1
    private static var sharedHandlerInstalled = false

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    var handler: (() -> Void)?

    /// 解析 "option+space"、"cmd+shift+p" 这类描述
    static func parse(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let parts = spec.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last else { return nil }

        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "option", "opt", "alt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        guard modifiers != 0, let keyCode = Self.keyCodes[keyName] else { return nil }
        return (keyCode, modifiers)
    }

    /// 键码反查名称（快捷键录制用）
    static func keyName(forCode code: UInt32) -> String? {
        keyCodes.first { $0.value == code }?.key
    }

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49, "`": 50, "return": 36, "tab": 48,
    ]

    init?(keyCode: UInt32, modifiers: UInt32) {
        Self.installSharedHandlerIfNeeded()
        id = Self.nextId

        let hotKeyID = EventHotKeyID(signature: 0x504C_5348 /* 'PLSH' */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return nil }

        hotKeyRef = ref
        Self.nextId += 1
        Self.registry[id] = self
    }

    /// 显式注销。注册表对实例是强引用，等 deinit 自动注销永远不会发生——
    /// 热重载快捷键前必须先对旧实例调用本方法
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        handler = nil
        GlobalHotKey.registry[id] = nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }

    private static func installSharedHandlerIfNeeded() {
        guard !sharedHandlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    GlobalHotKey.registry[id]?.handler?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
        sharedHandlerInstalled = true
    }
}
