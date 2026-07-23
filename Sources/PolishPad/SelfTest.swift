import AppKit
import Foundation

/// 纯逻辑自检：`PolishPad --selftest` 运行，不启动 UI。
/// 覆盖预设/术语表/映射/历史/diff/Keychain/版本比较。
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)  \(detail)")
        }
    }

    static func run() -> Int {
        var config = AppConfig(
            baseURL: "https://example.com/v1", apiKey: "sk-test", model: "m",
            temperature: 0.3, maxTokens: 100, hotkey: nil, promptPreset: "polish",
            hotkeyPolishSelection: nil, hotkeyPolishAll: nil, systemPrompt: nil,
            speechLocale: nil, autoPaste: true,
            appPresets: ["com.tinyspeck.slackmacgap": "slack-english",
                         "com.apple.mail": "formal"],
            glossary: ["小流量=canary", "PolishPad"]
        )

        // 1. 场景预设解析
        check("preset.polish.zh",
              config.resolvedSystemPrompt(english: false).contains("文本改写工具，不是 AI 助手"))
        config.presetOverrides = ["polish": "OVERRIDE-TEST"]
        check("preset.override",
              config.resolvedSystemPrompt(english: false).hasPrefix("OVERRIDE-TEST"))
        config.presetOverrides = nil
        config.customScenarios = [CustomScenario(id: "sc1", name: "测试场景", prompt: "USER-SCENE")]
        check("scenario.user",
              config.resolvedSystemPrompt(english: false, scenario: .user("sc1"))
                  .hasPrefix("USER-SCENE"))
        check("scenario.user.fallback",
              Scenario.from(key: "user:gone", in: config.customScenarios ?? [])
                  == .builtin(.polish))
        check("scenario.keyRoundtrip",
              Scenario.from(key: Scenario.user("sc1").keyString,
                            in: config.customScenarios ?? []) == .user("sc1"))
        config.customScenarios = nil
        config.promptPreset = "slack-english"
        check("preset.slack",
              config.resolvedSystemPrompt(english: false).contains("Slack"))
        config.promptPreset = "formal"
        check("preset.formal.zh",
              config.resolvedSystemPrompt(english: false).contains("正式、书面、专业"))
        check("preset.formal.en",
              config.resolvedSystemPrompt(english: true).contains("formal, professional"))
        config.promptPreset = "concise"
        check("preset.concise.zh",
              config.resolvedSystemPrompt(english: false).contains("大幅压缩"))
        config.promptPreset = "polish"

        // 2. 面板级预设覆盖
        check("preset.override",
              config.resolvedSystemPrompt(english: false, presetOverride: .slackEnglish)
                  .contains("Slack"))

        // 3. 术语表注入（所有预设都带）
        let glossaryPrompt = config.resolvedSystemPrompt(english: false)
        check("glossary.translation",
              glossaryPrompt.contains("小流量 → canary"))
        check("glossary.verbatim",
              glossaryPrompt.contains("PolishPad（原样保留）"))
        check("glossary.en",
              config.resolvedSystemPrompt(english: true, presetOverride: .slackEnglish)
                  .contains("keep as-is"))

        // 4. 应用感知映射
        let mapped = config.appPresets?["com.tinyspeck.slackmacgap"]
            .flatMap(PromptPreset.init(rawValue:))
        check("appPresets.slack", mapped == .slackEnglish)

        // 5. 历史记录：容量 20、最新在前、可持久化往返
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("polishpad-selftest-history-\(UUID().uuidString).json")
        let store = HistoryStore(url: tempURL)
        var lastID = UUID()
        for i in 1...25 {
            lastID = UUID()
            store.upsert(id: lastID, original: "原文\(i)", versions: ["v\(i)"], preset: "polish")
        }
        check("history.capacity", store.records.count == 20,
              "count=\(store.records.count)")
        check("history.latestFirst", store.records.first?.original == "原文25")
        store.upsert(id: lastID, original: "原文25", versions: ["v25", "v25b"], preset: "polish")
        check("history.upsert",
              store.records.count == 20 && store.records.first?.versions.count == 2)
        let reloaded = HistoryStore(url: tempURL)
        check("history.roundtrip", reloaded.records.count == 20)
        try? FileManager.default.removeItem(at: tempURL)

        // 6. diff：same+inserted 重组等于新文本，same+removed 重组等于旧文本
        let old = "我们今天上线推荐服务，注意监控。"
        let new = "我们明天上线推荐服务的新版本，注意监控和报警。"
        if let segments = DiffRenderer.segments(from: old, to: new) {
            let rebuiltNew = segments.filter { $0.kind != .removed }.map(\.text).joined()
            let rebuiltOld = segments.filter { $0.kind != .inserted }.map(\.text).joined()
            check("diff.rebuildNew", rebuiltNew == new)
            check("diff.rebuildOld", rebuiltOld == old)
            check("diff.hasChanges",
                  segments.contains { $0.kind == .inserted }
                      && segments.contains { $0.kind == .removed })
        } else {
            check("diff.segments", false, "returned nil")
        }
        check("diff.lengthGuard",
              DiffRenderer.segments(
                  from: String(repeating: "a", count: 5000),
                  to: String(repeating: "b", count: 5000)) == nil)

        // 7. Keychain 往返（独立测试账户，不碰真实 key）
        KeychainStore.set("secret-123", account: "selftest")
        check("keychain.roundtrip", KeychainStore.get(account: "selftest") == "secret-123")
        KeychainStore.set("secret-456", account: "selftest")
        check("keychain.overwrite", KeychainStore.get(account: "selftest") == "secret-456")
        KeychainStore.delete(account: "selftest")
        check("keychain.delete", KeychainStore.get(account: "selftest") == nil)

        // 8. 版本比较
        check("semver.newer", SettingsView.isVersion("0.5.0", newerThan: "0.4.9"))
        check("semver.equal", !SettingsView.isVersion("0.5.0", newerThan: "0.5.0"))
        check("semver.patch", SettingsView.isVersion("0.5.1", newerThan: "0.5.0"))

        // 9. 用量累计
        let before = UsageStore.currentMonth()
        UsageStore.record(promptTokens: 11, completionTokens: 7)
        let after = UsageStore.currentMonth()
        check("usage.record",
              after.requests == before.requests + 1
                  && after.prompt == before.prompt + 11
                  && after.completion == before.completion + 7)

        print(failures == 0 ? "== ALL PASS ==" : "== \(failures) FAILURE(S) ==")
        return failures
    }
}
