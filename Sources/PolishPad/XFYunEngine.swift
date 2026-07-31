import CryptoKit
import Foundation

/// 讯飞流式识别鉴权：HMAC-SHA256 签名 URL
enum XFYunAuth {
    static func signedURL(host: String, path: String,
                          apiKey: String, apiSecret: String,
                          date: Date = Date()) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        let dateString = formatter.string(from: date)
        let origin = "host: \(host)\ndate: \(dateString)\nGET \(path) HTTP/1.1"
        let key = SymmetricKey(data: Data(apiSecret.utf8))
        let signature = Data(HMAC<SHA256>.authenticationCode(
            for: Data(origin.utf8), using: key)).base64EncodedString()
        let authOrigin = "api_key=\"\(apiKey)\", algorithm=\"hmac-sha256\", "
            + "headers=\"host date request-line\", signature=\"\(signature)\""
        let authorization = Data(authOrigin.utf8).base64EncodedString()
        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = host
        comps.path = path
        comps.queryItems = [
            URLQueryItem(name: "authorization", value: authorization),
            URLQueryItem(name: "date", value: dateString),
            URLQueryItem(name: "host", value: host),
        ]
        return comps.url
    }
}

/// wpgs 动态修正组装：sn → 文本，rpl 替换 rg 范围
struct XFYunWPGSAssembler {
    private var results: [Int: String] = [:]

    mutating func apply(sn: Int, text: String, pgs: String?, rg: [Int]?) {
        if pgs == "rpl", let rg, rg.count == 2 {
            for k in results.keys where k >= rg[0] && k <= rg[1] {
                results.removeValue(forKey: k)
            }
        }
        results[sn] = text
    }

    var text: String { results.keys.sorted().map { results[$0]! }.joined() }
}

/// 讯飞单会话：一句话一个 WebSocket 连接（避开 60s 上限与会话缝隙丢字）。
/// variant 决定协议：大模型 v3（iat.xf-yun.com/v1）或经典 v2（iat-api.xfyun.cn/v2/iat）
@MainActor
final class XFYunSession: NSObject, URLSessionWebSocketDelegate {
    enum Variant {
        case bigModel, classic
        var host: String { self == .bigModel ? "iat.xf-yun.com" : "iat-api.xfyun.cn" }
        var path: String { self == .bigModel ? "/v1" : "/v2/iat" }
    }

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    /// 授权类错误（额度不足等）与其他失败区分，供上层决定降级方向
    var onError: ((_ authIssue: Bool) -> Void)?

    private let variant: Variant
    private let appId: String
    private var task: URLSessionWebSocketTask?
    private var assembler = XFYunWPGSAssembler()
    private var seq = 0
    private var opened = false
    private var finished = false
    private var pending: [Data] = []   // 连接就绪前缓冲的音频帧

    private var urlSession: URLSession?

