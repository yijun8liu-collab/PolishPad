import AppKit
import SwiftUI

/// 面板外组件（HUD/控制器）的文案本地化，跟随 中/EN 开关
enum UILang {
    static var isEnglish: Bool {
        UserDefaults.standard.bool(forKey: "outputEnglish")
    }

    static func t(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }
}

/// HUD 内容模型：更新文字时不重建视图、不改窗口几何——实时字幕稳定不跳
@MainActor
final class HUDModel: ObservableObject {
    @Published var text = ""
    @Published var style: HUDView.Style = .working
    @Published var light = false
    /// 听写波形：最近 12 帧的音量（0-1），滚动更新
    @Published var levels: [Float] = Array(repeating: 0, count: 12)
    /// 收束/绽放编舞状态（按住说话专用）
    @Published var bubbleScale: CGFloat = 1
    @Published var bubbleOpacity: Double = 1
    @Published var bubbleBlur: CGFloat = 0
    @Published var seedVisible = false
    @Published var pastedOK = false
}

/// 光标旁的悬浮状态提示：不抢焦点、不响应鼠标，用于划词优化的过程反馈。
/// 按住说话另有一套"气泡收放"编舞：说话（波形+字幕）→ 按下结束时
/// 预备-收束成光点 → 光点呼吸（润色中）→ LLM 首字到达时绽开
@MainActor
final class HUD {
    static let shared = HUD()

    private let panel: NSPanel
    private let model = HUDModel()
    /// 防止旧的自动隐藏计时器关掉新一轮的提示
    private var sessionToken = 0

    private init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
    }

    func showWorking(_ text: String) {
        sessionToken += 1
        present(text: text, style: .working)
    }

    /// 更新进行中的文字：同一视图原地换字，窗口几何纹丝不动（流式字幕稳定）
    func updateWorking(_ text: String) {
        guard panel.isVisible else { return }
        model.text = text
    }

    func flashSuccess(_ text: String) {
        sessionToken += 1
        let token = sessionToken
        present(text: text, style: .success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.sessionToken == token else { return }
            self.fadeOut()
        }
    }

    // MARK: - 按住说话编舞

    /// 第一幕：听写中（红点 + 实时波形 + 滚动字幕）
    func showListening(_ hint: String) {
        sessionToken += 1
        model.bubbleScale = 1
        model.bubbleOpacity = 1
        model.bubbleBlur = 0
        model.seedVisible = false
        model.pastedOK = false
        model.levels = Array(repeating: 0, count: 12)
        present(text: hint, style: .listening)
    }

    /// 麦克风音量喂给波形（0-1）
    func updateLevel(_ level: Float) {
        guard panel.isVisible, model.style == .listening else { return }
        var levels = model.levels
        levels.removeFirst()
        levels.append(min(1, level))
        model.levels = levels
    }

    /// 第二幕（V2 预备-收束）：先鼓一口气（+6%）再吸入成光点
    func condense() {
        guard panel.isVisible else { return }
        sessionToken += 1
        let token = sessionToken
        withAnimation(.easeOut(duration: 0.12)) {
            model.bubbleScale = 1.06
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.sessionToken == token else { return }
            withAnimation(.timingCurve(0.5, 0, 0.8, 0.4, duration: 0.42)) {
                self.model.bubbleScale = 0.04
                self.model.bubbleOpacity = 0
                self.model.bubbleBlur = 3
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.54) { [weak self] in
            guard let self, self.sessionToken == token else { return }
            self.model.seedVisible = true
        }
    }

    /// 第三幕：LLM 首字到达——从光点绽开（带轻微过冲），随后 updateWorking 流式换字
    func bloom(_ text: String) {
        guard panel.isVisible else { return }
        model.seedVisible = false
        model.style = .working
        model.text = text
        model.bubbleBlur = 0
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
            model.bubbleScale = 1
            model.bubbleOpacity = 1
        }
    }

    /// 贴入成功：绽开态原地变绿，1.2s 后淡出（不重建视图不跳几何）
    func successInPlace(_ text: String) {
        guard panel.isVisible else { return }
        sessionToken += 1
        let token = sessionToken
        model.pastedOK = true
        model.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.sessionToken == token else { return }
            self.fadeOut()
        }
    }

    func hide() {
        sessionToken += 1
        fadeOut()
    }

    private func fadeOut() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    private func present(text: String, style: HUDView.Style) {
        model.text = text
        model.style = style
        model.light = UserDefaults.standard.bool(forKey: "lightTheme")
        model.pastedOK = false
        let hosting = NSHostingView(rootView: HUDView(model: model))
        panel.contentView = hosting
        let size = hosting.fittingSize
        panel.setContentSize(size)

        // 显示在鼠标右下方，出界时夹回屏幕内
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y - size.height - 16)
        if let frame = screen?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
        // 淡入登场（120ms），不再瞬间蹦出
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }
}

struct HUDView: View {
    enum Style { case working, success, listening }

    @ObservedObject var model: HUDModel

    var body: some View {
        let light = model.light
        ZStack {
            bubble(light: light)
                .scaleEffect(model.bubbleScale)
                .opacity(model.bubbleOpacity)
                .blur(radius: model.bubbleBlur)
            if model.seedVisible {
                SeedView()
            }
        }
        // 固定画布：收束/光点/绽放全程窗口几何不变
        .frame(width: model.style == .success ? nil : 340, height: 44)
    }

    @ViewBuilder
    private func bubble(light: Bool) -> some View {
        HStack(spacing: 8) {
            switch model.style {
            case .working:
                if model.pastedOK {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(light ? .light : .dark)
                }
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .listening:
                Circle()
                    .fill(model.pastedOK ? Color.green : Color(red: 1, green: 0.37, blue: 0.34))
                    .frame(width: 8, height: 8)
                WaveBars(levels: model.levels)
            }
            // 尾部截断 + 单行：实时字幕始终显示最新内容，宽度恒定不跳
            Text(model.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(light ? Color.black.opacity(0.85) : .white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(minWidth: 60, maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(light ? Color.white.opacity(0.94) : Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(light ? 0.12 : 0))
        )
    }
}

/// 实时波形：12 根小竖条，高度随麦克风音量滚动
private struct WaveBars: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color(red: 0.44, green: 0.62, blue: 1.0))
                    .frame(width: 3, height: 4 + CGFloat(levels[i]) * 13)
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.09), value: levels)
    }
}

/// 光点：气泡的化身——呼吸脉动 + 每秒荡一圈微澜（"活着、在干活"）
private struct SeedView: View {
    @State private var pulse = false
    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity: Double = 0.7

    private let seedColor = Color(red: 0.56, green: 0.49, blue: 1.0)

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(seedColor, lineWidth: 1.5)
                .frame(width: 12, height: 12)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)
            Circle()
                .fill(RadialGradient(
                    colors: [.white, seedColor], center: .center,
                    startRadius: 1, endRadius: 6))
                .frame(width: 12, height: 12)
                .scaleEffect(pulse ? 1.35 : 0.7)
                .shadow(color: seedColor.opacity(pulse ? 0.85 : 0.5),
                        radius: pulse ? 11 : 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                ringScale = 4.5
                ringOpacity = 0
            }
        }
    }
}
