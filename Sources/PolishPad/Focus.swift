import AppKit
import ApplicationServices

/// 焦点元素追踪：把"粘回哪个应用"细化到"粘回哪个输入框"。
/// 解决：唤起前点了别处、等待期间切了窗口、同应用内焦点漂移等盲贴问题。
/// 注意：AX 调用可能逐个顶满超时（慢应用），必须允许在后台线程执行，
/// 绝不能让轮询把主线程榨干
enum FocusTracker {
    struct Target {
        let element: AXUIElement
        let pid: pid_t
        let role: String
        let frame: CGRect
    }

    /// AX 调用对卡死应用的默认超时很长，会周期性拖住主线程——统一设短超时
    private static let axTimeout: Float = 0.3

    /// 已置过唤醒开关的进程（Chromium 唤醒需 ~1s 预热，靠轮询后续 tick 收获）
    nonisolated(unsafe) private static var wokenPIDs = Set<pid_t>()
    private static let wokenLock = NSLock()

    /// 记录当前系统焦点元素（需要辅助功能权限；未授权返回 nil 走旧行为）
    static func captureFocused() -> Target? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axTimeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        if status != .success || value == nil
            || CFGetTypeID(value!) != AXUIElementGetTypeID() {
            // Chromium/Electron（Slack、Chrome…）惰性可访问性：不唤醒查不到焦点。
            // 置唤醒开关（每进程一次）+ 应用级焦点查询；首次可能仍为 nil，
            // 预热完成后（约 1 秒）的下一次调用即可命中
            guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
            value = queryAppFocus(pid: front.processIdentifier)
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return buildTarget(from: value as! AXUIElement)
    }

    /// 查询任意应用当前内部聚焦的元素——应用不在前台也有效。
    /// 这是"提交时确认目标"的基石：不依赖轮询抓拍瞬时焦点
    static func focusedElement(inAppWithPID pid: pid_t) -> Target? {
        guard AXIsProcessTrusted() else { return nil }
        guard let value = queryAppFocus(pid: pid),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return buildTarget(from: value as! AXUIElement)
    }

    private static func buildTarget(from element: AXUIElement) -> Target {
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

    private static func queryAppFocus(pid: pid_t) -> CFTypeRef? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)
        wokenLock.lock()
        let alreadyWoken = wokenPIDs.contains(pid)
        if !alreadyWoken { wokenPIDs.insert(pid) }
        wokenLock.unlock()
        if !alreadyWoken {
            // Electron 认 AXManualAccessibility；Chrome 认 AXEnhancedUserInterface
            AXUIElementSetAttributeValue(
                appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(
                appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &value)
        return status == .success ? value : nil
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
        "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField",
    ]

    /// 容器级元素上限：整页 AXWebArea/巨型容器不是输入框，
    /// ⌘V 发过去会落空还误导目标提示
    private static let maxTargetArea: CGFloat = 1_000_000

    static func isTextLike(_ target: Target?) -> Bool {
        guard let target else { return false }
        // 密码框绝不能作为粘贴目标
        if target.role == "AXSecureTextField" { return false }
        // 网页容器不是输入框（真正的 web 输入框会暴露为 AXTextArea/AXTextField）
        if target.role == "AXWebArea" { return false }
        // 尺寸守卫：占了大半个屏幕的"元素"是容器
        let area = target.frame.width * target.frame.height
        if area > maxTargetArea { return false }
        if textRoles.contains(target.role) { return true }
        // 角色不认识时兜底：支持文本选区属性的一般是可输入元素（终端、自绘控件）
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            target.element, kAXSelectedTextAttribute as CFString, &value) == .success
    }

    enum TargetKind {
        case textField   // 明确的输入框：元素级精确操作
        case container   // 网页/组容器（Chromium AX 焦点摆动的常态）：应用级信任
        case control     // 按钮等明确非文本控件：拒绝粘贴
    }

    static func kind(of target: Target?) -> TargetKind {
        guard let target else { return .container }
        if isTextLike(target) { return .textField }
        if target.role == "AXWebArea" || target.role == "AXGroup"
            || target.role.isEmpty
            || target.frame.width * target.frame.height > maxTargetArea {
            return .container
        }
        return .control
    }

    /// 把焦点恢复到记录的元素。返回 true = 可以安全粘贴。
    /// 分层信任：
    /// - 没捕获到目标（无权限等）/ 目标是容器类（Chromium 的 DOM 焦点
    ///   自管理很好，⌘V 会正确路由）：应用级放行
    /// - 目标是明确的非文本控件（按钮/图标等）：拒绝，调用方走"仅复制"
    /// - 目标是输入框：精确恢复；恢复不了但当前焦点合理（文本框/容器）也放行，
    ///   只有当前焦点明确落在非文本控件上才拒绝
    /// 目标元素的实时屏幕区域
    static func liveFrame(of target: Target) -> CGRect {
        frameOf(target.element)
    }

    /// 唤醒开关失效时重置（下次查询重新唤醒该进程）
    static func forgetWake(pid: pid_t) {
        wokenLock.lock()
        wokenPIDs.remove(pid)
        wokenLock.unlock()
    }

