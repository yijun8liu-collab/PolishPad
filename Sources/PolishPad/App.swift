import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var quickPolish: QuickPolishController!
    private var serviceProvider: ServiceProvider!
    private var hotKeys: [GlobalHotKey] = []
    private var panelHotkeySpec = "option+space"
    private var selectionHotkeySpec = "ctrl+option+r"
    private var allHotkeySpec = "ctrl+option+a"

    func applicationDidFinishLaunching(_ notification: Notification) {
        ConfigStore.ensureConfigFileExists()
        panelController = PanelController()
        setupQuickPolish()
        setupHotKeys()
        setupStatusItem()
        setupServices()
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
        panelHotkeySpec = config?.hotkey ?? "option+space"
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

        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "打开润色窗口（\(panelHotkeySpec)）",
            action: #selector(togglePanel), keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        // 划词功能的快捷键提示（点击无效果场景多，仅作说明）
        let selectionInfo = NSMenuItem(
            title: "润色选中文本：\(selectionHotkeySpec)", action: nil, keyEquivalent: ""
        )
        selectionInfo.isEnabled = false
        menu.addItem(selectionInfo)
        let allInfo = NSMenuItem(
            title: "全选润色替换：\(allHotkeySpec)", action: nil, keyEquivalent: ""
        )
        allInfo.isEnabled = false
        menu.addItem(allInfo)

        menu.addItem(.separator())
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
        statusItem.menu = menu
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
