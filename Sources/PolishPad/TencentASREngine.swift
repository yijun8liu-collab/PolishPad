import CryptoKit
import Foundation

/// 云端实时字幕引擎的统一接口：讯飞/腾讯共用，WhisperRecorder 按配置装配
@MainActor
protocol CloudTailEngine: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onUnavailable: (() -> Void)? { get set }
    /// 实时层质量高于 Whisper 定稿层时为 true：定稿默认保留实时版文本
    var prefersRealtimeText: Bool { get }
    func preconnect()
    func startUtterance()
    func feed(_ samples: [Float])
    func endUtterance(_ completion: ((String) -> Void)?)
    func stop()
}

/// 腾讯云实时语音识别单会话（每句一连）。协议：wss + HMAC-SHA1 签名 URL、
/// 200ms 二进制分片、{"type":"end"} 收尾；结果按 slice_type 组装
@MainActor
final class TencentSession: NSObject, URLSessionWebSocketDelegate {
    let createdAt = Date()
    var isFinished: Bool { finished }

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((_ authIssue: Bool) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var opened = false
    private var finished = false
    private var pendingFrames: [Data] = []
    private var sendBuffer = Data()
    private var sentences: [String] = []
    private var current = ""

    static func signedURL(appId: String, secretId: String, secretKey: String,
                          engine: String, voiceId: String,
                          now: Int = Int(Date().timeIntervalSince1970),
                          nonce: Int = Int.random(in: 1...999_999_999)) -> URL? {
        let params: [(String, String)] = [
            ("engine_model_type", engine),
            ("expired", String(now + 3600)),
            ("needvad", "1"),
            ("nonce", String(nonce)),
            ("secretid", secretId),
            ("timestamp", String(now)),
            ("voice_format", "1"),
            ("voice_id", voiceId),
        ].sorted { $0.0 < $1.0 }
        let query = params.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let origin = "asr.cloud.tencent.com/asr/v2/\(appId)?\(query)"
        let key = SymmetricKey(data: Data(secretKey.utf8))
        let sig = Data(HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(origin.utf8), using: key)).base64EncodedString()
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        guard let encoded = sig.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "wss://\(origin)&signature=\(encoded)")
    }

    init?(appId: String, secretId: String, secretKey: String, engine: String) {
        guard let url = Self.signedURL(appId: appId, secretId: secretId,
                                       secretKey: secretKey, engine: engine,
                                       voiceId: UUID().uuidString) else { return nil }
        super.init()
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
            for frame in self.pendingFrames { self.sendBinary(frame) }
            self.pendingFrames = []
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
        guard let data = message.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let code = obj["code"] as? Int ?? 0
        guard code == 0 else {
            finished = true
            // 4004 资源包耗尽 / 6001 跨境流量：授权类问题，直接降级不重试
            onError?(code == 4004 || code == 6001 || code == 4002)
            return
        }
        if let result = obj["result"] as? [String: Any] {
            let text = result["voice_text_str"] as? String ?? ""
            if result["slice_type"] as? Int == 2 {
                sentences.append(text)
                current = ""
            } else {
                current = text
            }
            onPartial?(assembled)
        }
        if obj["final"] as? Int == 1 {
            finished = true
            onFinal?(assembled)
            task?.cancel(with: .normalClosure, reason: nil)
            urlSession?.finishTasksAndInvalidate()
        }
    }

    private var assembled: String {
        (sentences + (current.isEmpty ? [] : [current])).joined()
    }

    /// samples: 16k 单声道 Float32；攒满 200ms（6400 字节）再发
    func feed(_ samples: [Float]) {
        guard !finished else { return }
        for v in samples {
            var i = Int16(max(-1, min(1, v)) * 32767)
            withUnsafeBytes(of: &i) { sendBuffer.append(contentsOf: $0) }
        }
        while sendBuffer.count >= 6400 {
            let chunk = sendBuffer.prefix(6400)
            sendBuffer.removeFirst(6400)
            if opened { sendBinary(Data(chunk)) } else { pendingFrames.append(Data(chunk)) }
        }
    }

    func finish() {
        guard !finished else { return }
        if !sendBuffer.isEmpty {
            let rest = sendBuffer
            sendBuffer = Data()
            if opened { sendBinary(rest) } else { pendingFrames.append(rest) }
        }
        task?.send(.string(#"{"type":"end"}"#)) { _ in }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !self.finished else { return }
            self.finished = true
            self.onFinal?(self.assembled)
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.urlSession?.finishTasksAndInvalidate()
        }
    }

    func cancel() {
        finished = true
        task?.cancel(with: .normalClosure, reason: nil)
        urlSession?.finishTasksAndInvalidate()
    }

    private func sendBinary(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }
}

/// 腾讯实时层引擎：按句开会话 + 预连接；实测 16k_zh_large 术语还原 ≈95%
/// （超过 Whisper 定稿层），故 prefersRealtimeText = true
@MainActor
final class TencentTailEngine: CloudTailEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    let prefersRealtimeText = true

    static let engineModel = "16k_zh_large"

    private let appId: String
    private let secretId: String
    private let secretKey: String
    private var session: TencentSession?
    private var preconnected: TencentSession?
    private var consecutiveFailures = 0
    private var unavailable = false

    init(appId: String, secretId: String, secretKey: String) {
        self.appId = appId
        self.secretId = secretId
        self.secretKey = secretKey
    }

    func preconnect() {
        guard !unavailable else { return }
        if let pre = preconnected, !pre.isFinished,
           Date().timeIntervalSince(pre.createdAt) < 5 { return }
        preconnected?.cancel()
        preconnected = TencentSession(appId: appId, secretId: secretId,
                                      secretKey: secretKey, engine: Self.engineModel)
        preconnected?.onError = { [weak self] _ in self?.preconnected = nil }
    }

    func startUtterance() {
        guard !unavailable else { return }
        if let pre = preconnected, !pre.isFinished,
           Date().timeIntervalSince(pre.createdAt) < 5 {
            preconnected = nil
            session = pre
        } else {
            preconnected?.cancel()
            preconnected = nil
            session = TencentSession(appId: appId, secretId: secretId,
                                     secretKey: secretKey, engine: Self.engineModel)
        }
        guard let s = session else { fail(auth: false); return }
        s.onPartial = { [weak self] text in self?.onPartial?(text) }
        s.onFinal = { [weak self] text in
            self?.consecutiveFailures = 0
            self?.onFinal?(text)
        }
        s.onError = { [weak self] authIssue in self?.fail(auth: authIssue) }
    }

    /// 授权类问题立即降级；网络类连挫三次才降级（单次抖动下一句自动重试）
    private func fail(auth: Bool) {
        session = nil
        consecutiveFailures += 1
        if auth || consecutiveFailures >= 3 {
            unavailable = true
            onUnavailable?()
        }
    }

    func feed(_ samples: [Float]) {
        session?.feed(samples)
    }

    func endUtterance(_ completion: ((String) -> Void)?) {
        if let s = session {
            s.onPartial = nil   // 掐断迟到部分结果（与讯飞同款防重复）
            if let completion {
                let forward = s.onFinal
                s.onFinal = { text in
                    forward?(text)
                    completion(text)
                }
            }
        }
        session?.finish()
        session = nil
        preconnect()
    }

    func stop() {
        session?.cancel()
        session = nil
        preconnected?.cancel()
        preconnected = nil
    }
}