    /// 规范化文本用于内容比较：剥掉全部空白与零宽/不可见字符，
    /// 只留"可见内容骨架"——格式漂移不影响判定，真实增删改必然打破匹配
    static func canonical(_ text: String) -> String {
        let invisible: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}",
                                         "\u{FEFF}", "\u{2060}", "\u{FFFC}"]
        return String(text.filter { char in
            !char.isWhitespace && !char.isNewline && !invisible.contains(char)
        })
    }

    /// 目标输入框的光标位置（UTF-16 偏移，选区取末端；不可读返回 nil）
    static func caretLocation(of target: Target?) -> Int? {
        guard let target else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            target.element, kAXSelectedTextRangeAttribute as CFString,
            &rangeRef) == .success,
            let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range.location + range.length
    }

    /// 读取目标输入框的当前文本内容（不可读返回 nil）
    static func value(of target: Target?) -> String? {
        guard let target else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            target.element, kAXValueAttribute as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }

    /// 替换旧文本的策略
    enum ReplaceStrategy {
        case selected     // 已精确选中旧文本，⌘V 直接替换选区
        case backspaces   // 值不可读（终端）或旧文本恰在末尾：退格删除
        case insertOnly   // 旧文本找不到/位置不安全：绝不删除，只追加
    }

    /// 精确定位并选中上次贴入的文本。删除的安全层级：
    /// 能选中 > 末尾退格 > 不删只贴，绝不从任意位置盲删
    static func prepareReplace(of text: String, in target: Target?) -> ReplaceStrategy {
        guard let target else { return .backspaces }
        var valueRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            target.element, kAXValueAttribute as CFString, &valueRef)
        guard status == .success, let value = valueRef as? String else {
            return .backspaces // 值不可读（终端等）：退格是唯一手段
        }
        guard let range = value.range(of: text, options: .backwards) else {
            return .insertOnly // 旧文本已被用户改掉：绝不乱删
        }
        // 尝试把旧文本精确选中，⌘V 替换选区
        let utf16 = value.utf16
        if let lower = range.lowerBound.samePosition(in: utf16) {
            let location = utf16.distance(from: utf16.startIndex, to: lower)
            var cfRange = CFRange(location: location, length: text.utf16.count)
            if let axRange = AXValueCreate(.cfRange, &cfRange),
               AXUIElementSetAttributeValue(
                   target.element, kAXSelectedTextRangeAttribute as CFString,
                   axRange) == .success {
                var selectedRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    target.element, kAXSelectedTextAttribute as CFString,
                    &selectedRef) == .success,
                    (selectedRef as? String) == text {
                    return .selected
                }
            }
        }
        // 选不中：只有旧文本恰好在值末尾时，末尾退格才是安全的
        return value.hasSuffix(text) ? .backspaces : .insertOnly
    }

    /// avoidRect：面板的屏幕区域（AX 顶左坐标系）——补点击绝不能点到面板自己
    static func ensureFocus(_ target: Target?, avoiding avoidRect: CGRect? = nil) async -> Bool {
        guard let target else { return true }
        switch kind(of: target) {
        case .control:
            return false
        case .container:
            return true
        case .textField:
            break
        }
        AXUIElementSetAttributeValue(
            target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Chromium 的 AXFocused 读数与真实 DOM 焦点不是一回事（实测会谎报 true），
        // 网页还常在浏览器失活时 blur 输入框——所以对输入框目标一律像人一样
        // 真实点击一次（实时坐标），再 ⌘↓ 把光标移到末尾，然后才允许粘贴
        let liveFrame = frameOf(target.element)
        let center = CGPoint(x: liveFrame.midX, y: liveFrame.midY)
        let overlapsPanel = avoidRect?.contains(center) ?? false
        Diag.log("ENSURE liveFrame=\(Int(liveFrame.minX)),\(Int(liveFrame.minY)),\(Int(liveFrame.width))x\(Int(liveFrame.height)) overlapsPanel=\(overlapsPanel)")
        if liveFrame.width > 2, liveFrame.height > 2, !overlapsPanel {
            // 用户可能特意把光标放在了某个位置——点击前记住，点击后恢复
            var savedRange: CFTypeRef?
            let hasSavedRange = AXUIElementCopyAttributeValue(
                target.element, kAXSelectedTextRangeAttribute as CFString,
                &savedRange) == .success
            await MainActor.run {
                KeySimulator.postClick(at: center)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            var caretRestored = false
            if hasSavedRange, let savedRange,
               AXUIElementSetAttributeValue(
                   target.element, kAXSelectedTextRangeAttribute as CFString,
                   savedRange) == .success {
                caretRestored = true
            }
            if !caretRestored {
                await MainActor.run {
                    KeySimulator.postCommandKey(125) // ⌘↓：光标到末尾（兜底）
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            Diag.log("ENSURE force-clicked caretRestored=\(caretRestored)")
            return true
        }

        guard let now = captureFocused() else { return true }
        if sameTarget(now, target) { return true }
        return kind(of: now) != .control
    }
}
