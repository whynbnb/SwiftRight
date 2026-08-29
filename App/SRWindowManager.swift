import AppKit
import SwiftUI

/// 用 AppKit 直接管窗口。
///
/// SwiftRight 平时是 `.accessory` 的（不占 Dock、不抢焦点），
/// 而 `.accessory` 状态下没有菜单栏，脚本编辑框里的 ⌘C/⌘V/⌘Z 就会失效。
/// 所以策略是：只要还有可见窗口就切 `.regular`，全关掉再切回 `.accessory`。
final class SRWindowManager: NSObject, NSWindowDelegate {

    static let shared = SRWindowManager()

    private var managerWindow: NSWindow?
    private var outputWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private override init() {
        super.init()
    }

    private var allWindows: [NSWindow] {
        [managerWindow, outputWindow, settingsWindow].compactMap { $0 }
    }

    // MARK: - 主窗口

    func showManager() {
        if let managerWindow {
            present(managerWindow)
            return
        }

        let window = makeWindow(
            title: "SwiftRight",
            size: NSSize(width: 940, height: 620),
            minSize: NSSize(width: 760, height: 460),
            autosaveName: "SwiftRightManagerWindow"
        ) {
            SRLocalizedRoot {
                RootView().environmentObject(SRAppModel.shared)
            }
        }
        managerWindow = window
        present(window)
    }

    // MARK: - 输出窗口

    func showOutput() {
        if let outputWindow {
            present(outputWindow)
            return
        }

        let window = makeWindow(
            title: L("运行输出"),
            size: NSSize(width: 720, height: 480),
            minSize: NSSize(width: 480, height: 300),
            autosaveName: "SwiftRightOutputWindow"
        ) {
            SRLocalizedRoot {
                OutputWindowView().environmentObject(SRCommandRunner.shared)
            }
        }
        outputWindow = window
        present(window)
    }

    // MARK: - 设置窗口

    func showSettings() {
        if let settingsWindow {
            present(settingsWindow)
            return
        }

        // 设置窗口内容是固定尺寸的 TabView，不给缩放。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("设置")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SRLocalizedRoot {
            SRSettingsView()
                .environmentObject(SRAppModel.shared)
        })
        window.center()
        settingsWindow = window
        present(window)
    }

    // MARK: - 语言切换

    /// 窗口标题是 AppKit 属性，不在 SwiftUI 的重建范围里，得手动刷。
    func refreshWindowTitles() {
        managerWindow?.title = "SwiftRight"
        outputWindow?.title = L("运行输出")
        settingsWindow?.title = L("设置")
    }

    // MARK: - 构造

    private func makeWindow<Content: View>(title: String,
                                           size: NSSize,
                                           minSize: NSSize,
                                           autosaveName: String,
                                           @ViewBuilder content: () -> Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.delegate = self
        window.center()
        window.setFrameAutosaveName(autosaveName)
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 关窗动作走完之后 isVisible 才更新，所以推到下一个 runloop 再判断。
        DispatchQueue.main.async { [weak self] in
            self?.syncActivationPolicy()
        }
    }

    private func syncActivationPolicy() {
        if !allWindows.contains(where: { $0.isVisible }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
