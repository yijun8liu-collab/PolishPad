import AVFoundation
import Foundation

/// `PolishPad --test-xfyun <wav>`：取音频前 20 秒按实时节奏喂给讯飞实时引擎，
/// 打印流式部分结果与终稿。验证鉴权/协议/降级链，不启动 UI
enum XFYunTestCLI {
    @MainActor
    static func run(wavPath: String, engine engineName: String = "xfyun") {
        let cfg = ConfigStore.loadRaw()
        let engine: (any CloudTailEngine)
        if engineName == "tencent" {
            guard let appId = cfg?.tencentAppId, let sid = cfg?.tencentSecretId,
                  let sk = cfg?.tencentSecretKey else {
                print("配置缺少腾讯凭证"); exit(1)
            }
            engine = TencentTailEngine(appId: appId, secretId: sid, secretKey: sk)
        } else {
            guard let appId = cfg?.xfyunAppId, let apiKey = cfg?.xfyunApiKey,
                  let apiSecret = cfg?.xfyunApiSecret else {
                print("配置缺少讯飞凭证"); exit(1)
            }
            engine = XFYunTailEngine(appId: appId, apiKey: apiKey, apiSecret: apiSecret)
        }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: wavPath)) else {
            print("无法读取 wav"); exit(1)
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        var samples: [Float] = []
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)!
        while samples.count < 20 * 16000 {
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
        samples = Array(samples.prefix(20 * 16000))
        print("音频 \(samples.count / 16000)s，逐帧实时喂入…")

        var finalText: String?
        var lastPartial = ""
        engine.onPartial = { text in
            if text != lastPartial {
                print("[实时] \(text.suffix(40))")
                lastPartial = text
            }
        }
        engine.onFinal = { text in finalText = text }
        engine.onUnavailable = { print("云端引擎不可用（已降级到底）"); finalText = "" }

        engine.startUtterance()
        let chunk = 640   // 40ms
        var i = 0
        while i < samples.count {
            engine.feed(Array(samples[i..<min(i + chunk, samples.count)]))
            i += chunk
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        engine.endUtterance(nil)
        let deadline = Date().addingTimeInterval(8)
        while finalText == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        print("=== 终稿 ===")
        print(finalText ?? lastPartial)
        exit(finalText == nil && lastPartial.isEmpty ? 1 : 0)
    }
}
