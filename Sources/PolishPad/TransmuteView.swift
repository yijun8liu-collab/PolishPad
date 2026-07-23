import SwiftUI

/// 逐字符自动换行布局：settled 文字 + 光标 + 飘舞旧字符混排成一段连续文本
struct CharFlowLayout: Layout {
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 600, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let offsets = arrange(width: bounds.width, subviews: subviews).offsets
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + offsets[index].x,
                            y: bounds.minY + offsets[index].y),
                proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews)
        -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
        return (offsets, CGSize(width: width, height: y + lineHeight))
    }
}

/// 飘舞中的旧字符：微位移 + 旋转 + 模糊，节奏按序错落
private struct DriftChar: View {
    let ch: String
    let seed: Int

    @State private var floating = false

    private var dx: CGFloat { CGFloat((seed * 73) % 17) - 8 }
    private var dy: CGFloat { CGFloat((seed * 31) % 13) - 6 }
    private var rot: Double { Double((seed * 47) % 13) - 6 }

    var body: some View {
        Text(ch)
            .font(.system(size: 14.5))
            .foregroundColor(Color.secondary.opacity(floating ? 0.35 : 0.65))
            .blur(radius: floating ? 1.1 : 0)
            .rotationEffect(.degrees(floating ? rot : 0))
            .offset(x: floating ? dx : 0, y: floating ? dy : 0)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 2.2)
                        .repeatForever(autoreverses: true)
                        .delay(Double(seed % 20) * 0.09)
                ) { floating = true }
            }
    }
}

/// 原地逐字蜕变：定稿新文字从左往右生长（落定聚焦入场），
/// 右侧旧字符仍在飘舞；蜕变线扫过之处旧字翻转消散。
/// 等待首字阶段（output 为空）= 整段旧文字飘舞。
struct TransmuteView: View {
    /// 本轮开始前的旧文字（首轮=草稿，纠偏轮=上一版结果）
    let source: String
    /// 已流式到达的新文字
    let output: String

    @State private var cursorOn = true

    /// 旧字符按 1:1 节奏被消耗；输出更长时旧字提前耗尽自然收尾
    private var remainingSource: [(offset: Int, ch: String)] {
        let consumed = min(source.count, output.count)
        return source.dropFirst(consumed).enumerated()
            .map { ($0.offset + consumed, String($0.element)) }
    }

    var body: some View {
        ScrollView {
            CharFlowLayout(lineSpacing: 9) {
                    ForEach(Array(output.enumerated()), id: \.offset) { _, ch in
                        Text(String(ch))
                            .font(.system(size: 14.5))
                            .foregroundColor(.primary.opacity(0.9))
                            .transition(.asymmetric(
                                insertion: .scale(scale: 1.5).combined(with: .opacity),
                                removal: .identity))
                    }
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor.opacity(cursorOn ? 0.9 : 0.15))
                        .frame(width: 2, height: 16)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.45)
                                .repeatForever(autoreverses: true)) { cursorOn = false }
                        }
                    ForEach(remainingSource, id: \.offset) { item in
                        DriftChar(ch: item.ch, seed: item.offset)
                            .transition(.asymmetric(
                                insertion: .identity,
                                removal: .offset(y: -8).combined(with: .opacity)))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: output.count)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
