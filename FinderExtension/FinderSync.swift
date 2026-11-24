import AppKit
import FinderSync

/// Finder 右键菜单扩展。
///
/// 这里刻意保持"薄"：只负责读配置、拼菜单、把点击事件转成一张凭据丢给主 App。
/// 真正执行命令必须放在非沙盒的主 App 里 —— app extension 强制沙盒，
/// 在扩展里 `Process` 起任何外部程序都会被拒绝。
/// 访达扩展的入口。回调（`menu(for:)`、菜单点击、卷挂载通知）都由系统
/// 在主线程投递，内部状态也只在那里改；这里显式声明共享安全，避免
/// Swift 6 把闭包捕获当成跨线程传递。
final class FinderSync: FIFinderSync, @unchecked Sendable {

    /// tag → 命令 ID。NSMenuItem 跨进程代理到 Finder 时只有少数属性能存活，
    /// `representedObject` 不在其中，所以用 Int tag 做索引。
    private var tagToCommandID: [Int: UUID] = [:]

    override init() {
        super.init()
        SRPaths.ensureDirectories()
        refreshMonitoredDirectories()

        // 插拔外置硬盘 / 挂载网络卷之后要把新卷加进监视范围，否则那些卷上没有菜单。
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self,
                       selector: #selector(volumesChanged),
                       name: NSWorkspace.didMountNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(volumesChanged),
                       name: NSWorkspace.didUnmountNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(volumesChanged),
                       name: NSWorkspace.didRenameVolumeNotification,
                       object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - 监视范围

    @objc private func volumesChanged(_ note: Notification) {
        refreshMonitoredDirectories()
    }

    /// FIFinderSync 只在 `directoryURLs` 覆盖的范围内提供菜单。
    /// 想让菜单"到处都有"，就得把根目录和所有已挂载的卷都放进去。
    private func refreshMonitoredDirectories() {
        var urls: Set<URL> = [URL(fileURLWithPath: "/", isDirectory: true)]
        if let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) {
            urls.formUnion(volumes)
        }
        FIFinderSyncController.default().directoryURLs = urls
    }

    // MARK: - 菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // 未知的菜单类型不掺和，交回给系统。
        switch menuKind {
        case .contextualMenuForItems, .contextualMenuForContainer,
             .contextualMenuForSidebar, .toolbarItemMenu:
            break
        @unknown default:
            return nil
        }

        let config = SRConfigStore.shared.load()
        let isContainer = (menuKind == .contextualMenuForContainer)
        let selection = currentSelection(isContainerMenu: isContainer)
        guard !selection.isEmpty else { return nil }

