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

        // 走响应链到 SRAppDelegate，用自己的关于窗口而不是系统那个标准面板。
        append(to: menu, L("关于 SwiftRight"),
               #selector(SRAppDelegate.showAboutFromMenu(_:)))
        menu.addItem(.separator())

        append(to: menu, L("设置…"),
               #selector(SRAppDelegate.showSettingsFromMenu(_:)), key: ",")
        menu.addItem(.separator())

        append(to: menu, L("隐藏 SwiftRight"),
               #selector(NSApplication.hide(_:)), key: "h")
        append(to: menu, L("隐藏其他"),
               #selector(NSApplication.hideOtherApplications(_:)),
               key: "h", modifiers: [.command, .option])
        append(to: menu, L("显示全部"),
               #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())

        append(to: menu, L("退出 SwiftRight"),
               #selector(NSApplication.terminate(_:)), key: "q")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - 编辑菜单

    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: L("编辑"))

        // undo:/redo: 没有公开的 Swift selector，只能按名字取。
        append(to: menu, L("撤销"), Selector(("undo:")), key: "z")
        append(to: menu, L("重做"), Selector(("redo:")), key: "z",
               modifiers: [.command, .shift])
        menu.addItem(.separator())

        append(to: menu, L("剪切"), #selector(NSText.cut(_:)), key: "x")
        append(to: menu, L("拷贝"), #selector(NSText.copy(_:)), key: "c")
        append(to: menu, L("粘贴"), #selector(NSText.paste(_:)), key: "v")
        append(to: menu, L("删除"), #selector(NSText.delete(_:)))
        append(to: menu, L("全选"), #selector(NSText.selectAll(_:)), key: "a")

        let item = NSMenuItem(title: L("编辑"), action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: - 窗口菜单

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: L("窗口"))

        append(to: menu, L("最小化"), #selector(NSWindow.performMiniaturize(_:)), key: "m")
        append(to: menu, L("缩放"), #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        append(to: menu, L("关闭"), #selector(NSWindow.performClose(_:)), key: "w")

        let item = NSMenuItem(title: L("窗口"), action: nil, keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
