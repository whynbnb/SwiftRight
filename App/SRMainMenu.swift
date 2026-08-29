import AppKit

/// 手工搭主菜单。
///
/// 走的是纯 AppKit 的 `NSApp.run()` 入口，没有 MainMenu.nib，
/// 不建这套菜单的话 ⌘Q / ⌘C / ⌘V / ⌘Z 全都不会响应。
enum SRMainMenu {

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenuItem())
        main.addItem(editMenuItem())
        main.addItem(windowMenuItem())
        return main
    }

    /// AppKit 的 `addItem(withTitle:…)` 返回值不是 @discardableResult，
    /// 直接调用会一路报 "result unused"，所以统一走这里。
    @discardableResult
    private static func append(to menu: NSMenu,
                               _ title: String,
                               _ action: Selector?,
                               key: String = "",
                               modifiers: NSEvent.ModifierFlags? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if let modifiers { item.keyEquivalentModifierMask = modifiers }
        menu.addItem(item)
        return item
    }

    // MARK: - 应用菜单

    private static func appMenuItem() -> NSMenuItem {
        let name = "SwiftRight"
        let menu = NSMenu(title: name)

        append(to: menu, "关于 \(name)",
               #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())

        append(to: menu, "隐藏 \(name)",
               #selector(NSApplication.hide(_:)), key: "h")
        append(to: menu, "隐藏其他",
               #selector(NSApplication.hideOtherApplications(_:)),
               key: "h", modifiers: [.command, .option])
        append(to: menu, "显示全部",
               #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())

        append(to: menu, "退出 \(name)",
               #selector(NSApplication.terminate(_:)), key: "q")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - 编辑菜单

    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "编辑")

        // undo:/redo: 没有公开的 Swift selector，只能按名字取。
        append(to: menu, "撤销", Selector(("undo:")), key: "z")
        append(to: menu, "重做", Selector(("redo:")), key: "z",
               modifiers: [.command, .shift])
        menu.addItem(.separator())

        append(to: menu, "剪切", #selector(NSText.cut(_:)), key: "x")
        append(to: menu, "拷贝", #selector(NSText.copy(_:)), key: "c")
        append(to: menu, "粘贴", #selector(NSText.paste(_:)), key: "v")
        append(to: menu, "删除", #selector(NSText.delete(_:)))
        append(to: menu, "全选", #selector(NSText.selectAll(_:)), key: "a")

        let item = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: - 窗口菜单

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "窗口")

        append(to: menu, "最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        append(to: menu, "缩放", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        append(to: menu, "关闭", #selector(NSWindow.performClose(_:)), key: "w")

        let item = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
