import AVFoundation
import Foundation

/// 队列侧管线：VAD 状态机 + 分段解码。所有成员只在同一条串行队列上访问，
/// 与主线程仅通过 onCommit 回调交互
private final class WhisperPipeline: @unchecked Sendable {
    let transcriber = WhisperTranscriber()
    var language = "zh"
    var prompt = ""
    var generation = 0
    /// (文本, 代次) —— 调用方负责回主线程与代次校验
    var onCommit: ((String, Int) -> Void)?
    var onLoadError: (() -> Void)?

    private var utterance: [Float] = []
    private var preRoll: [Float] = []
    private var inSpeech = false
    private var silentFrames = 0

    static let sampleRate = 16000
    /// 判定为人声的 RMS 阈值（实测环境噪声 ~0.001，人声 0.03+）
    static let speechRMS: Float = 0.012
    static let endSilence = 0.9
    static let maxUtterance = 28.0
    static let preRollSeconds = 0.3

    func reset(language: String, prompt: String, generation: Int) {
        self.language = language
        self.prompt = prompt
        self.generation = generation
        utterance = []
        preRoll = []
        inSpeech = false
        silentFrames = 0
        if !transcriber.isLoaded,
           !transcriber.load(modelPath: WhisperModelStore.modelURL.path) {
            onLoadError?()
        }
    }

    func process(_ samples: [Float], generation gen: Int) {
        guard gen == generation else { return }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(max(samples.count, 1))).squareRoot()
        let frameSeconds = Double(samples.count) / Double(Self.sampleRate)

        if inSpeech {
            utterance.append(contentsOf: samples)
            if rms < Self.speechRMS { silentFrames += 1 } else { silentFrames = 0 }
            let silentSeconds = Double(silentFrames) * frameSeconds
            let utteranceSeconds = Double(utterance.count) / Double(Self.sampleRate)
            if silentSeconds >= Self.endSilence || utteranceSeconds >= Self.maxUtterance {
                flush(generation: gen)
            }
        } else if rms >= Self.speechRMS {
            inSpeech = true
            silentFrames = 0
            utterance = preRoll + samples
            preRoll = []
        } else {
            preRoll.append(contentsOf: samples)
            let keep = Int(Self.preRollSeconds * Double(Self.sampleRate))
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
        }
    }

    func flush(generation gen: Int) {
        let audio = utterance
        utterance = []
        inSpeech = false
        silentFrames = 0
        // 不足 0.4s 的碎片多为噪声
        guard Double(audio.count) / Double(Self.sampleRate) >= 0.4 else { return }
        // 整段能量闸门：底噪触发的伪人声段（实测 rms<0.013）会让 Whisper
        // 凭空编造文字，真实语音整段 rms 在 0.022+，0.015 取中间留裕量
        var sum2: Float = 0
        for v in audio { sum2 += v * v }
        guard (sum2 / Float(audio.count)).squareRoot() >= 0.015 else { return }
        guard let text = transcriber.transcribe(
            samples: audio, language: language, prompt: prompt),
            !text.isEmpty else { return }
        onCommit?(text, gen)
    }

    func unload() { transcriber.unload() }
}

/// Whisper 本地听写引擎：AVAudioEngine 采集 → 16k 单声道 →
/// 能量 VAD 按停顿切段 → whisper.cpp 整段转写 → 累计提交。
/// 对外接口与 SpeechRecorder 完全一致，SessionModel 按配置二选一。
///
/// 与系统引擎的体验差异：不逐字出字，说完一句停顿约 1 秒后整句出现
@MainActor
final class WhisperRecorder {
    private(set) var isRecording = false
    var onPartial: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let pipeline = WhisperPipeline()
    /// VAD、缓冲、解码统一在这条串行队列上，whisper ctx 无并发访问
    private let queue = DispatchQueue(label: "polishpad.whisper", qos: .userInitiated)

    private var committed = ""
    private var language = "zh"
    private var generation = 0

    func toggle(localeId: String) {
        if isRecording { stop() } else { start(localeId: localeId) }
    }

    func start(localeId: String) {
        guard !isRecording else { return }
        guard WhisperModelStore.isReady else {
            onError?("Whisper 模型未就绪，请到 设置 → 行为 下载")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.onError?("麦克风权限被拒绝：请在 系统设置 → 隐私与安全性 → 麦克风 中允许 PolishPad")
                    return
                }
                self.beginSession(localeId: localeId)
            }
        }
    }

    private func beginSession(localeId: String) {
        language = localeId.lowercased().hasPrefix("zh") ? "zh"
            : String(localeId.prefix(2)).lowercased()
        committed = ""
        generation += 1
        let gen = generation
        let lang = language
        let prompt = Self.buildPrompt(language: language)

        pipeline.onCommit = { [weak self] text, g in
            Task { @MainActor in
                guard let self, g == self.generation else { return }
                self.commit(text)
            }
        }
        pipeline.onLoadError = { [weak self] in
            Task { @MainActor in
                self?.onError?("Whisper 模型加载失败，请到设置里重新下载")
                self?.stop()
            }
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            onError?("没有可用的麦克风输入设备")
            return
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperPipeline.sampleRate), channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: format, to: targetFormat) else {
            onError?("音频格式初始化失败")
            return
        }

        let pipe = pipeline
        let workQueue = queue
        workQueue.async { pipe.reset(language: lang, prompt: prompt, generation: gen) }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // 音频线程：仅重采样，随后转投串行队列
            let ratio = Double(WhisperPipeline.sampleRate) / format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                             frameCapacity: capacity) else { return }
            var fed = false
            var conversionError: NSError?
            converter.convert(to: out, error: &conversionError) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, out.frameLength > 0,
                  let channel = out.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel,
                                                    count: Int(out.frameLength)))
            workQueue.async { pipe.process(samples, generation: gen) }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            onError?("启动录音失败：\(error.localizedDescription)")
            return
        }
        isRecording = true
        onStateChange?(true)
    }

    private func commit(_ text: String) {
        let separator = language == "zh" ? "" : " "
        committed = committed.isEmpty ? text : committed + separator + text
        onPartial?(committed)
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        let gen = generation
        let pipe = pipeline
        queue.async {
            // 收尾：把最后未满静音阈值的一句也解码出来，然后释放模型（约 1GB 内存）
            pipe.flush(generation: gen)
            pipe.unload()
        }
        onStateChange?(false)
    }

    /// 术语表注入提示词：Whisper 对 initial_prompt 里的词有明显偏置，
    /// 正好用来锁定用户的专有名词
    private static func buildPrompt(language: String) -> String {
        let glossary = (ConfigStore.loadRaw()?.glossary ?? [])
            .map { $0.split(separator: "=").first.map(String.init) ?? $0 }
            .filter { !$0.isEmpty }
        let terms = glossary.joined(separator: "、")
        if language == "zh" {
            return "以下是中文口述，夹杂英文技术术语。" + (terms.isEmpty ? "" : "常用词：\(terms)。")
        }
        return terms.isEmpty ? "" : "Technical terms: \(terms)."
    }
}
