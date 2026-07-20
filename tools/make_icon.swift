// 生成 App 图标：蓝紫渐变圆角方块 + 白色 wand.and.stars
// 用法: swift tools/make_icon.swift <输出png路径>
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let pixels = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: pixels, height: pixels)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let size = CGFloat(pixels)

// macOS 风格：约 10% 留白的圆角方块
let inset: CGFloat = size * 0.098
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = rect.width * 0.225

ctx.saveGState()
let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(shape)
ctx.clip()

// 对角渐变：蓝 → 紫
let gradientColors = [
    CGColor(red: 0.26, green: 0.47, blue: 1.00, alpha: 1),
    CGColor(red: 0.46, green: 0.26, blue: 0.92, alpha: 1),
    CGColor(red: 0.58, green: 0.20, blue: 0.80, alpha: 1),
] as CFArray
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: gradientColors, locations: [0.0, 0.62, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY),
    options: []
)

// 顶部柔和高光，增加立体感
let highlight = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    highlight,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.midY),
    options: []
)
ctx.restoreGState()

// 白色魔法棒符号 + 阴影
func tintedSymbol(_ name: String, pointSize: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return nil }
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

if let wand = tintedSymbol("wand.and.stars", pointSize: 200) {
    let target = rect.width * 0.60
    let scale = target / max(wand.size.width, wand.size.height)
    let drawSize = NSSize(width: wand.size.width * scale, height: wand.size.height * scale)
    let origin = NSPoint(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()

    wand.draw(
        in: NSRect(origin: origin, size: drawSize),
        from: .zero, operation: .sourceOver, fraction: 1
    )
}

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
print("written: \(outputPath)")
