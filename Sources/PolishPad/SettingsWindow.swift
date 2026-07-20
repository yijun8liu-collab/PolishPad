import AppKit
import SwiftUI

extension Notification.Name {
    static let polishPadOpenSettings = Notification.Name("PolishPad.openSettings")
    static let polishPadSettingsSaved = Notification.Name("PolishPad.settingsSaved")
}

/// 设置窗口：把 config.json 的所有可配置项整合成表单
struct SettingsView: View {
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelName = ""
    @State private var temperature = 0.3
    @State private var maxTokensText = "4096"
    @State private var hotkeyPanel = "ctrl+option+p"
    @State private var hotkeySelection = "ctrl+option+r"
    @State private var hotkeyAll = "ctrl+option+a"
    @State private var speechLocale = "zh-CN"
    @State private var autoPaste = true
    @State private var systemPrompt = ""
    @State private var showKey = false
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var testing = false
    @StateObject private var recorder = HotkeyRecorderCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(UILang.t("API 服务", "API Service")) {
                    TextField("Base URL", text: $baseURL, prompt: Text("https://api.deepseek.com/v1"))
                    HStack {
                        if showKey {
                            TextField("API Key", text: $apiKey)
                        } else {
                            SecureField("API Key", text: $apiKey)
                        }
                        Button(showKey ? UILang.t("隐藏", "Hide") : UILang.t("显示", "Show")) {
                            showKey.toggle()
                        }
                        .controlSize(.small)
                    }
                    TextField(UILang.t("模型", "Model"), text: $modelName, prompt: Text("deepseek-chat"))
                    HStack {
                        Text("Temperature")
                        Slider(value: $temperature, in: 0...2, step: 0.1)
                        Text(String(format: "%.1f", temperature))
                            .font(.caption.monospacedDigit())
                            .frame(width: 28)
                    }
                    TextField("Max Tokens", text: $maxTokensText)
                }

                Section(UILang.t("快捷键（保存后立即生效）", "Hotkeys (apply on save)")) {
                    HotkeyRecorderField(
                        label: UILang.t("润色窗口", "Polish panel"),
                        spec: $hotkeyPanel, coordinator: recorder)
                    HotkeyRecorderField(
                        label: UILang.t("划词润色替换", "Polish selection"),
                        spec: $hotkeySelection, coordinator: recorder)
                    HotkeyRecorderField(
                        label: UILang.t("全选润色替换", "Select-all polish"),
                        spec: $hotkeyAll, coordinator: recorder)
                    Text(UILang.t("点击后直接按下新的组合键（至少含一个修饰键）",
                                  "Click, then press the new combination (needs at least one modifier)"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(UILang.t("行为", "Behavior")) {
                    Toggle(UILang.t("润色后自动粘贴回原应用", "Auto-paste result back into the app"),
                           isOn: $autoPaste)
                    TextField(UILang.t("语音识别语言", "Speech locale"), text: $speechLocale,
                              prompt: Text("zh-CN"))
                }

                Section(UILang.t("系统提示词（留空使用内置双语版本）",
                                 "System prompt (empty = built-in bilingual)")) {
                    TextEditor(text: $systemPrompt)
                        .font(.system(size: 12))
                        .frame(height: 100)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                Button(testing ? UILang.t("测试中…", "Testing…") : UILang.t("测试连接", "Test Connection")) {
                    testConnection()
                }
                .disabled(testing)

                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(statusIsError ? .red : .secondary)
                    .lineLimit(2)

                Spacer()

                Button(UILang.t("打开配置文件", "Open Config File")) {
                    NSWorkspace.shared.open(ConfigStore.configURL)
                }
                Button(UILang.t("保存", "Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 540, height: 620)
        .onAppear(perform: load)
    }

    private func load() {
        guard let config = ConfigStore.loadRaw() else { return }
        baseURL = config.baseURL
        apiKey = config.apiKey == ConfigStore.placeholderKey ? "" : config.apiKey
        modelName = config.model
        temperature = config.temperature ?? 0.3
        maxTokensText = String(config.maxTokens ?? 4096)
        hotkeyPanel = config.hotkey ?? "ctrl+option+p"
        hotkeySelection = config.hotkeyPolishSelection ?? "ctrl+option+r"
        hotkeyAll = config.hotkeyPolishAll ?? "ctrl+option+a"
        speechLocale = config.speechLocale ?? "zh-CN"
        autoPaste = config.autoPaste ?? true
        systemPrompt = config.systemPrompt ?? ""
    }

    private func buildConfig() -> AppConfig {
        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppConfig(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: key.isEmpty ? ConfigStore.placeholderKey : key,
            model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            temperature: temperature,
            maxTokens: Int(maxTokensText.trimmingCharacters(in: .whitespaces)) ?? 4096,
            hotkey: hotkeyPanel.trimmingCharacters(in: .whitespaces),
            hotkeyPolishSelection: hotkeySelection.trimmingCharacters(in: .whitespaces),
            hotkeyPolishAll: hotkeyAll.trimmingCharacters(in: .whitespaces),
            systemPrompt: prompt.isEmpty ? nil : prompt,
            speechLocale: speechLocale.trimmingCharacters(in: .whitespaces),
            autoPaste: autoPaste
        )
    }

    private func save() {
        // 快捷键格式先行校验，避免保存后静默失效
        for spec in [hotkeyPanel, hotkeySelection, hotkeyAll] {
            let trimmed = spec.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, GlobalHotKey.parse(trimmed) == nil {
                statusMessage = UILang.t("快捷键「\(trimmed)」格式不正确", "Invalid hotkey: \(trimmed)")
                statusIsError = true
                return
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(buildConfig())
            try FileManager.default.createDirectory(
                at: ConfigStore.configDirectory, withIntermediateDirectories: true)
            try data.write(to: ConfigStore.configURL)
            statusMessage = UILang.t("✅ 已保存，快捷键已重新注册", "✅ Saved — hotkeys re-registered")
            statusIsError = false
            NotificationCenter.default.post(name: .polishPadSettingsSaved, object: nil)
        } catch {
            statusMessage = UILang.t("保存失败：", "Save failed: ") + error.localizedDescription
            statusIsError = true
        }
    }

    private func testConnection() {
        testing = true
        statusMessage = ""
        var config = buildConfig()
        config.maxTokens = 16
        let messages = [ChatMessage(role: "user", content: "Reply with the single word: OK")]
        Task {
            do {
                _ = try await LLMClient.complete(messages: messages, config: config)
                statusMessage = UILang.t("✅ 连接成功", "✅ Connection OK")
                statusIsError = false
            } catch {
                statusMessage = error.localizedDescription
                statusIsError = true
            }
            testing = false
        }
    }
}

@MainActor
final class SettingsWindowController {
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
        window?.title = UILang.t("PolishPad 设置", "PolishPad Settings")
        // 每次打开重建视图，加载磁盘上的最新配置
        window?.contentView = NSHostingView(rootView: SettingsView())
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
