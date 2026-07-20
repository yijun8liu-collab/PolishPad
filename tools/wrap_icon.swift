// 把任意方形图片包装成 macOS 标准图标：透明画布 + 10% 留白 + 系统圆角遮罩
// 用法: swift tools/wrap_icon.swift <输入图片> <输出png>
import AppKit

guard CommandLine.arguments.count >= 3,
      let source = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    print("用法: swift wrap_icon.swift <输入图片> <输出png>")
    exit(1)
}
let outputPath = CommandLine.arguments[2]
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

let inset: CGFloat = size * 0.098
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = rect.width * 0.225

ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

// 轻微放大填充，让原图自带的圆角/白边落在裁切范围之外
let overscan: CGFloat = 1.04
let drawWidth = rect.width * overscan
let drawHeight = rect.height * overscan
let drawRect = NSRect(
    x: rect.midX - drawWidth / 2,
    y: rect.midY - drawHeight / 2,
    width: drawWidth,
    height: drawHeight
)
source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
print("written: \(outputPath)")