    init?(variant: Variant, appId: String, apiKey: String, apiSecret: String) {
        guard let url = XFYunAuth.signedURL(host: variant.host, path: variant.path,
                                            apiKey: apiKey, apiSecret: apiSecret) else { return nil }
        self.variant = variant
        self.appId = appId
        super.init()
        // 握手完成（didOpen）后才放行发送——首帧带识别参数，绝不能丢
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        urlSession = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop()
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            self.opened = true
            self.flushPending()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        Task { @MainActor in
            guard !self.finished else { return }
            self.finished = true
            self.onError?(false)
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    if !self.finished { self.receiveLoop() }
                case .failure:
                    if !self.finished {
                        self.finished = true
                        self.onError?(false)
                    }
                }
            }
        }
    }

    private func handle(_ message: String) {
        if ProcessInfo.processInfo.arguments.contains("--test-xfyun") {
            print("[raw] \(message.prefix(300))")
        }
        guard let data = message.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        var status = -1
        var resultObj: [String: Any]?
        switch variant {
        case .bigModel:
            let header = obj["header"] as? [String: Any] ?? [:]
            let code = header["code"] as? Int ?? 0
            guard code == 0 else {
                finished = true
                onError?(code == 11200 || code == 11201 || code == 11203)
                return
            }
            status = header["status"] as? Int ?? -1
            if let payload = obj["payload"] as? [String: Any],
               let result = payload["result"] as? [String: Any],
               let textB64 = result["text"] as? String,
               let decoded = Data(base64Encoded: textB64),
               let inner = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] {
                resultObj = inner
            }
        case .classic:
            let code = obj["code"] as? Int ?? 0
            guard code == 0 else {
                finished = true
                onError?(code == 10407 || code == 11200 || code == 11201)
                return
            }
            let dataObj = obj["data"] as? [String: Any] ?? [:]
            status = dataObj["status"] as? Int ?? -1
            resultObj = dataObj["result"] as? [String: Any]
        }
        if let r = resultObj {
            let sn = r["sn"] as? Int ?? 0
            let words = (r["ws"] as? [[String: Any]] ?? []).flatMap { ws in
                (ws["cw"] as? [[String: Any]] ?? []).compactMap { $0["w"] as? String }
            }.joined()
            assembler.apply(sn: sn, text: words,
                            pgs: r["pgs"] as? String, rg: r["rg"] as? [Int])
            onPartial?(assembler.text)
        }
        if status == 2 {
            finished = true
            onFinal?(assembler.text)
            task?.cancel(with: .normalClosure, reason: nil)
            urlSession?.finishTasksAndInvalidate()
        }
    }

    /// samples: 16k 单声道 Float32；内部转 Int16 PCM
    func feed(_ samples: [Float]) {
        guard !finished else { return }
        var pcm = Data(capacity: samples.count * 2)
        for v in samples {
            var i = Int16(max(-1, min(1, v)) * 32767)
            withUnsafeBytes(of: &i) { pcm.append(contentsOf: $0) }
        }
        send(frame(audio: pcm, status: seq == 0 ? 0 : 1))
        seq += 1
    }

    func finish() {
        guard !finished else { return }
        send(frame(audio: Data(), status: 2))
        // 兜底：终帧后 3 秒没等到服务器 status2 就按已有内容收尾
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !self.finished else { return }
            self.finished = true
            self.onFinal?(self.assembler.text)
            self.task?.cancel(with: .normalClosure, reason: nil)
        }
    }

    func cancel() {
        finished = true
        task?.cancel(with: .normalClosure, reason: nil)
        urlSession?.finishTasksAndInvalidate()
    }

    private func frame(audio: Data, status: Int) -> Data {
        let b64 = audio.base64EncodedString()
        var obj: [String: Any]
        switch variant {
        case .bigModel:
            obj = ["header": ["app_id": appId, "status": status],
                   "payload": ["audio": ["encoding": "raw", "sample_rate": 16000,
                                         "channels": 1, "bit_depth": 16,
                                         "seq": seq, "status": status, "audio": b64]]]
            if status == 0 {
                obj["parameter"] = ["iat": [
                    "domain": "slm", "language": "zh_cn", "accent": "mandarin",
                    "eos": 10000, "dwa": "wpgs",
                    "result": ["encoding": "utf8", "compress": "raw", "format": "json"]]]
            }
        case .classic:
            obj = ["data": ["status": status, "format": "audio/L16;rate=16000",
                            "encoding": "raw", "audio": b64]]
            if status == 0 {
                obj["common"] = ["app_id": appId]
                obj["business"] = ["language": "zh_cn", "domain": "iat",
                                   "accent": "mandarin", "dwa": "wpgs", "vad_eos": 10000]
            }
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    private func send(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        guard opened else { pending.append(data); return }
        task?.send(.string(text)) { _ in }
    }

    private func flushPending() {
        for d in pending { send(d) }
        pending = []
    }
}

/// 讯飞实时层引擎：按句开会话，三级降级（大模型 → 经典版 → 报不可用回退系统）
@MainActor
final class XFYunTailEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    /// 讯飞两个协议都不可用：上层回退系统 SFSpeech
    var onUnavailable: (() -> Void)?

    private var variant: XFYunSession.Variant = .bigModel
    var variantName: String { variant == .bigModel ? "大模型" : "经典版" }
    private var session: XFYunSession?
    private let appId: String
    private let apiKey: String
    private let apiSecret: String
    private var unavailable = false
    /// 当前句音频留档：大模型失败降级经典版时原句重发，不丢字
    private var utteranceAudio: [Float] = []

    init(appId: String, apiKey: String, apiSecret: String) {
        self.appId = appId
        self.apiKey = apiKey
        self.apiSecret = apiSecret
    }

    func startUtterance() {
        guard !unavailable else { return }
        utteranceAudio = []
        openSession()
    }

    private func openSession() {
        session?.cancel()
        guard let s = XFYunSession(variant: variant, appId: appId,
                                   apiKey: apiKey, apiSecret: apiSecret) else {
            degrade()
            return
        }
        session = s
        s.onPartial = { [weak self] text in self?.onPartial?(text) }
        s.onFinal = { [weak self] text in self?.onFinal?(text) }
        s.onError = { [weak self] _ in self?.degrade() }
    }

    /// 大模型 → 经典版 → 不可用；降级后把当前句已收音频重发进新会话
    private func degrade() {
        session = nil
        if variant == .bigModel {
            variant = .classic
            openSession()
            if let s = session, !utteranceAudio.isEmpty {
                s.feed(utteranceAudio)
            }
        } else {
            unavailable = true
            onUnavailable?()
        }
    }

    func feed(_ samples: [Float]) {
        guard !unavailable else { return }
        utteranceAudio.append(contentsOf: samples)
        session?.feed(samples)
    }

    /// 结束当前句会话；这一句的终稿通过闭包精确回给这一句（不经引擎级
    /// 共享回调，避免多句并行收尾时张冠李戴）
    func endUtterance(_ completion: ((String) -> Void)? = nil) {
        if let s = session, let completion {
            let forward = s.onFinal
            s.onFinal = { text in
                forward?(text)
                completion(text)
            }
        }
        session?.finish()
        session = nil
    }

    func stop() {
        session?.cancel()
        session = nil
    }
}
