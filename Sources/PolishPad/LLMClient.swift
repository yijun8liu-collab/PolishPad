import Foundation

struct ChatMessage: Codable {
    let role: String
    let content: String
}

enum LLMError: LocalizedError {
    case badURL
    case http(Int, String)
    case emptyResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "baseURL 不合法，请检查配置"
        case .http(401, _):
            return "API Key 无效或未授权（401）"
        case .http(429, _):
            return "请求被限流（429），请稍后重试"
        case .http(let code, let body):
            let snippet = body.prefix(200)
            return "请求失败（\(code)）\(snippet.isEmpty ? "" : "：\(snippet)")"
        case .emptyResponse:
            return "模型返回了空内容，请重试"
        case .network(let detail):
            return detail
        }
    }
}

enum LLMClient {
    private struct RequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let max_tokens: Int
        var stream: Bool = false
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]?
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        struct APIError: Decodable { let message: String? }
        let choices: [Choice]?
        let error: APIError?
    }

    /// 划词/全选替换用的单发优化（无多轮上下文），跟随面板的 中/EN 开关
    static func polishOnce(
        _ input: String,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let config = try ConfigStore.load()
        let english = UserDefaults.standard.bool(forKey: "outputEnglish")
        let messages = [
            ChatMessage(role: "system", content: config.resolvedSystemPrompt(english: english)),
            ChatMessage(role: "user", content: "<input>\n\(input)\n</input>"),
        ]
        return try await completeStreaming(messages: messages, config: config, onPartial: onPartial)
    }

    /// 流式补全：每收到增量就回调累计文本。长文本下既有实时反馈，
    /// 空闲超时也随每个数据块刷新，不会撞上整体 60s 墙
    static func completeStreaming(
        messages: [ChatMessage],
        config: AppConfig,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let request = try buildRequest(messages: messages, config: config, stream: true)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as URLError {
            throw mapURLError(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line }
            if let data = body.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(ResponseBody.self, from: data),
               let message = parsed.error?.message {
                throw LLMError.http(http.statusCode, message)
            }
            throw LLMError.http(http.statusCode, body)
        }

        var full = ""
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                      let delta = chunk.choices?.first?.delta.content,
                      !delta.isEmpty else { continue }
                full += delta
                onPartial?(full)
            }
        } catch let error as URLError {
            throw mapURLError(error)
        }

        let cleaned = OutputCleaner.clean(full)
        guard !cleaned.isEmpty else { throw LLMError.emptyResponse }
        return cleaned
    }

    private static func buildRequest(
        messages: [ChatMessage], config: AppConfig, stream: Bool
    ) throws -> URLRequest {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            throw LLMError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: config.model,
            messages: messages,
            temperature: config.temperature ?? 0.3,
            max_tokens: config.maxTokens ?? 4096,
            stream: stream
        ))
        return request
    }

    private static func mapURLError(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return LLMError.network("请求超时，请检查网络或稍后重试")
        case .notConnectedToInternet, .networkConnectionLost:
            return LLMError.network("网络未连接")
        case .cannotFindHost, .cannotConnectToHost:
            return LLMError.network("无法连接到服务器，请检查 baseURL")
        default:
            return LLMError.network("网络错误：\(error.localizedDescription)")
        }
    }

    static func complete(messages: [ChatMessage], config: AppConfig) async throws -> String {
        let request = try buildRequest(messages: messages, config: config, stream: false)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw mapURLError(error)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // 尽量取出结构化的错误信息
            if let parsed = try? JSONDecoder().decode(ResponseBody.self, from: data),
               let message = parsed.error?.message {
                throw LLMError.http(http.statusCode, message)
            }
            throw LLMError.http(http.statusCode, body)
        }

        guard let parsed = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let content = parsed.choices?.first?.message.content else {
            throw LLMError.http(0, "响应解析失败：\(body.prefix(200))")
        }
        let cleaned = OutputCleaner.clean(content)
        guard !cleaned.isEmpty else { throw LLMError.emptyResponse }
        return cleaned
    }
}

enum OutputCleaner {
    /// 兜底清理：剥掉模型偶尔加上的前言、代码块围栏、整体引号
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 整体被 ``` 围栏包裹
        if text.hasPrefix("```"), text.hasSuffix("```") {
            var lines = text.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst()
                lines.removeLast()
                text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // "好的，以下是优化后的文本：" 式前言（仅当首行以冒号结尾且后面还有内容）
        let lines = text.components(separatedBy: "\n")
        if lines.count > 1 {
            let first = lines[0].trimmingCharacters(in: .whitespaces)
            let preamblePrefixes = ["好的", "以下是", "这是", "Here is", "Here's", "Sure"]
            if (first.hasSuffix(":") || first.hasSuffix("：")),
               preamblePrefixes.contains(where: { first.hasPrefix($0) }) {
                text = lines.dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 整体被引号包裹
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」")]
        for (open, close) in quotePairs {
            if text.count > 1, text.first == open, text.last == close,
               !text.dropFirst().dropLast().contains(close) {
                text = String(text.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}
