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

    /// 某文本区间在屏幕上的位置（光标处的字符矩形；不可用返回 nil）
    private static func boundsOfRange(
        _ rangeValue: AXValue, in element: AXUIElement
    ) -> CGRect? {
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue, &boundsRef) == .success,
            let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect
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
        // 1) 精确子串匹配
        if let range = value.range(of: text, options: .backwards) {
            let utf16 = value.utf16
            if let lower = range.lowerBound.samePosition(in: utf16) {
                let location = utf16.distance(from: utf16.startIndex, to: lower)
                let cfRange = CFRange(location: location, length: text.utf16.count)
                if selectAndVerify(cfRange, expecting: text,
                                   in: target.element, value: value) {
                    return .selected
                }
            }
            // 选不中：只有旧文本恰好在值末尾时，末尾退格才是安全的
            return value.hasSuffix(text) ? .backspaces : .insertOnly
        }
        // 2) 空白容错匹配：Slack 等富文本框会改写空白/换行（\n\n → \n 等），
        //    精确匹配失败时按非空白词块序列定位，选中 value 中的真实范围
        if let cfRange = fuzzyRange(of: text, in: value),
           selectAndVerify(cfRange, expecting: text,
                           in: target.element, value: value) {
            Diag.log("REPLACE fuzzy match at \(cfRange.location) len=\(cfRange.length)")
            return .selected
        }
        Diag.log("REPLACE no match value=\(value.count)ch text=\(text.count)ch")
        return .insertOnly // 旧文本已被用户改掉：绝不乱删
    }

    /// 选中 range 并核实选中的确实是目标文本（词块归一比较，容忍空白差异；
    /// 应用不支持读选中文本时改为读回选区位置核实）。
    /// 核实失败时把选区收拢回末尾——选区已被动过，不收回 ⌘V 会误吃错误选区
    private static func selectAndVerify(
        _ range: CFRange, expecting text: String,
        in element: AXUIElement, value: String
    ) -> Bool {
        var cfRange = range
        guard let axRange = AXValueCreate(.cfRange, &cfRange),
              AXUIElementSetAttributeValue(
                  element, kAXSelectedTextRangeAttribute as CFString,
                  axRange) == .success else { return false }
        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString,
            &selectedRef) == .success, let selected = selectedRef as? String {
            if selected == text || canonicalWords(selected) == canonicalWords(text) {
                return true
            }
        } else {
            var rangeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString,
                &rangeRef) == .success, let rangeRef,
                CFGetTypeID(rangeRef) == AXValueGetTypeID() {
                var readBack = CFRange()
                if AXValueGetValue(rangeRef as! AXValue, .cfRange, &readBack),
                   readBack.location == range.location,
                   readBack.length == range.length {
                    return true
                }
            }
        }
        var endRange = CFRange(location: value.utf16.count, length: 0)
        if let collapse = AXValueCreate(.cfRange, &endRange) {
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, collapse)
        }
        return false
    }

    /// 零宽字符：不参与词块内容比较
    private static let ignorableChars: Set<Character> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}",
    ]

    /// 按空白切词，记录每个词块在原文中的 UTF-16 起止位置
    private static func wordChunks(
        _ s: String
    ) -> [(norm: String, start: Int, end: Int)] {
        var result: [(norm: String, start: Int, end: Int)] = []
        var norm = ""
        var start = 0
        var offset = 0
        for ch in s {
            let width = String(ch).utf16.count
            if ch.isWhitespace {
                if !norm.isEmpty {
                    result.append((norm, start, offset))
                    norm = ""
                }
            } else if !ignorableChars.contains(ch) {
                if norm.isEmpty { start = offset }
                norm.append(ch)
            }
            offset += width
        }
        if !norm.isEmpty { result.append((norm, start, offset)) }
        return result
    }

    private static func canonicalWords(_ s: String) -> String {
        wordChunks(s).map(\.norm).joined(separator: " ")
    }

    /// 空白容错定位：按词块序列从后往前找 text 在 value 中的 UTF-16 范围
    private static func fuzzyRange(of text: String, in value: String) -> CFRange? {
        let needle = wordChunks(text).map(\.norm)
        let hay = wordChunks(value)
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            var matched = true
            for j in 0..<needle.count where hay[i + j].norm != needle[j] {
                matched = false
                break
            }
            if matched {
                let start = hay[i].start
                let end = hay[i + needle.count - 1].end
                return CFRange(location: start, length: end - start)
            }
            i -= 1
        }
        return nil
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

        // Chromium 的 AXFocused 读数不可信，网页还会在失活时 blur 输入框——
        // 对输入框目标一律像人一样真实点击。点击位置优先取用户光标所在
        // 字符的屏幕坐标：点击本身就落在用户的插入点上，不依赖选区恢复
        let liveFrame = frameOf(target.element)
        Diag.log("ENSURE liveFrame=\(Int(liveFrame.minX)),\(Int(liveFrame.minY)),\(Int(liveFrame.width))x\(Int(liveFrame.height))")
        if liveFrame.width > 2, liveFrame.height > 2 {
            var savedRange: CFTypeRef?
            let hasSavedRange = AXUIElementCopyAttributeValue(
                target.element, kAXSelectedTextRangeAttribute as CFString,
                &savedRange) == .success
                && savedRange != nil
                && CFGetTypeID(savedRange!) == AXValueGetTypeID()

            var clickPoint = CGPoint(x: liveFrame.midX, y: liveFrame.midY)
            var clickedAtCaret = false
            if hasSavedRange, let savedRange,
               let caretRect = boundsOfRange(savedRange as! AXValue, in: target.element),
               caretRect.height > 1,
               liveFrame.insetBy(dx: -4, dy: -4).contains(
                   CGPoint(x: caretRect.midX, y: caretRect.midY)) {
                clickPoint = CGPoint(
                    x: min(max(caretRect.midX, liveFrame.minX + 2), liveFrame.maxX - 2),
                    y: min(max(caretRect.midY, liveFrame.minY + 2), liveFrame.maxY - 2))
                clickedAtCaret = true
            }
            await MainActor.run {
                KeySimulator.postClick(at: clickPoint)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)

            var caretRestored = false
            if hasSavedRange, let savedRange,
               AXUIElementSetAttributeValue(
                   target.element, kAXSelectedTextRangeAttribute as CFString,
                   savedRange) == .success {
                caretRestored = true
            }
            // 只有既没能点在光标位置、又恢复不了选区时，才退到末尾兜底
            if !caretRestored, !clickedAtCaret {
                await MainActor.run {
                    KeySimulator.postCommandKey(125)
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            Diag.log("ENSURE clicked atCaret=\(clickedAtCaret) restored=\(caretRestored)")
            return true
        }

        guard let now = captureFocused() else { return true }
        if sameTarget(now, target) { return true }
        return kind(of: now) != .control
    }
}
