import AppKit
import SwiftUI

/// 用 AppKit 直接管窗口。
///
/// SwiftRight 平时是 `.accessory` 的（不占 Dock、不抢焦点），
/// 而 `.accessory` 状态下没有菜单栏，脚本编辑框里的 ⌘C/⌘V/⌘Z 就会失效。
/// 所以策略是：只要还有可见窗口就切 `.regular`，全关掉再切回 `.accessory`。
@MainActor
final class SRWindowManager: NSObject, NSWindowDelegate {

    static let shared = SRWindowManager()

    private var managerWindow: NSWindow?
    private var outputWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var sortWindow: NSWindow?
    private var aboutWindow: NSWindow?

    private override init() {
        super.init()
    }

    private var allWindows: [NSWindow] {
        [managerWindow, outputWindow, settingsWindow, sortWindow, aboutWindow].compactMap { $0 }
    }

    /// 还有窗口开着吗。「用完自动退出」要靠它判断能不能退。
    var hasVisibleWindow: Bool {
        allWindows.contains { $0.isVisible }
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

        // fullSizeContentView + 透明标题栏：内容区一直铺到窗口顶端，
        // 侧栏因此是通体到顶的，红绿灯直接浮在侧栏材质上 ——
        // 这是访达、系统设置那种统一侧栏的做法。
        // 保留标准标题栏的话，侧栏只能从标题栏下面开始，顶上会多出一条 header。
        //
        // 注意 fullSizeContentView 下 contentRect 就是整窗尺寸（不像标准
        // 标题栏那样再加 32pt），所以这里给的 820×560 即窗口最终大小。
        //
        // 可以自由缩放：内容页都有自己的滚动，侧栏固定 172pt。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = L("设置")
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 最小尺寸要够放下侧栏和一行说明文字；最大不限。
        window.contentMinSize = NSSize(width: 600, height: 400)
        window.contentView = NSHostingView(rootView: SRLocalizedRoot {
            SRSettingsView()
                .environmentObject(SRAppModel.shared)
        })
        window.center()
        settingsWindow = window
        present(window)
    }

    // MARK: - 排序

    func showSort() {
        if let sortWindow {
            present(sortWindow)
            return
        }

        // 排序窗口用标准标题栏：fullSizeContentView + 透明标题栏会让
        // 后面的主窗口透出来，在顶部留下奇怪的竖线。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("排序")
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SRLocalizedRoot {
            SRSortView().environmentObject(SRAppModel.shared)
        })
        window.center()
        window.setFrameAutosaveName("SwiftRightSortWindow")
        sortWindow = window
        present(window)
    }

    // MARK: - 关于

    func showAbout() {
        if let aboutWindow {
            present(aboutWindow)
            return
        }

        // 内容是固定尺寸的，高度让 SwiftUI 自己撑，所以不给缩放也不给最小化。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("关于 SwiftRight")
        window.isReleasedWhenClosed = false
        window.delegate = self

        let hosting = NSHostingView(rootView: SRLocalizedRoot { SRAboutView() })
        window.contentView = hosting
        // 按内容的实际高度收一下窗口，免得底部留一条空白。
        window.setContentSize(hosting.fittingSize)
        window.center()

        aboutWindow = window
        present(window)
    }

    // MARK: - 语言切换

    /// 窗口标题是 AppKit 属性，不在 SwiftUI 的重建范围里，得手动刷。
    func refreshWindowTitles() {
        managerWindow?.title = "SwiftRight"
        outputWindow?.title = L("运行输出")
        settingsWindow?.title = L("设置")
        sortWindow?.title = L("排序")
        aboutWindow?.title = L("关于 SwiftRight")
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
        // fullSizeContentView 下让标题栏透明，内容才能通体到顶；
        // 不透明标题栏在折叠侧栏后会留一块和内容宽度不一致的矩形。
        window.titlebarAppearsTransparent = true
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
            // 窗口全关了可能就该退出了，交给「用完自动退出」那套判断。
            SRAppDelegate.retained?.scheduleIdleQuitCheck()
        }
    }

    private func syncActivationPolicy() {
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - 破坏性操作确认

/// 删除这类不可撤销的操作统一走原生确认框，避免误触。
@MainActor
enum SRConfirm {

    /// 返回 true 表示用户点了确认。
    @discardableResult
    static func confirmDestructive(message: String,
                                   informative: String,
                                   confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L("取消"))
        // 确认按钮按系统规范渲染成红色，和菜单里的删除操作保持一致。
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}
