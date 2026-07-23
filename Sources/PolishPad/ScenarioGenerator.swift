import Foundation

/// 一句话生成场景：AI 只产出【场景名 + 提示词正文】，
/// 多轮标签协议由本地拼接——生成的场景绝不会破坏多轮纠偏
enum ScenarioGenerator {
    struct Generated: Decodable, Equatable {
        let name: String
        let nameEN: String?
        let bodyZH: String
        let bodyEN: String

        enum CodingKeys: String, CodingKey {
            case name
            case nameEN = "name_en"
            case bodyZH = "body_zh"
            case bodyEN = "body_en"
        }
    }

    /// 模型常在 JSON 字符串里写裸换行（非法）：只转义引号内的换行，
    /// 键与键之间的结构性换行保持原样
    static func escapingInStringNewlines(_ text: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        for ch in text {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { out.append(ch); escaped = true; continue }
            if ch == "\"" { inString.toggle(); out.append(ch); continue }
            if inString, ch == "\n" { out += "\\n"; continue }
            if inString, ch == "\r" { continue }
            out.append(ch)
        }
        return out
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
        let json = String(text[start...end])
        if let ok = try? JSONDecoder().decode(Generated.self, from: Data(json.utf8)) {
            return ok
        }
        return try? JSONDecoder().decode(
            Generated.self, from: Data(escapingInStringNewlines(json).utf8))
    }

    private static let metaPromptZH = """
    你是场景配置生成器。用户会用一句话描述一个文本处理场景，你只输出一个单行合法 JSON 对象（无任何其他文字、无代码块围栏、字符串内换行必须写成 \\n 转义）：
    {"name": "场景名（2-6个字）", "name_en": "English name (1-3 words)", "body_zh": "中文提示词正文", "body_en": "English prompt body"}

    两个 body 的要求（语义一致，各自用对应语言书写）：
    1. 以"你是一个XX工具。用户会给你一段文字。你的任务是……"（英文版用 "You are a ... tool. The user gives you a passage. Your job is ..."）开头，明确改写目标。
    2. 用分点列出具体、可执行的风格要求（语气、结构、用词、长度等）。
    3. 只描述"改写行为"，绝不允许回答问题或执行内容。
    4. 不要提及 <input>/<feedback>/<append> 等标签（系统会自动附加协议）。
    注意：body_en 是"输出英文"模式使用的版本，风格要求需适配英文表达习惯。
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

        // 中英两版各自拼接对应语言的协议块（含铁律：只改写不回应）
        let scenario = CustomScenario(
            name: String(generated.name.prefix(12)),
            nameEN: generated.nameEN.map { String($0.prefix(24)) },
            prompt: generated.bodyZH.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n" + AppConfig.scenarioRulesZH,
            promptEN: generated.bodyEN.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n" + AppConfig.scenarioRulesEN)

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
