import AppKit

/// 应用内一键更新：下载 Release 的 zip → 校验版本 → 去隔离 →
/// 原地替换 app 包 → 自动重启到新版。全程无需用户碰浏览器/访达。
@MainActor
enum SelfUpdater {
    enum UpdateError: LocalizedError {
        case translocated
        case notWritable
        case badArchive
        case versionMismatch(found: String)

        var errorDescription: String? {
            switch self {
            case .translocated:
                return UILang.t("应用处于系统隔离运行状态，无法原地更新——请从下载页手动替换",
                                "App is running translocated — please update manually from the release page")
            case .notWritable:
                return UILang.t("应用所在目录不可写，无法原地更新——请从下载页手动替换",
                                "App folder is not writable — please update manually from the release page")
            case .badArchive:
                return UILang.t("更新包解压失败或不完整",
                                "Downloaded archive is invalid")
            case .versionMismatch(let found):
                return UILang.t("更新包版本校验失败（包内为 \(found)）",
                                "Version check failed (archive contains \(found))")
            }
        }
    }

    struct LatestRelease {
        let version: String
        let zipURL: URL?
        let pageURL: String
    }

    /// 查询 GitHub 最新 Release（设置界面与测试钩子共用）
    static func fetchLatest() async throws -> LatestRelease {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Release: Decodable {
            let tag_name: String
            let html_url: String
            let assets: [Asset]
        }
        var request = URLRequest(url: URL(
            string: "https://api.github.com/repos/yijun8liu-collab/PolishPad/releases/latest")!)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.hasPrefix("v")
            ? String(release.tag_name.dropFirst()) : release.tag_name
        let zip = release.assets.first { $0.name.hasSuffix(".zip") }
            .flatMap { URL(string: $0.browser_download_url) }
        return LatestRelease(version: version, zipURL: zip, pageURL: release.html_url)
    }

    /// 隐藏测试钩子：--test-selfupdate 启动时直接跑完整更新管线，
    /// 阶段与结果打到 stdout（端到端回归用）
    static func testRun(currentVersion: String) async {
        print("[selfupdate-test] current=\(currentVersion)")
        do {
            let latest = try await fetchLatest()
            print("[selfupdate-test] latest=\(latest.version) zip=\(latest.zipURL?.absoluteString ?? "nil")")
            guard SettingsView.isVersion(latest.version, newerThan: currentVersion),
                  let zip = latest.zipURL else {
                print("[selfupdate-test] no update applicable")
                return
            }
            try await downloadAndInstall(zipURL: zip, expectedVersion: latest.version) {
                print("[selfupdate-test] stage: \($0)")
            }
        } catch {
            print("[selfupdate-test] FAILED: \(error.localizedDescription)")
        }
    }

    /// 下载并安装；progress 回调阶段性文案。成功后调用方无需做任何事——
    /// 本进程会启动新版并退出
    static func downloadAndInstall(
        zipURL: URL,
        expectedVersion: String,
        progress: @escaping (String) -> Void
    ) async throws {
        let bundleURL = Bundle.main.bundleURL

        // 前置检查：Translocation 下 bundlePath 是只读镜像，替换了也没意义
        guard !bundleURL.path.contains("/AppTranslocation/") else {
            throw UpdateError.translocated
        }
        guard FileManager.default.isWritableFile(
            atPath: bundleURL.deletingLastPathComponent().path) else {
            throw UpdateError.notWritable
        }

        // 1. 下载
        progress(UILang.t("下载中…", "Downloading…"))
        let (tmpZip, _) = try await URLSession.shared.download(from: zipURL)

        // 2. 解压到独立临时目录
        progress(UILang.t("解压中…", "Unpacking…"))
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polishpad-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true)
        try runTool("/usr/bin/ditto", ["-xk", tmpZip.path, workDir.path])
        guard let newApp = try FileManager.default
            .contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.badArchive
        }

        // 3. 校验：包内版本必须等于宣称的新版本，且可执行文件存在
        progress(UILang.t("校验中…", "Verifying…"))
        let plist = newApp.appendingPathComponent("Contents/Info.plist")
        let info = NSDictionary(contentsOf: plist)
        let found = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        guard found == expectedVersion,
              FileManager.default.fileExists(
                  atPath: newApp.appendingPathComponent("Contents/MacOS/PolishPad").path)
        else {
            throw UpdateError.versionMismatch(found: found)
        }

        // 4. 去隔离：不清除的话替换后 Gatekeeper 会再拦一次
        try? runTool("/usr/bin/xattr", ["-cr", newApp.path])

        // 5. 原地替换：旧包先挪到同目录的备份名（同卷原子操作），
        //    新包移入原位置；替换运行中的 app 是 macOS 允许的
        progress(UILang.t("安装中…", "Installing…"))
        let backup = bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".PolishPad-old-\(ProcessInfo.processInfo.processIdentifier).app")
        try FileManager.default.moveItem(at: bundleURL, to: backup)
        do {
            try FileManager.default.moveItem(at: newApp, to: bundleURL)
        } catch {
            // 回滚：新包放不进去就把旧包挪回来
            try? FileManager.default.moveItem(at: backup, to: bundleURL)
            throw error
        }
        try? FileManager.default.trashItem(at: backup, resultingItemURL: nil)
        try? FileManager.default.removeItem(at: workDir)

        // 6. 重启到新版
        progress(UILang.t("重启中…", "Relaunching…"))
        try runTool("/usr/bin/open", ["-n", bundleURL.path])
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSApp.terminate(nil)
    }

    private static func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.badArchive
        }
    }
}
