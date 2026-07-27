import AppKit
import ApplicationServices
import SwiftUI

extension Notification.Name {
    /// 教学回合完成（userInfo["text"] = 结果文本）
    static let polishPadTutorialResult = Notification.Name("PolishPad.tutorialResult")
    /// 新手引导完成/关闭（面板空态提示据此消失）
    static let polishPadOnboardingDone = Notification.Name("PolishPad.onboardingDone")
}

/// 教学模式全局开关：引导窗口第 3 步期间为 true。
/// 此时面板预填示例草稿、结果直接写入引导窗口的演示框（不发合成按键）
@MainActor
enum Tutorial {
    static var active = false
}

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.isReleasedWhenClosed = false
            window = w
        }
        guard let window else { return }
        window.title = UILang.t("欢迎使用 PolishPad", "Welcome to PolishPad")
        window.appearance = NSAppearance(
            named: UserDefaults.standard.bool(forKey: "lightTheme") ? .aqua : .darkAqua)
        let wasVisible = window.isVisible
        let hosting = NSHostingView(rootView: OnboardingView())
        window.setContentSize(hosting.fittingSize)
        window.contentView = hosting
        if !wasVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct OnboardingView: View {
    @State private var step = 1
    // 步骤 1
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelName = ""
    @State private var testing = false
    @State private var apiOK = false
    @State private var apiStatus = ""
    // 步骤 2
    @State private var axTrusted = AXIsProcessTrusted()
    // 步骤 3
    @State private var task1Done = false
    @State private var task2Done = false
    @State private var demoText = ""

    private let axTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var panelHotkeyLabel: String {
        prettyHotkey(ConfigStore.loadRaw()?.hotkey ?? "ctrl+option+p")
    }

    var body: some View {
        VStack(spacing: 16) {
            stepIndicator
            switch step {
            case 1: stepConnect
            case 2: stepPermission
            default: stepTutorial
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear(perform: prepare)
        .onDisappear { Tutorial.active = false }
        .onReceive(axTimer) { _ in
            axTrusted = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default
            .publisher(for: .polishPadTutorialResult)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            demoText = text
            if task1Done { task2Done = true } else { task1Done = true }
        }
    }

    // MARK: - 步骤指示器

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            stepDot(1, UILang.t("连接 AI", "Connect"))
            line
            stepDot(2, UILang.t("授权", "Permission"))
            line
            stepDot(3, UILang.t("上手", "Try it"))
        }
    }

    private var line: some View {
        Rectangle().fill(Color.primary.opacity(0.15))
            .frame(width: 26, height: 1)
    }

    private func stepDot(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(n < step ? Color.green.opacity(0.2)
                        : n == step ? Color.accentColor : Color.primary.opacity(0.08))
                    .frame(width: 20, height: 20)
                if n < step {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.green)
                } else {
                    Text("\(n)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(n == step ? .white : .secondary)
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(n == step ? .primary : .secondary)
        }
    }

    // MARK: - 步骤 1：连接 AI

    private var stepConnect: some View {
        VStack(spacing: 10) {
            Text(UILang.t("连接你的 AI 服务", "Connect your AI service"))
                .font(.system(size: 16, weight: .semibold))
            Text(UILang.t("任何 OpenAI 兼容端点都可以（DeepSeek / Moonshot / Ollama / 内部代理）",
                          "Any OpenAI-compatible endpoint works (DeepSeek / Moonshot / Ollama / proxy)"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            VStack(spacing: 8) {
                labeledField("Base URL", text: $baseURL, prompt: "https://api.deepseek.com/v1")
                labeledField("API Key", text: $apiKey, prompt: "sk-…", secure: true)
                labeledField(UILang.t("模型", "Model"), text: $modelName, prompt: "deepseek-chat")
            }
            if !apiStatus.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: apiOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(apiOK ? Color.green.opacity(0.8) : .red)
                    Text(apiStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            footer {
                Button(testing ? UILang.t("测试中…", "Testing…")
                       : UILang.t("测试连接", "Test Connection")) { testAPI() }
                    .disabled(testing)
                Button(UILang.t("下一步", "Next")) { advance(to: 2) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!apiOK)
            }
        }
    }

    private func labeledField(_ label: String, text: Binding<String>,
                              prompt: String, secure: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .trailing)
            if secure {
                SecureField("", text: text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("", text: text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - 步骤 2：辅助功能授权

    private var stepPermission: some View {
        VStack(spacing: 12) {
            Text(UILang.t("授予辅助功能权限", "Grant Accessibility permission"))
                .font(.system(size: 16, weight: .semibold))
            Text(UILang.t("PolishPad 需要它才能把结果自动粘贴回你的应用、以及划词原地替换",
                          "Needed to paste results back into your apps and replace selections in place"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 4) {
                Text(UILang.t("在弹出的系统设置里：隐私与安全性 → 辅助功能 → 打开 PolishPad 的开关。",
                              "In System Settings: Privacy & Security → Accessibility → enable PolishPad."))
                Text(UILang.t("这个权限只用于模拟粘贴和读取当前选中文本，不做任何其他事。",
                              "Used only to simulate paste and read the current selection — nothing else."))
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 12))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
            HStack(spacing: 6) {
                Circle()
                    .fill(axTrusted ? Color.green : Color.yellow)
                    .frame(width: 8, height: 8)
                Text(axTrusted
                     ? UILang.t("已授权", "Granted")
                     : UILang.t("等待授权中…（勾选后这里会自动变绿）",
                                "Waiting… (turns green automatically once enabled)"))
                    .font(.caption)
                    .foregroundColor(axTrusted ? .green : .secondary)
            }
            footer {
                Button(UILang.t("打开系统设置", "Open System Settings")) {
                    // 触发一次带提示的检查让应用出现在列表里，再直达面板
                    let options = [kAXTrustedCheckOptionPrompt
                        .takeUnretainedValue() as String: false] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    if let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(UILang.t("下一步", "Next")) { advance(to: 3) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!axTrusted)
            }
        }
    }

    // MARK: - 步骤 3：上手实战

    private var stepTutorial: some View {
        VStack(spacing: 12) {
            Text(UILang.t("30 秒上手", "Hands-on in 30 seconds"))
                .font(.system(size: 16, weight: .semibold))
            Text(UILang.t("跟着做两步，在下面的演示框里看到真实效果",
                          "Two quick tasks — watch real results land in the demo box below"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 9) {
                taskRow(done: task1Done, number: 1, content: UILang.t(
                    "按 \(panelHotkeyLabel) 唤起面板——我们已帮你填好一段口语化草稿，直接按 ↩",
                    "Press \(panelHotkeyLabel) — a rough draft is pre-filled; just hit ↩"))
                taskRow(done: task2Done, number: 2, content: UILang.t(
                    "结果出现后，按 ⇥ 切到「修改」，输入\u{201C}更正式\u{201D}再回车，看它原地进化",
                    "Then press ⇥ to switch to Edit, type \u{201C}more formal\u{201D} and hit ↩ again"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if demoText.isEmpty {
                    Text(UILang.t("结果会自动出现在这里…", "The result will appear here…"))
                        .foregroundColor(.secondary.opacity(0.6))
                } else {
                    Text(demoText)
                }
            }
            .font(.system(size: 12.5))
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.accentColor.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )
            footer {
                Button(UILang.t("重新演示", "Reset demo")) {
                    task1Done = false
                    task2Done = false
                    demoText = ""
                }
                Button(UILang.t("完成，开始使用", "Done — start using")) { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { Tutorial.active = true }
    }

    private func taskRow(done: Bool, number: Int, content: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.15))
                    .frame(width: 18, height: 18)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.green)
                } else {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
            Text(content)
                .font(.system(size: 12.5))
                .foregroundColor(done ? .secondary : .primary)
                .strikethrough(done)
        }
    }

    // MARK: - 通用

    private func footer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Button(UILang.t("跳过引导", "Skip")) { finish() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary.opacity(0.7))
                .font(.system(size: 12))
            Spacer()
            content()
        }
        .padding(.top, 6)
    }

    private func prepare() {
        let config = ConfigStore.loadRaw()
        baseURL = config?.baseURL ?? "https://api.deepseek.com/v1"
        modelName = config?.model ?? "deepseek-chat"
        let key = config?.apiKey ?? ""
        if !key.isEmpty, key != ConfigStore.placeholderKey,
           key != ConfigStore.keychainSentinel {
            apiKey = key
            apiOK = true
            apiStatus = UILang.t("已配置", "Configured")
            step = AXIsProcessTrusted() ? 3 : 2
        }
        axTrusted = AXIsProcessTrusted()
    }

    private func advance(to next: Int) {
        Tutorial.active = false
        step = next
    }

    private func testAPI() {
        guard var config = ConfigStore.loadRaw() ?? (try? ConfigStore.load()) else { return }
        config.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        config.maxTokens = 16
        testing = true
        apiStatus = ""
        Task { @MainActor in
            defer { testing = false }
            do {
                _ = try await LLMClient.complete(
                    messages: [ChatMessage(role: "user",
                                           content: "Reply with the single word: OK")],
                    config: config)
                apiOK = true
                apiStatus = UILang.t("连接成功", "Connection OK")
                // 通过即保存（保留配置其他字段）
                if var saved = ConfigStore.loadRaw() {
                    saved.baseURL = config.baseURL
                    saved.apiKey = config.apiKey
                    saved.model = config.model
                    ConfigStore.writeRaw(saved)
                }
            } catch {
                apiOK = false
                apiStatus = error.localizedDescription
            }
        }
    }

    private func finish() {
        Tutorial.active = false
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        NotificationCenter.default.post(name: .polishPadOnboardingDone, object: nil)
        NSApp.keyWindow?.close()
    }

    /// "ctrl+option+p" → "⌃⌥P"
    private func prettyHotkey(_ spec: String) -> String {
        let symbols: [String: String] = [
            "ctrl": "⌃", "control": "⌃", "option": "⌥", "opt": "⌥",
            "alt": "⌥", "shift": "⇧", "cmd": "⌘", "command": "⌘",
        ]
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        guard parts.count > 1 else { return spec }
        let mods = parts.dropLast().compactMap { symbols[$0] }.joined()
        let key = parts.last == "space" ? "Space" : parts.last!.uppercased()
        return mods + key
    }
}
