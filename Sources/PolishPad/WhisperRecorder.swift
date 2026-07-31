import AVFoundation
import Foundation
import Speech
import whisper

/// 队列侧管线：VAD 状态机 + 分段解码。所有成员只在同一条串行队列上访问，
/// 与主线程仅通过 onCommit 回调交互
private final class WhisperPipeline: @unchecked Sendable {
    let transcriber = WhisperTranscriber()
    var language = "zh"
    var prompt = ""
    var generation = 0
    /// (文本, 句子编号, 代次) —— 调用方负责回主线程与代次校验
    var onCommit: ((String, Int, Int) -> Void)?
    /// 说话过程中的滑动窗口预览：当前未完句的临时转写（空串=清除预览）
    var onInterim: ((String, Int) -> Void)?
    /// 停顿刚被检测到（解码开始前）：(句子编号, 代次)。
    /// 融合模式在此刻快照实时侧文字并重开实时段
    var onUtteranceEnd: ((Int, Int) -> Void)?
    /// 句子自增编号：快照与定稿按编号精确配对，杜绝竞态下的重复提交
    private var utteranceId = 0
    /// 人声段实时音频外送（供云端实时引擎逐帧转写）；isStart 含前导音频
    var onSpeechAudio: (([Float], _ isStart: Bool, Int) -> Void)?
    /// 这句解码为空/被判无效：(句子编号, 代次)，调用方决定快照文字的去留
    var onUtteranceDropped: ((Int, Int) -> Void)?
    var onLoadError: (() -> Void)?
    /// 滑动窗口预览开关：融合模式（系统引擎负责实时显示）下关闭省 GPU
    var interimEnabled = true
    /// 上次预览解码时的样本数：每新增 ~1s 音频重解一次
    private var lastInterimSamples = 0

    private var utterance: [Float] = []
    private var preRoll: [Float] = []
    private var inSpeech = false
    private var silentFrames = 0
    /// silero VAD：神经网络人声检测。加载成功后完全取代能量阈值——
    /// 用户环境"说话 0.012-0.019 vs 环境声 0.006-0.008"能量法已不可分
    private var vad: OpaquePointer?
    private var vadCarry: [Float] = []
    private var speechWindows = 0
    /// silero 处理窗口：512 样本 = 32ms @16k
    static let vadWindow = 512
    static let vadEntry: Float = 0.5
    static let vadExit: Float = 0.35
    /// 环境底噪 RMS 滑动估计：静音帧持续更新，人声判定相对它浮动，
    /// 轻声说话（0.008-0.015）和大声朗读（0.02+）都能正确触发
    private var noiseFloor: Float = 0.003

    static let sampleRate = 16000
    static let endSilence = 0.75
    static let maxUtterance = 28.0
    static let preRollSeconds = 0.3

    /// 进入人声：高出底噪即触发。宁多勿漏——误收的噪声段有后级
    /// 能量闸 + polish 兜底，漏掉的话可就真没了（用户实测定标 2026-07-30）
    private var entryRMS: Float { max(noiseFloor * 2.5, 0.005) }
    /// 静音判定用低得多的退出阈值（迟滞）：轻声说话的弱音节 rms 会
    /// 掉到底噪 1.5 倍附近，退出阈值再高句子就被切碎了
    private var exitRMS: Float { max(noiseFloor * 1.3, 0.003) }