        var candidates: [SRCommand] = config.commands.filter { command in
            command.matches(paths: selection, isContainerMenu: isContainer)
        }
        candidates.sort { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        guard !candidates.isEmpty else { return nil }

        tagToCommandID.removeAll()
        var nextTag = 1

        // 未分组命令放最前面；分组按 settings.groupOrder 排，
        // 没列进去的分组按首次出现顺序补在后面。
        let ungrouped = candidates.filter {
            $0.group.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let groupNames = config.settings.orderedGroups(for: candidates)

        let menu = NSMenu(title: config.settings.menuTitle)

        // 每个分组自己决定要不要收进共用的二级菜单：勾选的分组放进
        // 「菜单名称」那一项里，其余分组直接挂在右键菜单顶层。
        for command in ungrouped {
            menu.addItem(makeItem(for: command, tag: &nextTag, settings: config.settings))
        }

        var submenuItems: [NSMenuItem] = []
        for group in groupNames {
            // 分组自己的启用开关：关掉后整组都不出现。
            guard !config.settings.isGroupHidden(group) else { continue }

            let commands = candidates.filter {
                $0.group.trimmingCharacters(in: .whitespaces) == group
            }
            guard !commands.isEmpty else { continue }

            let submenu = NSMenu(title: group)
            for command in commands {
                submenu.addItem(makeItem(for: command, tag: &nextTag, settings: config.settings))
            }
            let holder = NSMenuItem(title: group, action: nil, keyEquivalent: "")
            holder.submenu = submenu
            if config.settings.showIcons {
                holder.image = symbolImage(config.settings.symbol(for: group))
            }

            if config.settings.isInSubmenu(group) {
                submenuItems.append(holder)
            } else {
                menu.addItem(holder)
            }
        }

        if !submenuItems.isEmpty {
            let submenu = NSMenu(title: config.settings.menuTitle)
            for item in submenuItems { submenu.addItem(item) }
            let root = NSMenuItem(title: config.settings.menuTitle, action: nil, keyEquivalent: "")
            root.submenu = submenu
            if config.settings.showIcons {
                root.image = symbolImage(config.settings.menuSymbol)
            }
            menu.addItem(root)
        }

        // 全部分组都被关掉、又没有未分组命令时，别留一个空菜单。
        return menu.items.isEmpty ? nil : menu
    }

    private func makeItem(for command: SRCommand, tag: inout Int, settings: SRSettings) -> NSMenuItem {
        let item = NSMenuItem(title: command.title,
                              action: #selector(runCommand(_:)),
                              keyEquivalent: "")
        item.target = self
        item.tag = tag
        tagToCommandID[tag] = command.id
        tag += 1

        if settings.showIcons, !command.symbol.isEmpty {
            item.image = symbolImage(command.symbol)
        }
        return item
    }

    /// 图标画布的逻辑尺寸。访达的菜单图标槽是 16×16pt，画布必须和它一致：
    /// 交给访达的图会被整体缩放进这个槽，20×16 的画布会被横向压扁到 16 宽，
    /// 图标看起来就又小又扁。
    private static let iconBox = NSSize(width: 16, height: 16)
    /// 符号本身的目标高度。等于画布高度，铺满图标槽。
    private static let iconGlyphHeight: CGFloat = 16
    private static let iconPointSize: CGFloat = 14

    /// 渲染好的图标缓存。`menu(for:)` 每次右键都会跑一遍，
    /// 十几个菜单项每次都重新画位图是白费。
    ///
    /// 键里带上明暗外观：颜色是直接烘进像素的（见下），
    /// 系统切换深浅色之后必须重新画一份。
    private var iconCache: [String: NSImage] = [:]

    /// 当前是不是深色外观。
    ///
    /// 注意：访达是在自己的 XPC 队列上调用 `menu(for:)` 的，不是主线程，
    /// 所以这里不能碰 `NSApp` / `NSAppearance`（Swift 6 的主线程断言会直接
    /// 触发 SIGTRAP，扩展就崩了，右键菜单也就不出现）。改读系统偏好里的
    /// `AppleInterfaceStyle` —— 访达菜单跟随的正是这个开关。
    private static func prefersDarkAppearance() -> Bool {
        UserDefaults.standard
            .string(forKey: "AppleInterfaceStyle")?
            .caseInsensitiveCompare("Dark") == .orderedSame
    }

    /// 把 SF Symbol 渲染成菜单图标。
    ///
    /// 有两个访达特有的坑：
    ///
    /// 其一，**Finder Sync 不认 `isTemplate`**。菜单项图片跨进程交给访达后
    /// 会按原样绘制，不会像普通 App 的菜单那样自动染成黑/白。所以颜色必须
    /// 自己按当前外观烘进像素，并显式设 `isTemplate = false`。
    ///
    /// 其二，符号的原始尺寸各不相同，访达会把整张图缩放进 16×16 的图标槽。
    /// 画布不是 16×16 就会被非等比缩放。这里固定 16×16 画布，符号按比例
    /// 缩放、居中，绝不拉伸 —— 非正方形符号（`textformat.abc`、`</>`）
    /// 塞满方框会明显变形。
    ///
    /// 另外按 2x 出位图：位图跨 XPC 无损，Retina 上一个逻辑点对应两个
    /// 物理像素，访达那边不需要二次缩放，边缘不发虚。
    private func symbolImage(_ name: String) -> NSImage? {
        let isDark = Self.prefersDarkAppearance()
        let cacheKey = "\(name)|\(isDark ? "dark" : "light")"
        if let cached = iconCache[cacheKey] { return cached }

        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize,
                                                        weight: .regular)
        let configured = symbol.withSymbolConfiguration(configuration) ?? symbol

        let natural = configured.size
        guard natural.width > 0, natural.height > 0 else { return nil }

        let box = Self.iconBox
        // 等比缩放到 16×16 里：先按高度归一，特别宽的符号再由画布宽度兜底。
        let ratio = min(Self.iconGlyphHeight / natural.height, box.width / natural.width)
        let drawn = NSSize(width: natural.width * ratio, height: natural.height * ratio)
        let origin = NSPoint(x: ((box.width - drawn.width) / 2).rounded(),
                             y: ((box.height - drawn.height) / 2).rounded())

        // 像素尺寸取逻辑尺寸的 2 倍，rep.size 仍报逻辑尺寸，
        // 于是它就是一张 2x 图，Retina 上一个逻辑点对两个物理像素，不再二次缩放。
        let scale = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(box.width) * scale,
            pixelsHigh: Int(box.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = box

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        configured.draw(in: NSRect(origin: origin, size: drawn),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1)
        // SF Symbol 自带内部颜色，直接改填充色没用。用 sourceIn 只保留
        // 符号的 alpha，把目标颜色填进去，相当于给已经画好的符号上色。
        (isDark ? NSColor.white : NSColor.black).setFill()
        NSRect(origin: .zero, size: box).fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: box)
        image.addRepresentation(rep)
        // Finder Sync 不认模板图，颜色已经烘进像素，必须关掉。
        image.isTemplate = false

        iconCache[cacheKey] = image
        return image
    }

