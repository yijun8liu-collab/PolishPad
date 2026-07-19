import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var hotKey: GlobalHotKey?
    private var hotkeyDescription = "option+space"

    func applicationDidFinishLaunching(_ notification: Notification) {
        ConfigStore.ensureConfigFileExists()
        panelController = PanelController()
        setupHotKey()
        setupStatusItem()
    }

    private func setupHotKey() {
        let spec = ConfigStore.loadRaw()?.hotkey ?? "option+space"
        hotkeyDescription = spec

        guard let parsed = GlobalHotKey.parse(spec),
              let hotKey = GlobalHotKey(keyCode: parsed.keyCode, modifiers: parsed.modifiers) else {
            showAlert(
                title: "快捷键注册失败",
                message: "「\(spec)」无法注册，可能已被其他应用占用或格式不正确。\n可在配置文件中修改 hotkey 后重启应用，也可以通过菜单栏图标打开窗口。"
            )
            return
        }
        hotKey.handler = { [weak self] in
            self?.panelController.toggle()
        }
        self.hotKey = hotKey
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "wand.and.stars",
                accessibilityDescription: "PolishPad"
            )
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "打开润色窗口（\(hotkeyDescription)）",
            action: #selector(togglePanel), keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

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
