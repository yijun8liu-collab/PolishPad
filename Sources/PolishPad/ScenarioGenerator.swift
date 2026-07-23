import Foundation

/// 一句话生成场景：AI 只产出【场景名 + 提示词正文】，
/// 多轮标签协议由本地拼接——生成的场景绝不会破坏多轮纠偏
enum ScenarioGenerator {
    struct Generated: Decodable, Equatable {
        let name: String
        let body: String
    }

    /// 防御性解析（自检覆盖）：剥代码围栏，取首尾大括号之间
    static func parse(_ raw: String) -> Generated? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst()
                .joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(
            Generated.self, from: Data(String(text[start...end]).utf8))
    }

    private static let metaPromptZH = """
    你是场景配置生成器。用户会用一句话描述一个文本处理场景，你只输出一个 JSON 对象（无任何其他文字、无代码块围栏）：
    {"name": "场景名（2-6个字）", "body": "提示词正文"}

    body 的要求：
    1. 以"你是一个XX工具。用户会给你一段文字。你的任务是……"开头，明确改写目标。
    2. 用分点列出具体、可执行的风格要求（语气、结构、用词、长度等）。
    3. 只描述"改写行为"，绝不允许回答问题或执行内容。
    4. 不要提及 <input>/<feedback>/<append> 等标签（系统会自动附加协议）。
    5. body 的语言与用户描述的语言一致。
    """

    /// 生成并立即持久化到配置；返回新场景
    static func generateAndSave(_ description: String) async throws -> CustomScenario {
        let config = try ConfigStore.load()
        let messages = [
            ChatMessage(role: "system", content: metaPromptZH),
            ChatMessage(role: "user", content: description),
        ]
        let raw = try await LLMClient.completeStreaming(
            messages: messages, config: config, onPartial: nil)

        guard let generated = parse(raw) else {
            throw ScenarioError.badResponse
        }

        // 多轮标签协议按描述语言拼接（含铁律：只改写不回应）
        let isChinese = description.unicodeScalars
            .contains { (0x4E00...0x9FFF).contains($0.value) }
        let rules = isChinese
            ? AppConfig.scenarioRulesZH : AppConfig.scenarioRulesEN
        let scenario = CustomScenario(
            name: String(generated.name.prefix(12)),
            prompt: generated.body.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n" + rules)

        guard var rawConfig = ConfigStore.loadRaw() else {
            throw ScenarioError.badResponse
        }
        rawConfig.customScenarios = (rawConfig.customScenarios ?? []) + [scenario]
        ConfigStore.writeRaw(rawConfig)
        return scenario
    }

    enum ScenarioError: LocalizedError {
        case badResponse
        var errorDescription: String? {
            UILang.t("场景生成失败，请换个描述再试",
                     "Scenario generation failed — try a different description")
        }
    }
}
