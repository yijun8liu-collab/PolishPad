import AppKit

/// 无面板"按住说话"：全局修饰键
/// - 按住 ≥0.35s（对讲）：松开即结束
/// - 短按 <0.35s（锁定）：再按一次结束，Esc 取消
/// 结束后：听写定稿 → 当前场景 LLM 润色 → 粘贴到焦点光标处。
/// 原文进历史（可找回），失败时原始转写留在剪贴板。
/// 一次性闸门（跨线程安全）：LLM 首字到达时触发绽开，仅一次
final class BloomGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fireOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// 按时间节流（跨线程安全）：流式回调降频到人眼刷新节奏
final class TimeThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last = Date.distantPast

    init(interval: TimeInterval) { self.interval = interval }

    func shouldFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Date().timeIntervalSince(last) >= interval else { return false }
        last = Date()
        return true
    }
}

@MainActor
final class PushToTalkController {
    /// 可选热键：单个右侧修饰键（左手打字右手够得着，且不与输入法冲突）
    static let keyOptions: [(key: String, code: CGKeyCode, flag: NSEvent.ModifierFlags,
                             zh: String, en: String, symbol: String)] = [
        ("right_cmd", 54, .command, "右 Command", "Right Command", "右 ⌘"),
        ("right_shift", 60, .shift, "右 Shift", "Right Shift", "右 ⇧"),
        ("right_ctrl", 62, .control, "右 Control", "Right Control", "右 ⌃"),
    ]

    private enum State {
        case idle
        case pressed(Date)   // 按下未松：可能对讲可能锁定
        case locked          // 短按锁定录音中
        case processing
    }

    private var state: State = .idle
    private var monitors: [Any] = []
    private var whisperRecorder: WhisperRecorder?
    private var systemRecorder: SpeechRecorder?
    private var liveText = ""
    private var lastLiveUpdate = Date.distantPast
    private var targetApp: NSRunningApplication?
    private var processingTask: Task<Void, Never>?
    private var lockTimeout: Task<Void, Never>?
    var isPanelVisible: (() -> Bool)?

