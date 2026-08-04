import AppKit

/// 安装位置守护：从"下载"目录或安全转移（Translocation）沙箱运行时，
/// 引导一键搬进 /Applications——那两种状态下自更新无法原地替换，
/// 用户会永远卡在"跳浏览器手动下载"的死循环里
@MainActor
enum AppInstaller {
    static func offerMoveToApplicationsIfNeeded() {
        let bundlePath = Bundle.main.bundlePath
        let translocated = bundlePath.contains("/AppTranslocation/")
        let downloads = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "~/Downloads"
        let inDownloads = bundlePath.hasPrefix(downloads)
        guard translocated || inDownloads else { return }

        let alert = NSAlert()
        alert.messageText = UILang.t("把 PolishPad 移到「应用程序」文件夹？",
                                     "Move PolishPad to the Applications folder?")
        alert.informativeText = UILang.t(
            "当前从下载目录（或系统安全沙箱）运行，一键自动更新将不可用，"
                + "每次升级都要手动下载。移动后即可享受应用内一键升级。",
            "Running from Downloads (or the security sandbox) disables one-click "
                + "updates — you'd have to download every release manually. "
                + "Moving fixes this permanently.")
        alert.addButton(withTitle: UILang.t("移动并重新打开", "Move & Relaunch"))
        alert.addButton(withTitle: UILang.t("以后再说", "Later"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try install(from: bundlePath, downloads: downloads)
        } catch {
            let fail = NSAlert()
            fail.messageText = UILang.t("移动失败", "Move failed")
            fail.informativeText = error.localizedDescription
            fail.runModal()
        }
    }

    private static func install(from bundlePath: String, downloads: String) throws {
        let dest = "/Applications/PolishPad.app"
        let fm = FileManager.default
        // 覆盖旧版：确保应用程序目录里不会新旧并存
        if fm.fileExists(atPath: dest) {
            try fm.removeItem(atPath: dest)
        }
        try runTool("/usr/bin/ditto", [bundlePath, dest])
        try? runTool("/usr/bin/xattr", ["-cr", dest])
        // 清理下载目录里的散装副本（非沙箱运行时 bundle 即源文件）
        if bundlePath.hasPrefix(downloads) {
            try? fm.trashItem(at: URL(fileURLWithPath: bundlePath),
                              resultingItemURL: nil)
        } else {
            // 转移沙箱：源在别处，顺手清掉下载目录里的同名包
            let stray = downloads + "/PolishPad.app"
            if fm.fileExists(atPath: stray) {
                try? fm.trashItem(at: URL(fileURLWithPath: stray),
                                  resultingItemURL: nil)
            }
        }
        try runTool("/usr/bin/open", ["-n", dest])
        NSApp.terminate(nil)
    }

    private static func runTool(_ path: String, _ args: [String]) throws {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "PolishPad.Installer",
                          code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                              "\(path.split(separator: "/").last ?? "tool") 失败(\(task.terminationStatus))"])
        }
    }
}
