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

    private override init() {
        super.init()
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
            content: RootView().environmentObject(SRAppModel.shared)
        )
        window.setFrameAutosaveName("SwiftRightManagerWindow")
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
            title: "运行输出",
            size: NSSize(width: 720, height: 480),
            minSize: NSSize(width: 480, height: 300),
            content: OutputWindowView().environmentObject(SRCommandRunner.shared)
        )
        window.setFrameAutosaveName("SwiftRightOutputWindow")
        outputWindow = window
        present(window)
    }

    // MARK: - 构造

    private func makeWindow<Content: View>(title: String,
                                           size: NSSize,
                                           minSize: NSSize,
                                           content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = false
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.delegate = self
        window.center()
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
        let hasVisibleWindow = [managerWindow, outputWindow]
            .compactMap { $0 }
            .contains { $0.isVisible }
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
