import AVFoundation
import Speech

/// 供音频线程安全地向"当前段"的识别请求追加数据
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        request = newRequest
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    func finish() {
        lock.lock()
        let current = request
        request = nil
        lock.unlock()
        current?.endAudio()
    }
}

/// macOS 原生语音识别：AVAudioEngine 采集 + SFSpeechRecognizer 流式转写。
///
/// 连续听写：系统在较长静默后会把当前段"敲定"（isFinal）并结束识别任务。
/// 这里在收到 isFinal 时把该段提交进 `committed`，麦克风不中断，
/// 立即开启下一段识别任务，对外始终报告 committed + 当前段临时结果，
/// 所以长停顿不会丢失之前的内容。
@MainActor
final class SpeechRecorder {
    private(set) var isRecording = false
    /// 每次识别结果更新时回调（整段累计文本，非增量）
    var onPartial: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let requestBox = RequestBox()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var localeId = "zh-CN"

    /// 已敲定的段落累计
    private var committed = ""
    /// 当前段最新的临时结果
    private var lastPartial = ""
    private var segmentStart = Date()
    private var rapidRestarts = 0

    /// 临时诊断日志（定位长停顿丢内容问题）
    private func slog(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/polishpad-speech.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }

    func toggle(localeId: String) {
        if isRecording {
            stop()
        } else {
            start(localeId: localeId)
        }
    }

    func start(localeId: String) {
        guard !isRecording else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.onError?("语音识别权限被拒绝：请在 系统设置 → 隐私与安全性 → 语音识别 中允许 PolishPad")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.onError?("麦克风权限被拒绝：请在 系统设置 → 隐私与安全性 → 麦克风 中允许 PolishPad")
                            return
                        }
                        self.beginSession(localeId: localeId)
                    }
                }
            }
        }
    }

    private func beginSession(localeId: String) {
        self.localeId = localeId
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)) else {
            onError?("不支持的语音识别语言：\(localeId)")
            return
        }
        guard recognizer.isAvailable else {
            onError?("语音识别服务暂不可用，请稍后再试")
            return
        }
        self.recognizer = recognizer
        committed = ""
        lastPartial = ""
        rapidRestarts = 0

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            onError?("没有可用的麦克风输入设备")
            return
        }
        input.removeTap(onBus: 0)
        let box = requestBox
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.append(buffer)
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
        startRecognitionSegment()
    }

    /// 开启一段识别任务（听写期间可被多次调用，麦克风不中断）
    private func startRecognitionSegment() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // 本地识别没有服务端的时长限制，支持时优先
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        requestBox.set(request)
        segmentStart = Date()
        slog("SEGMENT-START onDevice=\(recognizer.supportsOnDeviceRecognition) committed=\(committed.count)字")

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(result: result, error: error)
            }
        }
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        // 手动 stop 之后的迟到回调：不再更新文本
        guard isRecording else { return }

        if let result {
            rapidRestarts = 0
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                // 静默后系统敲定本段：提交并无缝开下一段。
                // 防御：final 偶尔为空或被截短（静默过久时识别器放弃），
                // 此时用最后一次临时结果兜底，避免前文蒸发
                let finalText = (text.isEmpty || text.count * 3 < lastPartial.count)
                    ? lastPartial : text
                slog("FINAL text=\(text.count)字 lastPartial=\(lastPartial.count)字 -> commit \(finalText.count)字")
                commit(finalText)
                lastPartial = ""
                startRecognitionSegment()
            } else {
                // 识别器偶发不带 isFinal 的重置：临时结果突然大幅变短，视为新段开始
                if lastPartial.count > 6, text.count * 2 < lastPartial.count {
                    slog("SHRINK-RESET lastPartial=\(lastPartial.count)字 new=\(text.count)字，先提交旧段")
                    commit(lastPartial)
                }
                lastPartial = text
                emit(current: text)
            }
        } else if error != nil {
            slog("ERROR \((error as NSError?).map { "\($0.domain)#\($0.code)" } ?? "?") "
                + "lastPartial=\(lastPartial.count)字 committed=\(committed.count)字")
            // 静默超时/服务断开：把已有临时结果提交后重开一段
            if !lastPartial.isEmpty {
                commit(lastPartial)
                lastPartial = ""
            }
            // 防止服务不可用时无限快速重启
            if Date().timeIntervalSince(segmentStart) < 1 {
                rapidRestarts += 1
            } else {
                rapidRestarts = 0
            }
            if rapidRestarts >= 3 {
                stop()
                onError?("语音识别连续失败，已停止听写")
                return
            }
            startRecognitionSegment()
        }
    }

    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            committed = joined(committed, trimmed)
        }
        slog("COMMIT +\(trimmed.count)字 -> committed=\(committed.count)字")
        emit(current: "")
    }

    private func emit(current: String) {
        onPartial?(joined(committed, current))
    }

    private func joined(_ head: String, _ tail: String) -> String {
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        let separator = localeId.lowercased().hasPrefix("zh") ? "" : " "
        return head + separator + tail
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        requestBox.finish()
        task?.cancel()
        task = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        onStateChange?(false)
    }
}