    private func dlog(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/polishpad-whisper.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }

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
        if vad == nil, WhisperModelStore.vadReady {
            var params = whisper_vad_default_context_params()
            params.n_threads = 2
            params.use_gpu = false
            vad = whisper_vad_init_from_file_with_params(
                WhisperModelStore.vadModelURL.path, params)
        }
        if let vad { whisper_vad_reset_state(vad) }
        vadCarry = []
        speechWindows = 0
    }

    func process(_ samples: [Float], generation gen: Int) {
        guard gen == generation else { return }
        if let vad {
            processWithVAD(vad, samples, generation: gen)
            return
        }
        processWithEnergy(samples, generation: gen)
    }

    /// silero 路径：逐 32ms 窗口取人声概率，进入 0.5 / 退出 0.35 迟滞
    private func processWithVAD(_ vad: OpaquePointer, _ samples: [Float],
                                generation gen: Int) {
        vadCarry.append(contentsOf: samples)
        let window = Self.vadWindow
        var offset = 0
        while vadCarry.count - offset >= window {
            let chunk = Array(vadCarry[offset..<(offset + window)])
            offset += window
            var prob: Float = 0
            if whisper_vad_detect_speech_no_reset(vad, chunk, Int32(window)),
               whisper_vad_n_probs(vad) > 0,
               let probs = whisper_vad_probs(vad) {
                prob = probs[Int(whisper_vad_n_probs(vad)) - 1]
            }
            step(chunk: chunk, isSpeech: prob >= Self.vadEntry,
                 isSilence: prob < Self.vadExit, generation: gen)
        }
        if offset > 0 { vadCarry.removeFirst(offset) }
    }

    /// VAD 模型缺失时的能量法兜底（旧逻辑）
    private func processWithEnergy(_ samples: [Float], generation gen: Int) {
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(max(samples.count, 1))).squareRoot()
        let frameSeconds = Double(samples.count) / Double(Self.sampleRate)

        if inSpeech {
            utterance.append(contentsOf: samples)
            onSpeechAudio?(samples, false, gen)
            if rms < exitRMS { silentFrames += 1 } else { silentFrames = 0 }
            let silentSeconds = Double(silentFrames) * frameSeconds
            let utteranceSeconds = Double(utterance.count) / Double(Self.sampleRate)
            if silentSeconds >= Self.endSilence || utteranceSeconds >= Self.maxUtterance {
                flush(generation: gen)
            } else if interimEnabled,
                      utterance.count - lastInterimSamples >= Self.sampleRate,
                      utteranceSeconds >= 1.0, utteranceSeconds < 22 {
                // 滑动窗口预览：不等说完，先把已说的部分解码上屏。
                // 解码在本队列串行执行（0.1-1s），期间新音频在队列里排队不丢
                lastInterimSamples = utterance.count
                if let text = transcriber.transcribe(
                    samples: utterance, language: language, prompt: prompt),
                    !text.isEmpty {
                    onInterim?(text, gen)
                }
            }
        } else if rms >= entryRMS {
            dlog("SPEECH-START rms=\(rms) floor=\(noiseFloor) entry=\(entryRMS)")
            inSpeech = true
            silentFrames = 0
            utterance = preRoll + samples
            onSpeechAudio?(utterance, true, gen)
            preRoll = []
        } else {
            // 静音期：更新底噪估计（慢速 EMA，防止把渐强的人声学进去）
            noiseFloor = min(max(noiseFloor * 0.95 + rms * 0.05, 0.0005), 0.02)
            preRoll.append(contentsOf: samples)
            let keep = Int(Self.preRollSeconds * Double(Self.sampleRate))
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
        }
    }

    /// 统一状态机：一个 32ms 窗口的进入/退出决策
    private func step(chunk: [Float], isSpeech: Bool, isSilence: Bool,
                      generation gen: Int) {
        if inSpeech {
            utterance.append(contentsOf: chunk)
            onSpeechAudio?(chunk, false, gen)
            if isSpeech { speechWindows += 1 }
            if isSilence { silentFrames += 1 } else { silentFrames = 0 }
            let silentSeconds = Double(silentFrames) * Double(Self.vadWindow)
                / Double(Self.sampleRate)
            let utteranceSeconds = Double(utterance.count) / Double(Self.sampleRate)
            if silentSeconds >= Self.endSilence || utteranceSeconds >= Self.maxUtterance {
                flush(generation: gen)
            } else if interimEnabled,
                      utterance.count - lastInterimSamples >= Self.sampleRate,
                      utteranceSeconds >= 1.0, utteranceSeconds < 22 {
                lastInterimSamples = utterance.count
                if let text = transcriber.transcribe(
                    samples: utterance, language: language, prompt: prompt),
                    !text.isEmpty {
                    onInterim?(text, gen)
                }
            }
        } else if isSpeech {
            dlog("VAD-SPEECH-START")
            inSpeech = true
            silentFrames = 0
            speechWindows = 1
            utterance = preRoll + chunk
            onSpeechAudio?(utterance, true, gen)
            preRoll = []
        } else {
            preRoll.append(contentsOf: chunk)
            let keep = Int(Self.preRollSeconds * Double(Self.sampleRate))
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
        }
    }

    func flush(generation gen: Int) {
        let audio = utterance
        utterance = []
        inSpeech = false
        silentFrames = 0
        lastInterimSamples = 0
        let seconds = Double(audio.count) / Double(Self.sampleRate)
        var sum2: Float = 0
        for v in audio { sum2 += v * v }
        let segRMS = (sum2 / Float(max(audio.count, 1))).squareRoot()
        // 碎片/伪人声闸门：底噪触发的短促段会让 Whisper 凭空编造文字。
        // 闸门相对底噪浮动——大声朗读和轻声口述都不误伤
        let hadSpeechWindows = speechWindows
        speechWindows = 0
        if let vad { whisper_vad_reset_state(vad) }
        // 伪段闸门：VAD 路径按人声窗口数（≥8 窗 = 0.26s 真人声），
        // 能量兜底路径沿用相对底噪的闸
        let passes: Bool
        if vad != nil {
            passes = seconds >= 0.3 && hadSpeechWindows >= 8
        } else {
            let gate = max(noiseFloor * 1.2, 0.0045)
            passes = seconds >= 0.3 && segRMS >= gate
        }
        guard passes else {
            dlog("DROP \(String(format: "%.1f", seconds))s rms=\(segRMS) speechWin=\(hadSpeechWindows)")
            onInterim?("", gen)   // 清掉可能残留的预览
            return
        }
        // 先通知"这句说完了"，让调用方立刻快照实时侧文字——
        // 解码期间用户可能已在说下一句，晚了快照会混入下一句开头
        utteranceId += 1
        let uid = utteranceId
        onUtteranceEnd?(uid, gen)
        dlog("DECODE#\(uid) \(String(format: "%.1f", seconds))s rms=\(segRMS) speechWin=\(hadSpeechWindows)")
        guard let text = transcriber.transcribe(
            samples: audio, language: language, prompt: prompt),
            !text.isEmpty else {
            dlog("EMPTY-RESULT#\(uid)")
            onInterim?("", gen)
            onUtteranceDropped?(uid, gen)
            return
        }
        onCommit?(text, uid, gen)
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
    /// 当前未完句的滑动预览（仅系统引擎不可用时兜底）
    private var interim = ""
    private var language = "zh"
    private var generation = 0

    // 融合模式：系统识别负责当前未完句的逐字实时显示（丝滑），
    // Whisper 每句定稿后原地替换（准确）。系统侧文字同时是安全网——
    // Whisper 闸门误丢的段，尾巴文字仍会保留进最终结果
    /// 云端实时层（讯飞）：配置开启且凭证齐全时优先，失败回退 SFSpeech
    private var xfyunTail: XFYunTailEngine?

    private let tailBox = RequestBox()
    private var tailRecognizer: SFSpeechRecognizer?
    private var tailTask: SFSpeechRecognitionTask?
    private var tailCommitted = ""
    private var tailPartial = ""
    private var tailActive = false
    /// 尾巴段代次：老任务被取消后的迟到回调直接丢弃，防止定稿后旧句复活
    private var tailGen = 0
    /// 停顿快照队列：每句的实时侧版本按句子编号排队，等对应的 Whisper
    /// 定稿来"二选一"。队列化后 Whisper 慢半拍也不会重复提交
    private var pendingSnaps: [(id: Int, text: String)] = []

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
                // 系统识别授权用于融合模式的实时尾巴；被拒不阻塞，退回纯 Whisper
                SFSpeechRecognizer.requestAuthorization { _ in
                    Task { @MainActor in self.beginSession(localeId: localeId) }
                }
            }
        }
    }

    private func beginSession(localeId: String) {
        language = localeId.lowercased().hasPrefix("zh") ? "zh"
            : String(localeId.prefix(2)).lowercased()
        committed = ""
        interim = ""
        generation += 1
        let gen = generation
        let lang = language
        let prompt = Self.buildPrompt(language: language)

        pipeline.onCommit = { [weak self] text, uid, g in
            Task { @MainActor in
                guard let self, g == self.generation else { return }
                self.commit(text, utteranceId: uid)
            }
        }
        pipeline.onInterim = { [weak self] text, g in
            Task { @MainActor in
                guard let self, g == self.generation else { return }
                self.interim = text
                self.emit()
            }
        }
        pipeline.onUtteranceEnd = { [weak self] uid, g in
            Task { @MainActor in
                guard let self, g == self.generation,
                      self.tailActive || self.xfyunTail != nil else { return }
                let snap = self.joinTail(self.tailCommitted, self.tailPartial)
                Self.flog("SNAP#\(uid) \(snap.prefix(24))")
                self.pendingSnaps.append((uid, snap))
                self.tailCommitted = ""
                self.tailPartial = ""
                if let tail = self.xfyunTail {
                    // 会话终稿比停顿快照完整：到达时若这句还没被定稿就升级
                    tail.endUtterance { [weak self] final in
                        guard let self, !final.isEmpty,
                              let idx = self.pendingSnaps.firstIndex(where: { $0.id == uid })
                        else { return }
                        Self.flog("UPGRADE#\(uid) \(final.prefix(24))")
                        self.pendingSnaps[idx].text = final
                        self.emit()
                    }
                } else {
                    self.startTailSegment()
                }
                self.emit()
            }
        }
        pipeline.onUtteranceDropped = { [weak self] uid, g in
            Task { @MainActor in
                guard let self, g == self.generation else { return }
                // Whisper 没给出结果：实时版就是这句的最终版（安全网）
                if let idx = self.pendingSnaps.firstIndex(where: { $0.id == uid }) {
                    let snap = self.pendingSnaps.remove(at: idx)
                    if !snap.text.isEmpty { self.appendCommitted(snap.text) }
                }
                self.emit()
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

        // 融合模式装配：系统识别可用则由它负责实时尾巴，关闭滑动窗口预览
        tailCommitted = ""
        tailPartial = ""
        pendingSnaps = []
        tailRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
        tailActive = SFSpeechRecognizer.authorizationStatus() == .authorized
            && tailRecognizer?.isAvailable == true

        // 云端实时层：讯飞（大模型 → 经典版），不可用自动回退 SFSpeech
        xfyunTail = nil
        let cfg = ConfigStore.loadRaw()
        if cfg?.realtimeEngine == "xfyun",
           let appId = cfg?.xfyunAppId, !appId.isEmpty,
           let apiKey = cfg?.xfyunApiKey, !apiKey.isEmpty,
           let apiSecret = cfg?.xfyunApiSecret, !apiSecret.isEmpty {
            let engine = XFYunTailEngine(appId: appId, apiKey: apiKey, apiSecret: apiSecret)
            engine.onPartial = { [weak self] text in
                guard let self, self.isRecording else { return }
                self.tailPartial = text
                self.emit()
            }
            engine.onUnavailable = { [weak self] in
                guard let self else { return }
                // 三级降级末端：回退系统 SFSpeech
                self.xfyunTail = nil
                if self.tailActive { self.startTailSegment() }
                self.emit()
            }
            xfyunTail = engine
            pipe.onSpeechAudio = { [weak self] samples, isStart, g in
                Task { @MainActor in
                    guard let self, g == self.generation,
                          let tail = self.xfyunTail else { return }
                    if isStart { tail.startUtterance() }
                    tail.feed(samples)
                }
            }
        } else {
            pipe.onSpeechAudio = nil
        }
        pipe.interimEnabled = !tailActive && xfyunTail == nil

        input.removeTap(onBus: 0)
        let box = tailBox
        let feedTail = tailActive
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if feedTail { box.append(buffer) }
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
        if tailActive, xfyunTail == nil { startTailSegment() }
    }

    /// 开一段系统识别（每次 Whisper 定稿后重开，让尾巴只覆盖"未定稿"部分）
    private func startTailSegment() {
        guard let recognizer = tailRecognizer, recognizer.isAvailable else {
            tailActive = false
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        tailTask?.cancel()
        tailBox.set(request)
        tailGen += 1
        let gen = tailGen
        tailTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in self?.handleTail(result: result, error: error, gen: gen) }
        }
    }

    private func handleTail(result: SFSpeechRecognitionResult?, error: Error?, gen: Int) {
        guard isRecording, tailActive, gen == tailGen else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                if !text.isEmpty { tailCommitted = joinTail(tailCommitted, text) }
                tailPartial = ""
                startTailSegment()
            } else {
                tailPartial = text
            }
            emit()
        } else if error != nil {
            if !tailPartial.isEmpty {
                tailCommitted = joinTail(tailCommitted, tailPartial)
                tailPartial = ""
            }
            startTailSegment()
        }
    }

    private func joinTail(_ head: String, _ tail: String) -> String {
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + (language == "zh" ? "" : " ") + tail
    }

    private static func flog(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] FUSION \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/polishpad-whisper.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }

    private func commit(_ text: String, utteranceId uid: Int) {
        interim = ""
        // 按编号认领这句的快照：Whisper 慢半拍时快照在队列里安然等待，
        // 不会被后续句子的时序挤出去重复提交
        var snapshot: String?
        if let idx = pendingSnaps.firstIndex(where: { $0.id == uid }) {
            snapshot = pendingSnaps.remove(at: idx).text
        }
        // 版本选择：含英文（Whisper 的价值所在）→ Whisper 版替换；
        // 纯中文 → 保留实时引擎那句，不做无意义的替换跳动；
        // 实时那句为空（漏听）→ 无论中英都用 Whisper 版
        let hasEnglish = text.range(of: "[A-Za-z]", options: .regularExpression) != nil
        Self.flog("CLAIM#\(uid) whisper=\(text.prefix(24)) snap=\((snapshot ?? "无").prefix(24)) en=\(hasEnglish)")
        let chosen: String
        if !tailActive && xfyunTail == nil {
            chosen = text
        } else if hasEnglish {
            chosen = text
        } else if let snapshot, !snapshot.isEmpty {
            chosen = snapshot
        } else {
            chosen = text
        }
        appendCommitted(chosen)
    }

    private func appendCommitted(_ text: String) {
        let separator = language == "zh" ? "" : " "
        committed = committed.isEmpty ? text : committed + separator + text
        emit()
    }

    private func emit() {
        let separator = language == "zh" ? "" : " "
        let hasTail = tailActive || xfyunTail != nil
        let live = hasTail ? joinTail(tailCommitted, tailPartial) : interim
        var parts = [committed]
        parts.append(contentsOf: pendingSnaps.sorted { $0.id < $1.id }.map(\.text))
        if !live.isEmpty { parts.append(live) }
        let full = parts.filter { !$0.isEmpty }.joined(separator: separator)
        onPartial?(full)
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        xfyunTail?.stop()
        xfyunTail = nil
        tailBox.finish()
        tailTask?.cancel()
        tailTask = nil
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
