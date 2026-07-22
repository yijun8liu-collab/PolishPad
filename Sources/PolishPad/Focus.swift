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
        let frame: CGRect
    }

    /// AX 调用对卡死应用的默认超时很长，会周期性拖住主线程——统一设短超时
    private static let axTimeout: Float = 0.3

    /// 记录当前系统焦点元素（需要辅助功能权限；未授权返回 nil 走旧行为）
    static func captureFocused() -> Target? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        return Target(
            element: element, pid: pid,
            role: (roleValue as? String) ?? "",
            frame: frameOf(element)
        )
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        var point = CGPoint.zero
        var size = CGSize.zero
        if let posValue, CFGetTypeID(posValue) == AXValueGetTypeID() {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        }
        if let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: point, size: size)
    }

    /// 同一输入框判定：CFEqual 优先；部分应用（web/Electron）每次聚焦返回
    /// 不同的元素对象，用 pid+角色+屏幕位置 兜底，避免误判"新目标"
    static func sameTarget(_ a: Target, _ b: Target) -> Bool {
        if CFEqual(a.element, b.element) { return true }
        return a.pid == b.pid && a.role == b.role
            && a.frame != .zero && a.frame == b.frame
    }

    private static let textRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXWebArea",
    ]

    static func isTextLike(_ target: Target?) -> Bool {
        guard let target else { return false }
        // 密码框绝不能作为粘贴目标
        if target.role == "AXSecureTextField" { return false }
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
        if let now = captureFocused(), sameTarget(now, target) {
            return true
        }
        return isTextLike(captureFocused())
    }
}
