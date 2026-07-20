import AppKit
import Foundation
import Security

// MARK: - 历史记录

struct HistoryRecord: Codable, Identifiable {
    let id: UUID
    var date: Date
    var original: String
    var versions: [String]
    var preset: String
}

/// 最近 20 次会话的持久化存储
@MainActor
final class HistoryStore {
    static let shared = HistoryStore(
        url: ConfigStore.configDirectory.appendingPathComponent("history.json"))

    private(set) var records: [HistoryRecord] = []
    private let url: URL
    private let capacity = 20

    init(url: URL) {
        self.url = url
        load()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([HistoryRecord].self, from: Data(contentsOf: url))) ?? []
    }

    /// 每轮成功后更新当前会话（新会话插到最前）
    func upsert(id: UUID, original: String, versions: [String], preset: String) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            var record = records.remove(at: index)
            record.date = Date()
            record.original = original
            record.versions = versions
            records.insert(record, at: 0)
        } else {
            records.insert(
                HistoryRecord(id: id, date: Date(), original: original,
                              versions: versions, preset: preset),
                at: 0)
        }
        if records.count > capacity {
            records.removeLast(records.count - capacity)
        }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(records) {
            try? data.write(to: url)
        }
    }
}

// MARK: - 用量统计（按月累计，UserDefaults）

enum UsageStore {
    static func monthKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return "usage-" + formatter.string(from: date)
    }

    static func record(promptTokens: Int, completionTokens: Int) {
        let defaults = UserDefaults.standard
        let key = monthKey()
        defaults.set(defaults.integer(forKey: key + "-req") + 1, forKey: key + "-req")
        defaults.set(defaults.integer(forKey: key + "-in") + promptTokens, forKey: key + "-in")
        defaults.set(defaults.integer(forKey: key + "-out") + completionTokens, forKey: key + "-out")
    }

    static func currentMonth() -> (requests: Int, prompt: Int, completion: Int) {
        let defaults = UserDefaults.standard
        let key = monthKey()
        return (defaults.integer(forKey: key + "-req"),
                defaults.integer(forKey: key + "-in"),
                defaults.integer(forKey: key + "-out"))
    }
}

// MARK: - Keychain

enum KeychainStore {
    private static let service = "PolishPad"

    static func set(_ value: String, account: String = "apiKey") {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String = "apiKey") -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String = "apiKey") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 替换还原

/// 记录最近一次原地替换，支持一键还原（信任度兜底）
@MainActor
final class ReplacementUndo {
    static let shared = ReplacementUndo()

    private(set) var pastedText: String?
    /// 被我们删掉的旧文本；nil 表示首次插入（还原 = 仅删除）
    private(set) var replacedText: String?
    private(set) var targetApp: NSRunningApplication?

    var canRestore: Bool { !(pastedText ?? "").isEmpty }

    func record(pasted: String?, replaced: String?, app: NSRunningApplication?) {
        pastedText = pasted
        replacedText = replaced
        targetApp = app
    }

    /// 激活目标应用 → 退格删除上次粘贴 → 贴回被替换的原文
    func restore() async -> Bool {
        guard let pasted = pastedText, !pasted.isEmpty else { return false }
        guard KeySimulator.ensureAccessibilityPermission() else { return false }

        // 必须确认目标应用真的回到前台，否则键击会落进无辜的前台应用
        if let app = targetApp, !app.isTerminated {
            app.activate()
            var activated = false
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == app.processIdentifier {
                    activated = true
                    break
                }
                app.activate()
            }
            guard activated else {
                HUD.shared.flashSuccess(UILang.t("目标应用未能激活，已取消还原",
                                                 "Couldn't activate the target app — restore cancelled"))
                return false
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        HUD.shared.showWorking(UILang.t("还原中…", "Restoring…"))
        await KeySimulator.postBackspaces(pasted.count)

        if let replaced = replacedText, !replaced.isEmpty {
            let snapshot = ClipboardSnapshot.capture()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(replaced, forType: .string)
            try? await Task.sleep(nanoseconds: 120_000_000)
            KeySimulator.postCommandKey(KeySimulator.keyV)
            try? await Task.sleep(nanoseconds: 600_000_000)
            snapshot.restore()
        }

        HUD.shared.flashSuccess(UILang.t("已还原", "Restored"))
        pastedText = nil
        replacedText = nil
        targetApp = nil
        return true
    }
}
