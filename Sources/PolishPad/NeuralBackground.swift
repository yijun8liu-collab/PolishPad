import SwiftUI

/// 神经脉冲粒子引擎：节点漂移 + 近距连线 + （等待时）脉冲沿连线传播。
/// 同一套系统服务两个状态：待机=低透明度氛围层，等待首字=亮起加速。
@MainActor
final class NeuralEngine {
    struct Node {
        var pos: CGPoint
        var vel: CGVector
        var phase: Double
    }
    struct Edge {
        let a: CGPoint
        let b: CGPoint
        let alpha: Double
        let i: Int
        let j: Int
    }
    struct Pulse {
        var i: Int
        var j: Int
        var t: Double
    }

    private(set) var nodes: [Node] = []
    private(set) var edges: [Edge] = []
    private(set) var pulses: [Pulse] = []
    private var lastTime: Date?
    private var seededSize: CGSize = .zero

    private let count = 24
    private let linkDistance: CGFloat = 105

    func step(to now: Date, in size: CGSize, surge: Bool) {
        guard size.width > 10, size.height > 10 else { return }
        if nodes.isEmpty || abs(size.width - seededSize.width) > 60
            || abs(size.height - seededSize.height) > 60 {
            seed(in: size)
        }
        let dt = min(now.timeIntervalSince(lastTime ?? now), 0.1)
        lastTime = now

        let speed: CGFloat = surge ? 26 : 12
        for k in nodes.indices {
            nodes[k].pos.x += nodes[k].vel.dx * speed * dt
            nodes[k].pos.y += nodes[k].vel.dy * speed * dt
            nodes[k].phase += dt * (surge ? 3.2 : 1.6)
            if nodes[k].pos.x < 0 || nodes[k].pos.x > size.width { nodes[k].vel.dx *= -1 }
            if nodes[k].pos.y < 0 || nodes[k].pos.y > size.height { nodes[k].vel.dy *= -1 }
        }

        var result: [Edge] = []
        for i in 0..<count {
            for j in (i + 1)..<count {
                let dx = nodes[i].pos.x - nodes[j].pos.x
                let dy = nodes[i].pos.y - nodes[j].pos.y
                let d = (dx * dx + dy * dy).squareRoot()
                if d < linkDistance {
                    result.append(Edge(
                        a: nodes[i].pos, b: nodes[j].pos,
                        alpha: Double(1 - d / linkDistance) * 0.16,
                        i: i, j: j))
                }
            }
        }
        edges = result

        // 脉冲只在等待时产生：沿随机连线奔跑
        if surge, pulses.count < 6, !edges.isEmpty, Double.random(in: 0...1) < 0.28 {
            let edge = edges.randomElement()!
            pulses.append(Pulse(i: edge.i, j: edge.j, t: 0))
        }
        for k in pulses.indices.reversed() {
            pulses[k].t += dt * 1.9
            if pulses[k].t >= 1 { pulses.remove(at: k) }
        }
        if !surge { pulses.removeAll() }
    }

    func pulsePoint(_ p: Pulse) -> CGPoint {
        let a = nodes[p.i].pos
        let b = nodes[p.j].pos
        return CGPoint(x: a.x + (b.x - a.x) * p.t, y: a.y + (b.y - a.y) * p.t)
    }

    private func seed(in size: CGSize) {
        seededSize = size
        nodes = (0..<count).map { _ in
            Node(pos: CGPoint(x: .random(in: 0...size.width),
                              y: .random(in: 0...size.height)),
                 vel: CGVector(dx: .random(in: -0.5...0.5),
                               dy: .random(in: -0.5...0.5)),
                 phase: .random(in: 0...(2 * .pi)))
        }
    }
}

/// 面板背景的神经网络层：铺满整个面板、不响应鼠标；
/// surge=true（等待首字）时亮起并发射脉冲
struct NeuralBackgroundView: View {
    var surge: Bool
    var light: Bool
    /// 面板隐藏时必须停掉 TimelineView，否则后台空转耗电
    var active: Bool

    @State private var engine = NeuralEngine()

    var body: some View {
        // 辅助功能"减弱动态效果"开启时不渲染
        if !active || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                Canvas { ctx, size in
                    engine.step(to: timeline.date, in: size, surge: surge)
                    // 暗色：亮蓝粒子；明亮：深墨蓝"蓝图"风（浅玻璃上要用深色墨水才可见）
                    let base = light
                        ? Color(red: 0.16, green: 0.24, blue: 0.48)
                        : Color(red: 0.62, green: 0.78, blue: 1.0)
                    let visibility: Double = light ? 2.6 : 2.0
                    let boost: Double = (surge ? 1.6 : 1.0) * visibility
                    let lineWidth: CGFloat = light ? 0.9 : 0.8

                    for edge in engine.edges {
                        var path = Path()
                        path.move(to: edge.a)
                        path.addLine(to: edge.b)
                        ctx.stroke(path, with: .color(base.opacity(min(edge.alpha * boost, 0.5))),
                                   lineWidth: lineWidth)
                    }
                    for node in engine.nodes {
                        let glow = 0.4 + 0.28 * sin(node.phase)
                        let r: CGFloat = surge ? 2.1 : 1.7
                        ctx.fill(
                            Path(ellipseIn: CGRect(
                                x: node.pos.x - r, y: node.pos.y - r,
                                width: r * 2, height: r * 2)),
                            with: .color(base.opacity(min(glow * boost * 0.55, 0.85))))
                    }
                    for pulse in engine.pulses {
                        let p = engine.pulsePoint(pulse)
                        let halo = CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11)
                        ctx.fill(Path(ellipseIn: halo),
                                 with: .color(base.opacity(0.30)))
                        let core = CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4)
                        let coreColor = light
                            ? Color(red: 0.12, green: 0.28, blue: 0.85)
                            : Color(red: 0.78, green: 0.9, blue: 1.0)
                        ctx.fill(Path(ellipseIn: core), with: .color(coreColor.opacity(0.95)))
                    }
                }
            }
            .allowsHitTesting(false)
            .opacity(surge ? 0.95 : 0.6)
            .animation(.easeInOut(duration: 0.4), value: surge)
        }
    }
}
