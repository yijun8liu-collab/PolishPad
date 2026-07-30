import AVFoundation
import Foundation

/// `PolishPad --test-whisper <wav>`：加载模型转写整个 wav 文件后退出。
/// 静默验证引擎链路（模型加载/Metal/分段解码），不启动 UI
enum WhisperTestCLI {
    static func run(wavPath: String) {
        guard WhisperModelStore.isReady else {
            print("模型未下载: \(WhisperModelStore.modelURL.path)")
            exit(1)
        }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: wavPath)) else {
            print("无法读取 wav: \(wavPath)")
            exit(1)
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            print("格式不支持"); exit(1)
        }
        var samples: [Float] = []
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)!
        while true {
            do { try file.read(into: inBuf) } catch { break }
            if inBuf.frameLength == 0 { break }
            let cap = AVAudioFrameCount(Double(inBuf.frameLength)
                * 16000 / file.processingFormat.sampleRate) + 16
            let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap)!
            var fed = false
            converter.convert(to: outBuf, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return inBuf
            }
            if outBuf.frameLength > 0, let ch = outBuf.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: ch,
                                                               count: Int(outBuf.frameLength)))
            }
        }
        print("音频 \(Double(samples.count) / 16000.0) 秒，加载模型…")
        let transcriber = WhisperTranscriber()
        guard transcriber.load(modelPath: WhisperModelStore.modelURL.path) else {
            print("模型加载失败"); exit(1)
        }
        let start = Date()
        // 简单能量切段（与 WhisperPipeline 相同阈值），逐段转写
        var texts: [String] = []
        var segment: [Float] = []
        var silent = 0
        let frame = 1600
        var inSpeech = false
        for i in stride(from: 0, to: samples.count, by: frame) {
            let chunk = Array(samples[i..<min(i + frame, samples.count)])
            var sum: Float = 0
            for v in chunk { sum += v * v }
            let rms = (sum / Float(chunk.count)).squareRoot()
            if inSpeech {
                segment.append(contentsOf: chunk)
                silent = rms < 0.012 ? silent + 1 : 0
                if Double(silent) * 0.1 >= 0.9 || Double(segment.count) / 16000.0 >= 28 {
                    var peak: Float = 0
                    var sum2: Float = 0
                    for v in segment { peak = max(peak, abs(v)); sum2 += v * v }
                    let segRMS = (sum2 / Float(segment.count)).squareRoot()
                    let dur = Double(segment.count) / 16000.0
                    let t = segRMS >= 0.015
                        ? (transcriber.transcribe(samples: segment, language: "zh",
                                                  prompt: "以下是中文口述，夹杂英文技术术语。") ?? "")
                        : ""
                    FileHandle.standardError.write(
                        "[段] \(String(format: "%.1f", dur))s rms=\(String(format: "%.4f", segRMS)) peak=\(String(format: "%.3f", peak)) → \(t.prefix(30))\n"
                        .data(using: .utf8)!)
                    if !t.isEmpty { texts.append(t) }
                    segment = []; inSpeech = false; silent = 0
                }
            } else if rms >= 0.012 {
                inSpeech = true; segment = chunk; silent = 0
            }
        }
        var tailSum: Float = 0
        for v in segment { tailSum += v * v }
        if Double(segment.count) / 16000.0 >= 0.4,
           segment.isEmpty == false,
           (tailSum / Float(segment.count)).squareRoot() >= 0.015,
           let t = transcriber.transcribe(samples: segment, language: "zh",
                                          prompt: "以下是中文口述，夹杂英文技术术语。"),
           !t.isEmpty { texts.append(t) }
        print("耗时 \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        print(texts.joined(separator: " "))
        // 显式释放 ctx 再退出：exit() 跳过 deinit 会让 Metal 清理线程 SIGABRT
        transcriber.unload()
        exit(0)
    }
}
