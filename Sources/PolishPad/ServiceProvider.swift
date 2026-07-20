import AppKit

/// 线程安全的一次性结果传递
private final class ResultBox {
    private let lock = NSLock()
    private var value: Result<String, Error>?

    func set(_ result: Result<String, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func get() -> Result<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// macOS 系统「服务」菜单提供方：出现在任意应用的 右键 → 服务 子菜单中。
/// 服务定义见 build.sh 里 Info.plist 的 NSServices 段。
final class ServiceProvider: NSObject {
    private let quickPolish: QuickPolishController

    init(quickPolish: QuickPolishController) {
        self.quickPolish = quickPolish
    }

    /// 「PolishPad：润色并替换」——声明了返回类型，系统会用写回
    /// pasteboard 的内容自动替换调用方的选中文本，不需要模拟按键
    @objc func polishSelection(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let input = pboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !input.isEmpty else {
            error.pointee = "没有选中文本"
            return
        }

        Task { @MainActor in HUD.shared.showWorking("润色中…") }

        let box = ResultBox()
        Task.detached {
            do {
                box.set(.success(try await LLMClient.polishOnce(input)))
            } catch {
                box.set(.failure(error))
            }
        }
        // 服务回调必须同步返回结果：泵 RunLoop 等待，期间主线程 UI 不冻结
        var result = box.get()
        while result == nil {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            result = box.get()
        }

        switch result! {
        case .success(let output):
            pboard.clearContents()
            pboard.setString(output, forType: .string)
            Task { @MainActor in HUD.shared.flashSuccess("已替换") }
        case .failure(let err):
            Task { @MainActor in HUD.shared.hide() }
            error.pointee = err.localizedDescription as NSString
        }
    }

    /// 「PolishPad：全选润色并替换」——不声明返回类型，调用方不阻塞，
    /// 由我们模拟 ⌘A/⌘C/⌘V 完成整个流程
    @objc func polishAll(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        Task { @MainActor in
            self.quickPolish.trigger(.all)
        }
    }
}