    // MARK: - 点击

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let commandID = tagToCommandID[sender.tag] else { return }

        let controller = FIFinderSyncController.default()
        let target = controller.targetedURL()
        let selected = controller.selectedItemURLs() ?? []
        let isContainer = selected.isEmpty

        var paths = selected.map(\.path)
        if paths.isEmpty, let target {
            paths = [target.path]
        }
        guard !paths.isEmpty else { return }

        let ticket = SRTicket(commandID: commandID,
                              paths: paths,
                              targetPath: target?.path,
                              isContainerMenu: isContainer)

        do {
            let url = try SRTicket.write(ticket)
            Self.deliver(url) { [weak self] delivered in
                guard !delivered else { return }
                // URL scheme 还没被 LaunchServices 认到。
                self?.launchHostApp(thenRetry: ticket)
            }
        } catch {
            // 多半是 ~/Library/Application Support/SwiftRight/ 还不存在：
            // 沙盒例外只覆盖这个目录本身，建不了它的父目录，得靠 App 首次启动来创建。
            NSLog("[SwiftRight] 写入调用凭据失败，尝试拉起宿主 App: \(error.localizedDescription)")
            launchHostApp(thenRetry: ticket)
        }
    }

    /// 把凭据投递给主 App。
    ///
    /// 关键是 `activates = false`。单参数的 `NSWorkspace.open(url)` 内部固定
    /// 会把目标 App 激活到前台 —— 那是 LaunchServices 打开 URL 的默认行为，
    /// 和双击文件把对应 App 拉到前台是同一套逻辑，没有余地可调。
    ///
    /// 但 SwiftRight 在这里只是收凭据、在后台跑命令，被拉到前台纯属副作用：
    /// 主窗口开着时会看到它抢一下焦点再让给 VS Code，没开窗口时 accessory
    /// 状态的它也会顶掉菜单栏。真正该拿到前台的是命令自己拉起来的那些 App。
    private static func deliver(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            Task { @MainActor in completion(error == nil) }
        }
    }

    /// 兜底路径：直接按路径启动同 bundle 里的宿主 App，
    /// 等它注册好 URL scheme、建好目录之后，重投一次凭据。
    private func launchHostApp(thenRetry ticket: SRTicket) {
        // .../SwiftRight.app/Contents/PlugIns/FinderExtension.appex
        let hostApp = Bundle.main.bundleURL
            .deletingLastPathComponent()   // PlugIns
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // SwiftRight.app

        guard hostApp.pathExtension == "app" else {
            NSLog("[SwiftRight] 找不到宿主 App：\(hostApp.path)")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: hostApp, configuration: configuration) { _, error in
            if let error {
                NSLog("[SwiftRight] 启动宿主 App 失败: \(error.localizedDescription)")
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                guard let url = try? SRTicket.write(ticket) else {
                    NSLog("[SwiftRight] 重试写入凭据仍然失败")
                    return
                }
                // 重试这一路同样不激活，理由见 deliver(_:completion:)。
                Self.deliver(url) { delivered in
                    if !delivered { NSLog("[SwiftRight] 重试投递凭据失败") }
                }
            }
        }
    }

    // MARK: - 选择

    /// 拿当前选择。空白处右键时退化为"当前文件夹"。
    private func currentSelection(isContainerMenu: Bool) -> [String] {
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs() ?? []
        if !selected.isEmpty && !isContainerMenu {
            return selected.map(\.path)
        }
        if let target = controller.targetedURL() {
            return [target.path]
        }
        return selected.map(\.path)
    }
}
