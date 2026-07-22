import AppKit
import ApplicationServices

/// 焦点元素追踪：把"粘回哪个应用"细化到"粘回哪个输入框"。
/// 解决：唤起前点了别处、等待期间切了窗口、同应用内焦点漂移等盲贴问题
@MainActor
enum FocusTracker {
    struct Target {
        let element: AXUIElement
        let pid: pid_t
        let role: String
    }

    /// 记录当前系统焦点元素（需要辅助功能权限；未授权返回 nil 走旧行为）
    static func captureFocused() -> Target? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        return Target(element: element, pid: pid, role: (roleValue as? String) ?? "")
    }

    private static let textRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXWebArea",
    ]

    static func isTextLike(_ target: Target?) -> Bool {
        guard let target else { return false }
        if textRoles.contains(target.role) { return true }
        // 角色不认识时兜底：支持文本选区属性的一般是可输入元素（终端、自绘控件）
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            target.element, kAXSelectedTextAttribute as CFString, &value) == .success
    }

    /// 把焦点恢复到记录的元素。返回 true = 可以安全粘贴。
    /// - 没捕获到目标（无权限等）：放行，退回应用级旧行为
    /// - 唤起时就不在输入框：拒绝，调用方走"仅复制"
    /// - 元素找不回但当前焦点仍是文本类（应用自行恢复了合理焦点）：放行
    static func ensureFocus(_ target: Target?) async -> Bool {
        guard let target else { return true }
        guard isTextLike(target) else { return false }
        AXUIElementSetAttributeValue(
            target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 150_000_000)
        if let now = captureFocused(), CFEqual(now.element, target.element) {
            return true
        }
        return isTextLike(captureFocused())
    }
}
