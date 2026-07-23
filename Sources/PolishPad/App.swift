import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var historyMenuItem: NSMenuItem?
    private var panelController: PanelController!
    private var quickPolish: QuickPolishController!
    private var serviceProvider: ServiceProvider!
    private var hotKeys: [GlobalHotKey] = []
    private var panelHotkeySpec = "ctrl+option+p"
    private var selectionHotkeySpec = "ctrl+option+r"
    private var allHotkeySpec = "ctrl+option+a"

    private let settingsController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ConfigStore.ensureConfigFileExists()
        ConfigStore.migrateKeyFromKeychainIfNeeded()
        setupMainMenu()
        panelController = PanelController()
        setupQuickPolish()
        setupHotKeys()
        setupStatusItem()
        setupServices()
        setupNotifications()
    }

    /// 菜单栏应用默认没有主菜单，而 ⌘V/⌘C/⌘X/⌘A/⌘Z 依赖编辑菜单的
    /// 键盘等价键派发——挂一个不可见的标准编辑菜单让它们在面板内生效
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .polishPadOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsController.show() }
        }
        // 保存设置后热重载：快捷键重新注册、菜单标题刷新，无需重启
        NotificationCenter.default.addObserver(
            forName: .polishPadSettingsSaved, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadHotKeysAndMenu() }
        }
        // 快捷键录制期间暂停全局热键，避免按到现有组合时触发功能
        NotificationCenter.default.addObserver(
            forName: .polishPadSuspendHotkeys, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hotKeys.forEach { $0.unregister() }
                self.hotKeys.removeAll()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .polishPadResumeHotkeys, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hotKeys.isEmpty else { return }
                self.setupHotKeys()
            }
        }
    }

    private func reloadHotKeysAndMenu() {
        hotKeys.forEach { $0.unregister() }
        hotKeys.removeAll()
        setupHotKeys()
        statusItem.menu = buildMenu()
    }

    private func setupQuickPolish() {
        quickPolish = QuickPolishController()
        quickPolish.onStateChange = { [weak self] state in
            switch state {
            case .idle:
                self?.setStatusIcon("wand.and.stars")
            case .working:
                self?.setStatusIcon("hourglass")
            case .success:
                self?.setStatusIcon("checkmark.circle")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self?.setStatusIcon("wand.and.stars")
                }
            }
        }
    }

    private func setupHotKeys() {
        let config = ConfigStore.loadRaw()
        panelHotkeySpec = config?.hotkey ?? "ctrl+option+p"
        selectionHotkeySpec = config?.hotkeyPolishSelection ?? "ctrl+option+r"
        allHotkeySpec = config?.hotkeyPolishAll ?? "ctrl+option+a"

        var failed: [String] = []
        registerHotKey(panelHotkeySpec, failed: &failed) { [weak self] in
            self?.panelController.toggle()
        }
        registerHotKey(selectionHotkeySpec, failed: &failed) { [weak self] in
            self?.quickPolish.trigger(.selection)
        }
        registerHotKey(allHotkeySpec, failed: &failed) { [weak self] in
            self?.quickPolish.trigger(.all)
        }

        if !failed.isEmpty {
            showAlert(
                title: "部分快捷键注册失败",
                message: "「\(failed.joined(separator: "、"))」无法注册，可能已被其他应用占用或格式不正确。\n可在配置文件中修改对应字段后重启应用。"
            )
        }
    }

    private func registerHotKey(
        _ spec: String, failed: inout [String], action: @escaping () -> Void
    ) {
        guard let parsed = GlobalHotKey.parse(spec),
              let hotKey = GlobalHotKey(keyCode: parsed.keyCode, modifiers: parsed.modifiers) else {
            failed.append(spec)
            return
        }
        hotKey.handler = action
        hotKeys.append(hotKey)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setStatusIcon("wand.and.stars")
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "打开优化窗口",
            action: #selector(togglePanel), keyEquivalent: ""
        )
        openItem.target = self
        applyHotkeyDisplay(openItem, spec: panelHotkeySpec)
        menu.addItem(openItem)

        // 点击状态栏菜单不会切走目标应用的焦点，所以这两项可以直接作用于当前应用
        let selectionItem = NSMenuItem(
            title: "优化选中文本",
            action: #selector(polishSelectionFromMenu), keyEquivalent: ""
        )
        selectionItem.target = self
        applyHotkeyDisplay(selectionItem, spec: selectionHotkeySpec)
        menu.addItem(selectionItem)
        let allItem = NSMenuItem(
            title: "全选优化替换",
            action: #selector(polishAllFromMenu), keyEquivalent: ""
        )
        allItem.target = self
        applyHotkeyDisplay(allItem, spec: allHotkeySpec)
        menu.addItem(allItem)

        menu.addItem(.separator())
        let restoreItem = NSMenuItem(
            title: "还原上次替换", action: #selector(restoreLastReplacement), keyEquivalent: ""
        )
        restoreItem.target = self
        menu.addItem(restoreItem)

        let historyItem = NSMenuItem(title: "历史", action: nil, keyEquivalent: "")
        historyItem.submenu = buildHistoryMenu()
        menu.addItem(historyItem)
        self.historyMenuItem = historyItem

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "设置…", action: #selector(openSettings), keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let configItem = NSMenuItem(
            title: "打开配置文件", action: #selector(openConfig), keyEquivalent: ""
        )
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "退出 PolishPad",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        ))
        menu.delegate = self
        return menu
    }

    /// 把 "ctrl+option+space" 这类热键串转成菜单项右侧的原生快捷键显示（⌃⌥Space）
    private func applyHotkeyDisplay(_ item: NSMenuItem, spec: String) {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last, parts.count > 1 else { return }
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.command)
            case "option", "opt", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        let key: String
        switch keyName {
        case "space": key = " "
        case "return": key = "\r"
        case "tab": key = "\t"
        case "delete": key = "\u{8}"
        case "left": key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "up": key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default:
            if keyName.count == 1 {
                key = keyName
            } else if keyName.hasPrefix("f"), let n = Int(keyName.dropFirst()),
                      (1...12).contains(n),
                      let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                key = String(scalar)
            } else {
                return // 认不出的键名：不显示快捷键，标题保持干净
            }
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = flags
    }

    /// 历史子菜单：每条会话展开各版本，点击复制
    private func buildHistoryMenu() -> NSMenu {
        let menu = NSMenu()
        let records = HistoryStore.shared.records
        if records.isEmpty {
            let empty = NSMenuItem(title: "暂无记录", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        for record in records {
            let preview = record.original
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(18)
            let entry = NSMenuItem(
                title: "\(formatter.string(from: record.date)) · \(preview)…（v\(record.versions.count)）",
                action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (index, text) in record.versions.enumerated().reversed() {
                let item = NSMenuItem(
                    title: index == record.versions.count - 1
                        ? "复制 v\(index + 1)（最新）" : "复制 v\(index + 1)",
                    action: #selector(copyHistoryText(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = text
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let originalItem = NSMenuItem(
                title: "复制原文", action: #selector(copyHistoryText(_:)), keyEquivalent: "")
            originalItem.target = self
            originalItem.representedObject = record.original
            sub.addItem(originalItem)
            entry.submenu = sub
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func copyHistoryText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        HUD.shared.flashSuccess(UILang.t("已复制", "Copied"))
    }

    @objc private func restoreLastReplacement() {
        Task { @MainActor in
            let restored = await ReplacementUndo.shared.restore()
            if !restored {
                HUD.shared.flashSuccess(UILang.t("没有可还原的替换", "Nothing to restore"))
            }
        }
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    /// 注册系统「服务」（右键 → 服务 → PolishPad：…）
    private func setupServices() {
        serviceProvider = ServiceProvider(quickPolish: quickPolish)
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }

    private func setStatusIcon(_ symbolName: String) {
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "PolishPad"
        )
    }

    /// 每次打开菜单时刷新历史子菜单
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            guard menu === statusItem.menu else { return }
            historyMenuItem?.submenu = buildHistoryMenu()
        }
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    /// 等菜单完全收起后再模拟按键，避免事件落到菜单上
    @objc private func polishSelectionFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.quickPolish.trigger(.selection)
        }
    }

    @objc private func polishAllFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.quickPolish.trigger(.all)
        }
    }

    @objc private func openConfig() {
        ConfigStore.ensureConfigFileExists()
        NSWorkspace.shared.open(ConfigStore.configURL)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

@main
struct PolishPadMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(Int32(SelfTest.run()))
        }
        // 开机自启动的命令行开关（验证/脚本用）
        if CommandLine.arguments.contains("--login-status") {
            print("login item status: \(SMAppService.mainApp.status.rawValue) (1=enabled)")
            exit(0)
        }
        if CommandLine.arguments.contains("--login-enable") {
            do { try SMAppService.mainApp.register(); print("enabled") } catch { print("failed: \(error)") }
            exit(0)
        }
        if CommandLine.arguments.contains("--login-disable") {
            do { try SMAppService.mainApp.unregister(); print("disabled") } catch { print("failed: \(error)") }
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
