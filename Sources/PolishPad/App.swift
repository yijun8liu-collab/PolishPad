import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
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
            title: "打开润色窗口（\(panelHotkeySpec)）",
            action: #selector(togglePanel), keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        // 点击状态栏菜单不会切走目标应用的焦点，所以这两项可以直接作用于当前应用
        let selectionItem = NSMenuItem(
            title: "润色选中文本（\(selectionHotkeySpec)）",
            action: #selector(polishSelectionFromMenu), keyEquivalent: ""
        )
        selectionItem.target = self
        menu.addItem(selectionItem)
        let allItem = NSMenuItem(
            title: "全选润色替换（\(allHotkeySpec)）",
            action: #selector(polishAllFromMenu), keyEquivalent: ""
        )
        allItem.target = self
        menu.addItem(allItem)

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
        return menu
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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
