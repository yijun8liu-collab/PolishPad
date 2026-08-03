import Foundation
import whisper

/// Whisper 模型文件管理：下载（hf-mirror 优先）、进度、就绪状态
@MainActor
final class WhisperModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = WhisperModelStore()

    enum State: Equatable {
        case missing
        case downloading(Double)   // 0-1
        case ready
        case failed(String)
    }

    @Published var state: State = .missing

    nonisolated static let modelName = "ggml-large-v3-turbo-q8_0.bin"
    /// 下载完成后的最小合法体积（实际约 874MB）
    nonisolated static let minValidBytes: Int64 = 800_000_000

    /// silero VAD 模型（~1MB）：神经网络人声检测，随主模型自动下载
    nonisolated static let vadModelName = "ggml-silero-v5.1.2.bin"

    nonisolated static var vadModelURL: URL {
        ConfigStore.configDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(vadModelName)
    }

    nonisolated static var vadReady: Bool {
        let size = (try? FileManager.default
            .attributesOfItem(atPath: vadModelURL.path)[.size] as? Int64) ?? 0
        return (size ?? 0) > 500_000
    }

    nonisolated static var modelURL: URL {
        ConfigStore.configDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelName)
    }

    private static let sources = [
        "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/",
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/",
    ]

    private var task: URLSessionDownloadTask?
    private var sourceIndex = 0
    private lazy var session = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)

    override private init() {
        super.init()
        state = Self.isReady ? .ready : .missing
    }

    nonisolated static var isReady: Bool {
        let size = (try? FileManager.default
            .attributesOfItem(atPath: modelURL.path)[.size] as? Int64) ?? 0
        return (size ?? 0) >= minValidBytes
    }

    func startDownloadIfNeeded() {
        downloadVadIfNeeded()
        guard !Self.isReady else { state = .ready; return }
        if case .downloading = state { return }
        sourceIndex = 0
        beginDownload()
    }

    /// VAD 模型很小，静默补齐即可（含老用户升级路径）
    private func downloadVadIfNeeded() {
        guard !Self.vadReady else { return }
        for base in Self.sources {
            guard let url = URL(string: base + Self.vadModelName) else { continue }
            let dest = Self.vadModelURL
            URLSession.shared.downloadTask(with: url) { location, _, _ in
                guard let location else { return }
                let fm = FileManager.default
                try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try? fm.moveItem(at: location, to: dest)
            }.resume()
            break
        }
    }

    private func beginDownload() {
        guard sourceIndex < Self.sources.count else {
            state = .failed("下载失败，请检查网络后重试")
            return
        }
        guard let url = URL(string: Self.sources[sourceIndex] + Self.modelName) else { return }
        state = .downloading(0)
        let t = session.downloadTask(with: url)
        task = t
        t.resume()
    }

    func cancelDownload() {
        task?.cancel()
        task = nil
        state = Self.isReady ? .ready : .missing
    }

    // MARK: URLSessionDownloadDelegate（后台队列回调）

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            if case .downloading = self.state { self.state = .downloading(progress) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        // 目标目录 + 原子挪入
        let dest = Self.modelURL
        do {
            guard (size ?? 0) >= Self.minValidBytes else {
                throw NSError(domain: "PolishPad", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "文件不完整（\((size ?? 0) / 1_048_576)MB）"])
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            Task { @MainActor in self.state = .ready }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in
                self.sourceIndex += 1
                if self.sourceIndex < Self.sources.count {
                    self.beginDownload()
                } else {
                    self.state = .failed(message)
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            // 换备用源重试
            self.sourceIndex += 1
            self.beginDownload()
        }
    }
}

/// whisper.cpp 上下文包装：加载/释放 + 单段转写。
/// 内部 NSLock 串行化——共享实例可被面板与按住说话两条管线安全复用
final class WhisperTranscriber: @unchecked Sendable {
    /// 常驻共享实例：跨听写会话保留已加载模型（按住说话每次按键才不用
    /// 重新读 874MB）；空闲 5 分钟自动释放约 1GB 内存
    static let shared = WhisperTranscriber(idleUnloadSeconds: 300)

    private var ctx: OpaquePointer?
    private let lock = NSLock()
    private var lastUsed = Date.distantPast
    private var idleTimer: DispatchSourceTimer?

    init(idleUnloadSeconds: TimeInterval? = nil) {
        guard let idle = idleUnloadSeconds else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.ctx != nil, Date().timeIntervalSince(self.lastUsed) > idle {
                whisper_free(self.ctx)
                self.ctx = nil
            }
        }
        timer.resume()
        idleTimer = timer
    }

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ctx != nil
    }

    func load(modelPath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lastUsed = Date()
        guard ctx == nil else { return true }
        var params = whisper_context_default_params()
        params.use_gpu = true
        ctx = whisper_init_from_file_with_params(modelPath, params)
        return ctx != nil
    }

    func unload() {
        lock.lock()
        defer { lock.unlock() }
        if let ctx { whisper_free(ctx) }
        ctx = nil
    }

    /// samples: 16kHz 单声道 Float32（内部持锁，与加载/卸载互斥）
    func transcribe(samples: [Float], language: String, prompt: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        lastUsed = Date()
        guard let ctx, !samples.isEmpty else { return nil }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.no_context = true
        params.no_timestamps = true
        params.suppress_blank = true
        params.temperature = 0
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false

        var result: Int32 = -1
        language.withCString { lang in
            params.language = lang
            if prompt.isEmpty {
                result = whisper_full(ctx, params, samples, Int32(samples.count))
            } else {
                prompt.withCString { p in
                    params.initial_prompt = p
                    result = whisper_full(ctx, params, samples, Int32(samples.count))
                }
            }
        }
        guard result == 0 else { return nil }
        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            // 幻觉闸门：能量 VAD 偶尔会把环境底噪当人声送进来，
            // Whisper 对这种输入会编造文字——按"非人声概率"逐段过滤
            guard whisper_full_get_segment_no_speech_prob(ctx, i) < 0.6 else { continue }
            if let seg = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: seg)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit { unload() }
}
