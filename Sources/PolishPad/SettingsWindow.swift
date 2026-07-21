import AppKit
import ServiceManagement
import SwiftUI

extension Notification.Name {
    static let polishPadOpenSettings = Notification.Name("PolishPad.openSettings")
    static let polishPadSettingsSaved = Notification.Name("PolishPad.settingsSaved")
}

/// 应用感知映射的可编辑行
struct AppMappingRow: Identifiable {
    let id = UUID()
    var bundleID: String
    var preset: String
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
    @State private var promptPreset = "polish"
    @State private var appRows: [AppMappingRow] = []
    @State private var glossaryText = ""
    @State private var updateStatus = ""
    @State private var updateURL: String?
    @State private var checkingUpdate = false
    @State private var launchAtLogin = false
    @StateObject private var recorder = HotkeyRecorderCoordinator()

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

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
                        label: UILang.t("优化窗口", "Main panel"),
                        spec: $hotkeyPanel, coordinator: recorder)
                    HotkeyRecorderField(
                        label: UILang.t("划词优化替换", "Refine selection"),
                        spec: $hotkeySelection, coordinator: recorder)
                    HotkeyRecorderField(
                        label: UILang.t("全选优化替换", "Select-all refine"),
                        spec: $hotkeyAll, coordinator: recorder)
                    Text(UILang.t("点击后直接按下新的组合键（至少含一个修饰键）",
                                  "Click, then press the new combination (needs at least one modifier)"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(UILang.t("行为", "Behavior")) {
                    Toggle(UILang.t("优化后自动粘贴回原应用", "Auto-paste result back into the app"),
                           isOn: $autoPaste)
                    Toggle(UILang.t("开机自启动", "Launch at login"), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { enabled in
                            setLaunchAtLogin(enabled)
                        }
                    TextField(UILang.t("语音识别语言", "Speech locale"), text: $speechLocale,
                              prompt: Text("zh-CN"))
                }

                Section(UILang.t("场景预设", "Scenario Preset")) {
                    Picker(UILang.t("场景", "Scenario"), selection: $promptPreset) {
                        ForEach(PromptPreset.allCases, id: \.rawValue) { preset in
                            Text(UILang.t(preset.labelZH, preset.labelEN)).tag(preset.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(UILang.t(
                        (PromptPreset(rawValue: promptPreset) ?? .polish).descriptionZH,
                        (PromptPreset(rawValue: promptPreset) ?? .polish).descriptionEN
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)

                    if promptPreset == PromptPreset.custom.rawValue {
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 12))
                            .frame(height: 100)
                        Text(UILang.t("留空则回退到内置优化提示词",
                                      "Leave empty to fall back to the built-in refine prompt"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(UILang.t("应用感知（唤起面板时按前台应用自动选场景）",
                                 "App-aware presets (auto-select on summon)")) {
                    ForEach($appRows) { $row in
                        HStack(spacing: 8) {
                            TextField("Bundle ID", text: $row.bundleID,
                                      prompt: Text("com.tinyspeck.slackmacgap"))
                                .font(.system(size: 12))
                            Picker("", selection: $row.preset) {
                                ForEach(PromptPreset.allCases, id: \.rawValue) { preset in
                                    Text(UILang.t(preset.labelZH, preset.labelEN))
                                        .tag(preset.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                            Button {
                                appRows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                        }
                    }
                    Button(UILang.t("添加映射", "Add Mapping")) {
                        appRows.append(AppMappingRow(bundleID: "", preset: "polish"))
                    }
                    .controlSize(.small)
                    Text(UILang.t("查看应用 Bundle ID：终端执行 osascript -e 'id of app \"Slack\"'",
                                  "Find an app's bundle ID: osascript -e 'id of app \"Slack\"'"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(UILang.t("术语表（每行一条：术语=固定译法，或仅术语=原样保留）",
                                 "Glossary (one per line: term=translation, or term alone to keep verbatim)")) {
                    TextEditor(text: $glossaryText)
                        .font(.system(size: 12))
                        .frame(height: 70)
                    Text(UILang.t("示例：小流量=canary（换行分隔）；应用于所有场景，优先级最高",
                                  "Example: 小流量=canary (one per line); applies to every preset with top priority"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(UILang.t("更新", "Updates")) {
                    HStack {
                        Text(UILang.t("当前版本", "Current version") + "  v\(appVersion)")
                        Spacer()
                        if let updateURL {
                            Button(UILang.t("前往下载", "Download Update")) {
                                if let url = URL(string: updateURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        } else {
                            Button(checkingUpdate
                                   ? UILang.t("检查中…", "Checking…")
                                   : UILang.t("检查更新", "Check for Updates")) {
                                checkForUpdates()
                            }
                            .controlSize(.small)
                            .disabled(checkingUpdate)
                        }
                    }
                    if !updateStatus.isEmpty {
                        Text(updateStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    // 本月用量
                    let usage = UsageStore.currentMonth()
                    Text(UILang.t(
                        "本月用量：\(usage.requests) 次请求 · 输入 \(usage.prompt) / 输出 \(usage.completion) tokens",
                        "This month: \(usage.requests) requests · \(usage.prompt) in / \(usage.completion) out tokens"))
                        .font(.caption)
                        .foregroundColor(.secondary)
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

    /// 开机自启动：注册/注销即时生效，状态由系统持有（不进 config.json）
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            statusMessage = UILang.t("开机自启动设置失败：", "Launch-at-login failed: ")
                + error.localizedDescription
            statusIsError = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func load() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard let config = ConfigStore.loadRaw() else { return }
        baseURL = config.baseURL
        let rawKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawKey == ConfigStore.placeholderKey || rawKey.isEmpty {
            apiKey = ""
        } else if rawKey == ConfigStore.keychainSentinel {
            apiKey = KeychainStore.get() ?? ""
        } else {
            apiKey = rawKey
        }
        modelName = config.model
        temperature = config.temperature ?? 0.3
        maxTokensText = String(config.maxTokens ?? 4096)
        hotkeyPanel = config.hotkey ?? "ctrl+option+p"
        hotkeySelection = config.hotkeyPolishSelection ?? "ctrl+option+r"
        hotkeyAll = config.hotkeyPolishAll ?? "ctrl+option+a"
        speechLocale = config.speechLocale ?? "zh-CN"
        autoPaste = config.autoPaste ?? true
        systemPrompt = config.systemPrompt ?? ""
        promptPreset = config.promptPreset ?? "polish"
        // 老配置：之前填过自定义提示词的用户视为自定义场景
        if config.promptPreset == nil, !(config.systemPrompt ?? "").isEmpty {
            promptPreset = PromptPreset.custom.rawValue
        }
        appRows = (config.appPresets ?? [:])
            .sorted { $0.key < $1.key }
            .map { AppMappingRow(bundleID: $0.key, preset: $0.value) }
        glossaryText = (config.glossary ?? []).joined(separator: "\n")
    }

    /// includeRealKey：true 用于运行时测试；false 用于写盘（key 进 Keychain，JSON 留哨兵）
    private func buildConfig(includeRealKey: Bool) -> AppConfig {
        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonKey: String
        if key.isEmpty {
            jsonKey = ConfigStore.placeholderKey
        } else {
            jsonKey = includeRealKey ? key : ConfigStore.keychainSentinel
        }
        var mappings: [String: String] = [:]
        for row in appRows {
            let bundleID = row.bundleID.trimmingCharacters(in: .whitespaces)
            if !bundleID.isEmpty {
                mappings[bundleID] = row.preset
            }
        }
        let glossaryLines = glossaryText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return AppConfig(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: jsonKey,
            model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            temperature: temperature,
            maxTokens: Int(maxTokensText.trimmingCharacters(in: .whitespaces)) ?? 4096,
            hotkey: hotkeyPanel.trimmingCharacters(in: .whitespaces),
            promptPreset: promptPreset,
            hotkeyPolishSelection: hotkeySelection.trimmingCharacters(in: .whitespaces),
            hotkeyPolishAll: hotkeyAll.trimmingCharacters(in: .whitespaces),
            systemPrompt: prompt.isEmpty ? nil : prompt,
            speechLocale: speechLocale.trimmingCharacters(in: .whitespaces),
            autoPaste: autoPaste,
            appPresets: mappings.isEmpty ? nil : mappings,
            glossary: glossaryLines.isEmpty ? nil : glossaryLines
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
            // key 存 Keychain，JSON 只留哨兵
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                KeychainStore.set(key)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(buildConfig(includeRealKey: false))
            try FileManager.default.createDirectory(
                at: ConfigStore.configDirectory, withIntermediateDirectories: true)
            try data.write(to: ConfigStore.configURL)
            statusMessage = UILang.t("✅ 已保存（API Key 已存入钥匙串）",
                                     "✅ Saved (API key stored in Keychain)")
            statusIsError = false
            NotificationCenter.default.post(name: .polishPadSettingsSaved, object: nil)
        } catch {
            statusMessage = UILang.t("保存失败：", "Save failed: ") + error.localizedDescription
            statusIsError = true
        }
    }

    private func checkForUpdates() {
        checkingUpdate = true
        updateStatus = ""
        Task {
            defer { checkingUpdate = false }
            struct Release: Decodable {
                let tag_name: String
                let html_url: String
            }
            do {
                var request = URLRequest(url: URL(
                    string: "https://api.github.com/repos/yijun8liu-collab/PolishPad/releases/latest")!)
                request.timeoutInterval = 15
                let (data, _) = try await URLSession.shared.data(for: request)
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = release.tag_name.hasPrefix("v")
                    ? String(release.tag_name.dropFirst()) : release.tag_name
                if Self.isVersion(latest, newerThan: appVersion) {
                    updateURL = release.html_url
                    updateStatus = UILang.t("发现新版本 \(release.tag_name)，点击「前往下载」获取",
                                            "New version \(release.tag_name) available")
                } else {
                    updateStatus = UILang.t("✅ 已是最新版本", "✅ You're up to date")
                }
            } catch {
                updateStatus = UILang.t("检查失败：", "Check failed: ") + error.localizedDescription
            }
        }
    }

    /// 简单语义化版本比较（0.3.0 < 0.4.0 < 0.4.1）
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func testConnection() {
        testing = true
        statusMessage = ""
        var config = buildConfig(includeRealKey: true)
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