    /// 按配置装配全局监听（设置保存后重新调用）
    func rearm() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        guard let key = ConfigStore.loadRaw()?.pttKey,
              let option = Self.keyOptions.first(where: { $0.key == key }) else { return }
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.handleFlags(event, option: option) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged,
                                                     handler: flagsHandler) {
            monitors.append(m)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            flagsHandler(event)
            return event
        } as Any)
        // Esc：锁定录音/处理中取消
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { Task { @MainActor in self?.cancel() } }
        }) {
            monitors.append(m)
        }
    }

    private func handleFlags(_ event: NSEvent, option: (key: String, code: CGKeyCode,
                             flag: NSEvent.ModifierFlags, zh: String, en: String,
                             symbol: String)) {
        guard event.keyCode == option.code else { return }
        let isDown = event.modifierFlags.contains(option.flag)
        switch (state, isDown) {
        case (.idle, true):
            guard isPanelVisible?() != true else { return }
            state = .pressed(Date())
            startRecording()
        case (.pressed(let downAt), false):
            if Date().timeIntervalSince(downAt) < 0.35 {
                // 短按 → 锁定录音
                state = .locked
                HUD.shared.updateWorking(UILang.t(
                    "说话中… 结束请再按 \(option.symbol)",
                    "Speaking… press \(option.symbol) again to finish"))
                armLockTimeout()
            } else {
                finishRecording()   // 对讲：松开结束
            }
        case (.locked, true):
            finishRecording()       // 锁定：再按结束
        default:
            break
        }
    }

    /// 锁定模式最长 3 分钟，防止忘关一直录
    private func armLockTimeout() {
        lockTimeout?.cancel()
        lockTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard let self, case .locked = self.state else { return }
            self.finishRecording()
        }
    }

    private func startRecording() {
        liveText = ""
        lastLiveUpdate = .distantPast
        targetApp = NSWorkspace.shared.frontmostApplication
        HUD.shared.showListening(UILang.t("聆听中", "Listening"))

        let config = ConfigStore.loadRaw()
        let localeId = config?.speechLocale ?? "zh-CN"
        let applyLive: (String) -> Void = { [weak self] text in
            guard let self else { return }
            self.liveText = text
            self.lastLiveUpdate = Date()
            let tail = String(text.suffix(26))
            if !tail.isEmpty { HUD.shared.updateWorking(tail) }
        }
        let onError: (String) -> Void = { [weak self] message in
            HUD.shared.flashSuccess(message)
            self?.teardownRecorders()
            self?.state = .idle
        }
        let applyLevel: (Float) -> Void = { level in
            HUD.shared.updateLevel(level)
        }
        let finalizeReady = config?.effectiveFinalizeEngine == "whisper"
            && WhisperModelStore.isReady
        if finalizeReady || SessionModel.cloudRealtimeConfigured(config) {
            let r = WhisperRecorder()
            r.onPartial = applyLive
            r.onError = onError
            r.onLevel = applyLevel
            whisperRecorder = r
            r.start(localeId: localeId)
        } else {
            let r = SpeechRecorder()
            r.onPartial = applyLive
            r.onError = onError
            r.onLevel = applyLevel
            systemRecorder = r
            r.start(localeId: localeId)
        }
    }

    private func teardownRecorders() {
        whisperRecorder?.stop()
        whisperRecorder = nil
        systemRecorder?.stop()
        systemRecorder = nil
        lockTimeout?.cancel()
    }

    private func finishRecording() {
        lockTimeout?.cancel()
        state = .processing
        // V2 预备-收束：气泡鼓一口气再吸入成光点，光点呼吸陪伴润色
        HUD.shared.condense()
        systemRecorder?.stop()
        if let recorder = whisperRecorder {
            // 双通道竞速：收尾解码完成即刻走；超过 1 秒没等到就用当前
            // 已有文本（讯飞/桥版本）收工——LLM 纠错兜底，不为完美死等
            var fired = false
            let go: @MainActor () -> Void = { [weak self] in
                guard let self, !fired else { return }
                fired = true
                self.processingTask = Task { [weak self] in
                    if Task.isCancelled { return }
                    await self?.runPipeline()
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                go()
            }
            recorder.stop { go() }
        } else {
            // 系统引擎：partial 已实时到位，稍候片刻即可
            processingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                await self?.runPipeline()
            }
        }
    }

    private func runPipeline() async {
        defer {
            teardownRecorders()
            state = .idle
        }
        let transcript = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            HUD.shared.flashSuccess(UILang.t("没有听到内容", "Heard nothing"))
            return
        }
        let snapshot = ClipboardSnapshot.capture()
        let pasteboard = NSPasteboard.general
        do {
            // HUD 编舞：LLM 首字到达即从光点绽开，随后流式滚动产出
            let throttle = TimeThrottle(interval: 0.12)
            let bloomed = BloomGate()
            let output = try await LLMClient.polishOnce(
                transcript, targetBundleID: targetApp?.bundleIdentifier
            ) { partial in
                let tail = String(partial.suffix(26))
                if bloomed.fireOnce() {
                    Task { @MainActor in HUD.shared.bloom(tail) }
                    return
                }
                guard throttle.shouldFire() else { return }
                Task { @MainActor in HUD.shared.updateWorking(tail) }
            }
            if Task.isCancelled { snapshot.restore(); return }
            // 原始转写进历史，随时可找回
            HistoryStore.shared.upsert(
                id: UUID(), original: transcript, versions: [output],
                preset: ConfigStore.loadRaw()?.promptPreset ?? "polish")
            // 用户已切走窗口就不盲贴
            if let app = targetApp,
               NSWorkspace.shared.frontmostApplication?.processIdentifier
                   != app.processIdentifier {
                pasteboard.clearContents()
                pasteboard.setString(output, forType: .string)
                HUD.shared.flashSuccess(UILang.t(
                    "已复制（原窗口已切走，请手动粘贴）",
                    "Copied (window changed — paste manually)"))
                return
            }
            pasteboard.clearContents()
            pasteboard.setString(output, forType: .string)
            KeySimulator.postCommandKey(KeySimulator.keyV)
            ReplacementUndo.shared.record(pasted: output, replaced: nil, app: targetApp)
            try? await Task.sleep(nanoseconds: 600_000_000)
            snapshot.restore()
            HUD.shared.successInPlace(UILang.t("已粘贴", "Pasted"))
            NSSound(named: "Glass")?.play()
        } catch {
            // 失败兜底：原始转写留在剪贴板，说过的话不丢
            pasteboard.clearContents()
            pasteboard.setString(transcript, forType: .string)
            _ = error
            HUD.shared.flashSuccess(UILang.t("优化失败，原文已复制",
                                             "Refine failed — raw text copied"))
        }
    }

    private func cancel() {
        switch state {
        case .locked, .pressed:
            teardownRecorders()
            state = .idle
            HUD.shared.flashSuccess(UILang.t("已取消", "Cancelled"))
        case .processing:
            processingTask?.cancel()
            teardownRecorders()
            state = .idle
            HUD.shared.flashSuccess(UILang.t("已取消", "Cancelled"))
        case .idle:
            break
        }
    }
}
