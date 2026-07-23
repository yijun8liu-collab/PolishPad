// PolishPad 核心链路冒烟测试（对应 FEATURES.md 的 F1/F16/F22/F24/F40）：
// 点击 TextEdit → 热键唤面板 → 贴草稿 → 回车 → 验证自动贴回 →
// 反馈"改成英文" → 回车 → 验证原地替换、无重复。
// 运行前提：
//   1. PolishPad 已运行，热键为 ctrl+option+space（跟本机配置一致）
//   2. TextEdit 开着一个空文档
//   3. 机器空闲——运行期间不要动键盘鼠标（测试发的是真实点击/按键）
// 运行：swift tools/verify_baseline.swift
import AppKit
import ApplicationServices
func sleepMs(_ ms: Int) { usleep(useconds_t(ms * 1000)) }
func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = flags
    let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = flags
    d?.post(tap: .cghidEventTap); sleepMs(30); u?.post(tap: .cghidEventTap); sleepMs(150)
}
func click(_ p: CGPoint) {
    let src = CGEventSource(stateID: .combinedSessionState)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    sleepMs(30)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    sleepMs(200)
}
func axAttr(_ el: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil
}
func axRole(_ el: AXUIElement) -> String { (axAttr(el, kAXRoleAttribute) as? String) ?? "" }
func axKids(_ el: AXUIElement) -> [AXUIElement] { (axAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func axFrame(_ el: AXUIElement) -> CGRect {
    var r = CGRect.zero
    if let p = axAttr(el, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID() {
        var pt = CGPoint.zero; AXValueGetValue(p as! AXValue, .cgPoint, &pt); r.origin = pt
    }
    if let s = axAttr(el, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() {
        var sz = CGSize.zero; AXValueGetValue(s as! AXValue, .cgSize, &sz); r.size = sz
    }
    return r
}
func app(_ bundleID: String) -> AXUIElement? {
    guard let a = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
    else { return nil }
    return AXUIElementCreateApplication(a.processIdentifier)
}
func mainTextArea(_ bundleID: String) -> AXUIElement? {
    guard let appEl = app(bundleID),
          let wins = axAttr(appEl, kAXWindowsAttribute) as? [AXUIElement], let win = wins.first
    else { return nil }
    var areas: [AXUIElement] = []
    var queue: [(AXUIElement, Int)] = [(win, 0)]
    while !queue.isEmpty {
        let (el, d) = queue.removeFirst()
        if axRole(el) == "AXTextArea" { areas.append(el) }
        if d < 10 { queue.append(contentsOf: axKids(el).map { ($0, d + 1) }) }
    }
    return areas.max { axFrame($0).width * axFrame($0).height < axFrame($1).width * axFrame($1).height }
}
func value(_ el: AXUIElement?) -> String { el.flatMap { axAttr($0, kAXValueAttribute) as? String } ?? "" }
func panelUp() -> Bool {
    guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
    else { return false }
    return list.contains {
        ($0[kCGWindowOwnerName as String] as? String) == "PolishPad"
            && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 500
    }
}
func panelTexts() -> [String] {
    guard let a = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "PolishPad" })
    else { return [] }
    let appEl = AXUIElementCreateApplication(a.processIdentifier)
    guard let wins = axAttr(appEl, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
    var out: [String] = []
    var queue: [(AXUIElement, Int)] = wins.map { ($0, 0) }
    while !queue.isEmpty {
        let (el, d) = queue.removeFirst()
        if ["AXTextArea", "AXStaticText"].contains(axRole(el)),
           let v = axAttr(el, kAXValueAttribute) as? String, !v.isEmpty { out.append(v) }
        if d < 12 { queue.append(contentsOf: axKids(el).map { ($0, d + 1) }) }
    }
    return out
}
func clip(_ s: String) {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
}
func waitFor(_ sec: Int, _ cond: () -> Bool) -> Bool {
    for _ in 0..<(sec * 2) { if cond() { return true }; sleepMs(500) }
    return false
}
var failures: [String] = []
func check(_ n: String, _ ok: Bool, _ d: String = "") {
    print("\(ok ? "✅" : "❌") \(n)\(d.isEmpty ? "" : " — \(d)")")
    if !ok { failures.append(n) }
}

let te = "com.apple.TextEdit"
// 清空 TextEdit 文档：全选删除
guard let teArea = mainTextArea(te) else { print("❌ TextEdit 不可用"); exit(1) }
AXUIElementSetAttributeValue(teArea, kAXValueAttribute as CFString, "" as CFTypeRef)
sleepMs(300)
if panelUp() { key(49, flags: [.maskControl, .maskAlternate]); sleepMs(800) }

let f = axFrame(teArea)
click(CGPoint(x: f.midX, y: f.midY)); sleepMs(500)
check("TextEdit 已聚焦", NSWorkspace.shared.frontmostApplication?.bundleIdentifier == te)

key(49, flags: [.maskControl, .maskAlternate])
check("面板已唤起", waitFor(5) { panelUp() })
clip("帮我看下周三下午的会议室还有没有空的想约三点开个评审会")
key(9, flags: .maskCommand); sleepMs(500)
check("草稿进入面板", panelTexts().contains { $0.contains("评审会") })
key(36)
let pasted1 = waitFor(40) { value(mainTextArea(te)).count > 5 }
let v1Text = value(mainTextArea(te))
check("第1轮已自动贴回 TextEdit", pasted1, String(v1Text.prefix(50)))

// 第2轮：面板粘贴后自动回焦反馈框，直接 ⌘V+Enter
sleepMs(1000)
clip("改成英文")
key(9, flags: .maskCommand); sleepMs(500)
let fbIn = panelTexts().contains { $0.contains("改成英文") }
check("反馈进入面板", fbIn)
key(36)
let replaced = waitFor(40) {
    let v = value(mainTextArea(te))
    return v != v1Text && v.count > 5 && !v.contains("会议室")
}
let v2Text = value(mainTextArea(te))
check("第2轮已原地替换为英文", replaced, String(v2Text.prefix(60)))
check("没有重复残留", !v2Text.contains(v1Text.prefix(10)) || v1Text.isEmpty)

// 收尾：Esc 关面板
key(53); sleepMs(500)
if panelUp() { key(49, flags: [.maskControl, .maskAlternate]) }
print(failures.isEmpty ? "\n🎉 基线全部通过" : "\n💥 失败: \(failures)")
exit(failures.isEmpty ? 0 : 1)
