import AppKit
import Combine
import SwiftUI

@main
enum SwiftRightMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = SRAppDelegate()
        // NSApplication 只持有弱引用，这里必须自己留一份。
        SRAppDelegate.retained = delegate
        app.delegate = delegate
        app.run()
    }
}

final class SRAppDelegate: NSObject, NSApplicationDelegate {

    static var retained: SRAppDelegate?

    private var statusItem: NSStatusItem?
    /// 冷启动时是不是因为点了右键菜单才被拉起来的。
    private var launchedForTicket = false
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 启动

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 默认不占 Dock、不抢焦点；有窗口时 SRWindowManager 会临时切回 .regular。
        NSApp.setActivationPolicy(.accessory)
        SRPreferences.shared.applyTheme()
        NSApp.mainMenu = SRMainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SRPaths.ensureDirectories()
        SRTicket.pruneStale()
        _ = SRAppModel.shared
        // 提前建好终端清单。等到用户点「在终端中运行」才扫，
        // 第一次会白等一下；启动时扫完，设置页打开也是即时的。
        _ = SRTerminalCatalog.shared
        installStatusItem()
        observeLanguageChanges()

        // URL 事件到底在 didFinishLaunching 之前还是之后送达，各系统版本并不一致。
        // 稍等一拍再判断：如果这次启动是为了执行命令，就别把主窗口弹出来。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.launchedForTicket else { return }
            SRWindowManager.shared.showManager()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SRWindowManager.shared.showManager()
        return true
    }

    // MARK: - 语言

    /// 主菜单、菜单栏菜单、窗口标题都是命令式搭出来的，
    /// SwiftUI 那套 `.id()` 重建管不到它们，只能收到通知后自己重来一遍。
    private func observeLanguageChanges() {
        SRPreferences.shared.languageDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                NSApp.mainMenu = SRMainMenu.build()
                self?.rebuildStatusMenu()
                SRWindowManager.shared.refreshWindowTitles()
            }
            .store(in: &cancellables)
    }

    // MARK: - 扩展回调

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handle(url)
        }
    }

    private func handle(_ url: URL) {
        guard url.scheme == SRPaths.urlScheme, url.host == "run" else { return }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let raw = components.queryItems?.first(where: { $0.name == "ticket" })?.value,
            let ticketID = UUID(uuidString: raw),
            let ticket = SRTicket.consume(id: ticketID)
        else { return }

        launchedForTicket = true

        // 直接读盘而不是用内存里的 model：用户可能刚在别处改过配置。
        SRConfigStore.shared.invalidate()
        let config = SRConfigStore.shared.load()
        guard let command = config.commands.first(where: { $0.id == ticket.commandID }) else {
            NSLog("[SwiftRight] 找不到命令 \(ticket.commandID)")
            return
        }

        SRCommandRunner.shared.run(command: command,
                                   paths: ticket.paths,
                                   targetPath: ticket.targetPath) {
            SRWindowManager.shared.showOutput()
        }
    }

    // MARK: - 菜单栏

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bolt.circle",
                                     accessibilityDescription: "SwiftRight")
        item.button?.image?.isTemplate = true
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "") {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
        }

        add(L("管理命令…"), #selector(showManager))
        add(L("运行输出…"), #selector(showOutput))
        menu.addItem(.separator())
        add(L("设置…"), #selector(showSettings), key: ",")
        menu.addItem(.separator())
        add(L("重新载入配置"), #selector(reloadConfig))
        add(L("重启访达"), #selector(relaunchFinder))
        menu.addItem(.separator())
        add(L("退出 SwiftRight"), #selector(quit), key: "q")

        statusItem?.menu = menu
    }

    @objc private func showManager() { SRWindowManager.shared.showManager() }
    @objc private func showOutput() { SRWindowManager.shared.showOutput() }
    @objc private func showSettings() { SRWindowManager.shared.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// 主菜单里的「设置…」把 target 留空，靠响应链走到这里，
    /// 所以这个方法不能是 private，签名也得带 sender。
    @objc func showSettingsFromMenu(_ sender: Any?) {
        SRWindowManager.shared.showSettings()
    }

    @objc private func reloadConfig() {
        SRAppModel.shared.load()
        SRAppModel.shared.refreshExtensionStatus()
    }

    @objc private func relaunchFinder() {
        SRAppModel.shared.relaunchFinder()
    }
}
