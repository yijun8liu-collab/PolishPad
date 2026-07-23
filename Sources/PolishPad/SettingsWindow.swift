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
    @State private var idlePrefetch = true
    @State private var uiEnglish = UserDefaults.standard.bool(forKey: "outputEnglish")
    /// 面板尺寸档位：small/medium/large/custom（custom=用户拖拽出的尺寸）
    @State private var panelSizeChoice = "medium"
    @State private var systemPrompt = ""
    @State private var showKey = false
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var testing = false
    @State private var promptPreset = "polish"
    /// 内置场景提示词的用户覆写（键=场景 rawValue）
    @State private var presetOverrides: [String: String] = [:]
    /// 用户自定义场景列表
    @State private var customScenarios: [CustomScenario] = []
    @State private var appRows: [AppMappingRow] = []
    @State private var glossaryText = ""
    @State private var updateStatus = ""
    @State private var updateURL: String?
    @State private var checkingUpdate = false
    @State private var launchAtLogin = false
    @StateObject private var recorder = HotkeyRecorderCoordinator()
    /// 任何窗口关闭都停一次录制（幂等）：录制中直接关设置窗时，
    /// 必须恢复全局热键并摘掉吞键的本地监听，否则热键失效、面板打不出字
    private var windowWillClose: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
    }

    /// 选中的用户场景在列表中的下标（未选用户场景时为 nil）
    private var selectedUserScenarioIndex: Int? {
        guard promptPreset.hasPrefix("user:") else { return nil }
        let id = String(promptPreset.dropFirst(5))
        return customScenarios.firstIndex { $0.id == id }
    }

    /// 当前选中的内置场景（自定义除外）
    private var selectedBuiltinPreset: PromptPreset {
        PromptPreset(rawValue: promptPreset) ?? .polish
    }

    private var builtinPromptText: String {
        AppConfig.builtinPrompt(selectedBuiltinPreset, english: UILang.isEnglish)
    }

    /// 是否已被用户覆写（非空且不等于任一语言的内置版）
    private var isPresetCustomized: Bool {
        guard let value = presetOverrides[promptPreset]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return false
        }
        return value != AppConfig.builtinPrompt(selectedBuiltinPreset, english: false)
            && value != AppConfig.builtinPrompt(selectedBuiltinPreset, english: true)
    }

    /// 编辑器绑定：无覆写时显示内置全文，一旦修改即写入覆写
    private var presetPromptBinding: Binding<String> {
        Binding(
            get: { presetOverrides[promptPreset] ?? builtinPromptText },
            set: { presetOverrides[promptPreset] = $0 }
        )
    }

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
                    // 写入放在 Binding setter 里（先于重绘执行）：
                    // .onChange 在重绘之后才跑，本窗口文案会慢一拍
                    Picker(UILang.t("界面与输出语言", "UI & output language"),
                           selection: Binding(
                               get: { uiEnglish },
                               set: { value in
                                   uiEnglish = value
                                   UserDefaults.standard.set(value, forKey: "outputEnglish")
                                   NotificationCenter.default.post(
                                       name: .polishPadLanguageChanged, object: nil)
                               })) {
                        Text("中文").tag(false)
                        Text("English").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Toggle(UILang.t("优化后自动粘贴回原应用", "Auto-paste result back into the app"),
                           isOn: $autoPaste)
                    Toggle(UILang.t("开机自启动", "Launch at login"), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { enabled in
                            setLaunchAtLogin(enabled)
                        }
                    Toggle(UILang.t("停顿预取（回车秒出）", "Idle prefetch (instant Enter)"),
                           isOn: $idlePrefetch)
                    Text(UILang.t(
                        "输入停顿 2 秒后在后台预先优化一轮；回车时内容未再改动即瞬间出结果（状态栏显示闪电标记）。注意：预取会产生额外的 API 调用，每次有效停顿约多消耗一轮 token。",
                        "After a 2s typing pause, a round is pre-run in the background; press Enter without further edits and the result appears instantly (bolt icon in the status bar). Note: prefetching makes extra API calls — roughly one additional round of tokens per pause."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker(UILang.t("面板大小", "Panel size"), selection: $panelSizeChoice) {
                        Text(UILang.t("小", "Small")).tag("small")
                        Text(UILang.t("中", "Medium")).tag("medium")
                        Text(UILang.t("大", "Large")).tag("large")
                        if panelSizeChoice == "custom" {
                            Text(UILang.t("自定义（拖拽调整）", "Custom (dragged)")).tag("custom")
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField(UILang.t("语音识别语言", "Speech locale"), text: $speechLocale,
                              prompt: Text("zh-CN"))
                }

                Section(UILang.t("场景预设", "Scenario Preset")) {
                    HStack {
                        Picker(UILang.t("场景", "Scenario"), selection: $promptPreset) {
                            ForEach(PromptPreset.allCases.filter { $0 != .custom },
                                    id: \.rawValue) { preset in
                                Text(UILang.t(preset.labelZH, preset.labelEN)).tag(preset.rawValue)
                            }
                            if !customScenarios.isEmpty {
                                Divider()
                                ForEach(customScenarios) { scenario in
                                    Text(scenario.name).tag("user:" + scenario.id)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        // menu 型 Picker 的选项文字有缓存，语言切换/增删场景时按身份重建
                        .id("\(uiEnglish)-\(customScenarios.count)")
                        Button(UILang.t("＋ 新建场景", "＋ New scenario")) {
                            let scenario = CustomScenario(
                                name: UILang.t("新场景", "New scenario"), prompt: "")
                            customScenarios.append(scenario)
                            promptPreset = "user:" + scenario.id
                        }
                        .controlSize(.small)
                    }
                    if let index = selectedUserScenarioIndex {
                        // 用户自定义场景：命名 + 专属提示词 + 删除
                        TextField(UILang.t("场景名称", "Scenario name"),
                                  text: $customScenarios[index].name)
                        TextEditor(text: $customScenarios[index].prompt)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(height: 150)
                            .id(promptPreset)
                        HStack {
                            Text(UILang.t(
                                "此场景的提示词（中/EN 共用）；留空时按内置优化处理。可在面板场景菜单和应用感知映射中使用。",
                                "This scenario's prompt (shared by 中/EN); falls back to built-in refine when empty. Available in the panel menu and app-aware mapping."))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(UILang.t("删除此场景", "Delete scenario"), role: .destructive) {
                                customScenarios.remove(at: index)
                                promptPreset = "polish"
                            }
                            .controlSize(.small)
                        }
                    } else {
                    Text(UILang.t(
                        (PromptPreset(rawValue: promptPreset) ?? .polish).descriptionZH,
                        (PromptPreset(rawValue: promptPreset) ?? .polish).descriptionEN
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)

                    if true {
                        // 内置场景：公布提示词全文，可直接修改（成为覆写版）
                        HStack {
                            Text(UILang.t("提示词", "Prompt"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if isPresetCustomized {
                                Text(UILang.t("已自定义", "Customized"))
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                    .foregroundColor(.accentColor)
                            }
                            Spacer()
                            if isPresetCustomized {
                                Button(UILang.t("恢复默认", "Restore default")) {
                                    presetOverrides.removeValue(forKey: promptPreset)
                                }
                                .controlSize(.small)
                            }
                        }
                        TextEditor(text: presetPromptBinding)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(height: 150)
                            .id(promptPreset)
                        Text(UILang.t(
                            "直接修改即成为你的自定义版本（中/EN 模式共用）；恢复默认可随时回到内置提示词。注意保留 <input>/<feedback>/<append> 标签协议段，否则多轮纠偏会异常。",
                            "Edits become your customized version (shared by 中/EN modes); Restore default reverts to the built-in prompt. Keep the <input>/<feedback>/<append> tag protocol or multi-round revision will break."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
                                ForEach(PromptPreset.allCases.filter { $0 != .custom },
                                        id: \.rawValue) { preset in
                                    Text(UILang.t(preset.labelZH, preset.labelEN))
                                        .tag(preset.rawValue)
                                }
                                ForEach(customScenarios) { scenario in
                                    Text(scenario.name).tag("user:" + scenario.id)
                                }
                            }
                            .labelsHidden()
                            .id("\(uiEnglish)-\(customScenarios.count)")
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

                HStack(spacing: 4) {
                    if !statusMessage.isEmpty {
                        Image(systemName: statusIsError
                              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(statusIsError ? .red : Color.green.opacity(0.8))
                    }
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(statusIsError ? .red : .secondary)
                        .lineLimit(2)
                }

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
        .onReceive(windowWillClose) { _ in recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .polishPadLanguageChanged)) { _ in
            let value = UserDefaults.standard.bool(forKey: "outputEnglish")
            if value != uiEnglish { uiEnglish = value }
        }
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
            apiKey = ""  // 反向迁移未完成的残留哨兵：请用户重填
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
        idlePrefetch = config.idlePrefetch ?? true
        let size = PanelSize.current
        panelSizeChoice = PanelSize.presets.first {
            abs($0.w - size.width) < 2 && abs($0.h - size.height) < 2
        }?.name ?? "custom"
        systemPrompt = config.systemPrompt ?? ""
        promptPreset = config.promptPreset ?? "polish"
        // 老配置：之前填过自定义提示词的用户视为自定义场景
        if config.promptPreset == nil, !(config.systemPrompt ?? "").isEmpty {
            promptPreset = PromptPreset.custom.rawValue
        }
        presetOverrides = config.presetOverrides ?? [:]
        customScenarios = config.customScenarios ?? []
        if promptPreset == "custom" { promptPreset = "polish" }
        // 默认场景指向已删除的用户场景时回退
        if (config.promptPreset ?? "").hasPrefix("user:"),
           Scenario.from(key: config.promptPreset!, in: customScenarios)
               == .builtin(.polish) {
            promptPreset = "polish"
        }
        appRows = (config.appPresets ?? [:])
            .sorted { $0.key < $1.key }
            .map { AppMappingRow(bundleID: $0.key, preset: $0.value) }
        glossaryText = (config.glossary ?? []).joined(separator: "\n")
    }

    private func buildConfig(includeRealKey: Bool = true) -> AppConfig {
        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonKey = key.isEmpty ? ConfigStore.placeholderKey : key
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
            glossary: glossaryLines.isEmpty ? nil : glossaryLines,
            idlePrefetch: idlePrefetch,
            presetOverrides: normalizedOverrides(),
            customScenarios: normalizedScenarios()
        )
    }

    /// 写盘前清洗：空的/与内置一致的覆写不落盘
    private func normalizedOverrides() -> [String: String]? {
        var out: [String: String] = [:]
        for (key, value) in presetOverrides {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let preset = PromptPreset(rawValue: key),
                  preset != .custom,
                  trimmed != AppConfig.builtinPrompt(preset, english: false),
                  trimmed != AppConfig.builtinPrompt(preset, english: true) else { continue }
            out[key] = trimmed
        }
        return out.isEmpty ? nil : out
    }

    /// 写盘前清洗：空名补默认名；整表为空则不落盘
    private func normalizedScenarios() -> [CustomScenario]? {
        let cleaned = customScenarios.map { scenario -> CustomScenario in
            var out = scenario
            out.name = scenario.name.trimmingCharacters(in: .whitespaces)
            if out.name.isEmpty { out.name = UILang.t("未命名场景", "Unnamed") }
            return out
        }
        return cleaned.isEmpty ? nil : cleaned
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
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: ConfigStore.configURL.path)
            statusMessage = UILang.t("已保存", "Saved")
            statusIsError = false
            if let preset = PanelSize.presets.first(where: { $0.name == panelSizeChoice }) {
                PanelSize.store(NSSize(width: preset.w, height: preset.h))
                NotificationCenter.default.post(name: .polishPadPanelSizeChanged, object: nil)
            }
            NotificationCenter.default.post(name: .polishPadSettingsSaved, object: nil)
            // 保存成功即自动关窗（失败时留在原地显示错误）；用 HUD 补一个确认
            HUD.shared.flashSuccess(UILang.t("设置已保存", "Settings saved"))
            NSApp.keyWindow?.close()
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
                    updateStatus = UILang.t("已是最新版本", "You're up to date")
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
                statusMessage = UILang.t("连接成功", "Connection OK")
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
        window?.appearance = NSAppearance(
            named: UserDefaults.standard.bool(forKey: "lightTheme") ? .aqua : .darkAqua)
        // 每次打开重建视图，加载磁盘上的最新配置
        window?.contentView = NSHostingView(rootView: SettingsView())
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
