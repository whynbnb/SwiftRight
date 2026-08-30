import AppKit
import FinderSync

/// Finder 右键菜单扩展。
///
/// 这里刻意保持"薄"：只负责读配置、拼菜单、把点击事件转成一张凭据丢给主 App。
/// 真正执行命令必须放在非沙盒的主 App 里 —— app extension 强制沙盒，
/// 在扩展里 `Process` 起任何外部程序都会被拒绝。
final class FinderSync: FIFinderSync {

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

        // 把命令按 group 归拢，同时保留组内和组之间的原始顺序。
        var groupOrder: [String] = []
        var grouped: [String: [SRCommand]] = [:]
        for command in candidates {
            let key = command.group.trimmingCharacters(in: .whitespaces)
            if grouped[key] == nil {
                grouped[key] = []
                groupOrder.append(key)
            }
            grouped[key]?.append(command)
        }

        func buildItems(into menu: NSMenu) {
            for group in groupOrder {
                guard let commands = grouped[group] else { continue }

                if group.isEmpty {
                    for command in commands {
                        menu.addItem(makeItem(for: command, tag: &nextTag, settings: config.settings))
                    }
                } else {
                    let submenu = NSMenu(title: group)
                    for command in commands {
                        submenu.addItem(makeItem(for: command, tag: &nextTag, settings: config.settings))
                    }
                    let holder = NSMenuItem(title: group, action: nil, keyEquivalent: "")
                    holder.submenu = submenu
                    if config.settings.showIcons {
                        holder.image = symbolImage("folder")
                    }
                    menu.addItem(holder)
                }
            }
        }

        let menu = NSMenu(title: config.settings.menuTitle)

        if config.settings.useSubmenu {
            let submenu = NSMenu(title: config.settings.menuTitle)
            buildItems(into: submenu)
            let root = NSMenuItem(title: config.settings.menuTitle, action: nil, keyEquivalent: "")
            root.submenu = submenu
            if config.settings.showIcons {
                root.image = symbolImage(config.settings.menuSymbol)
            }
            menu.addItem(root)
        } else {
            buildItems(into: menu)
        }

        return menu
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

    /// 图标画布的逻辑尺寸。所有菜单项统一用这个尺寸，
    /// 菜单里的文字才会对齐在同一列上。
    private static let iconBox = NSSize(width: 20, height: 16)
    /// 符号本身的目标高度，比画布矮一点留出呼吸空间。
    private static let iconGlyphHeight: CGFloat = 15
    private static let iconPointSize: CGFloat = 14

    /// 渲染好的图标缓存。`menu(for:)` 每次右键都会跑一遍，
    /// 十几个菜单项每次都重新画位图是白费。
    private var iconCache: [String: NSImage] = [:]

    /// 把 SF Symbol 渲染成菜单图标。
    ///
    /// 直接把 symbol image 交给 NSMenuItem 会又糊又不齐，原因有两个：
    ///
    /// 其一，符号的原始尺寸各不相同（doc.plaintext 是 15×17，
    /// chevron.left.forwardslash.chevron.right 是 23×16，internaldrive 是 20×14），
    /// 塞进访达的图标槽全是 ×0.94、×1.14 这种非整数倍缩放，边缘必然发虚；
    /// 而且这个菜单要跨 XPC 代理给访达，NSSymbolImageRep 是私有类型，
    /// 归档过去还剩多少矢量信息并不可控。
    ///
    /// 其二，尺寸不齐会让菜单项看起来大小不一。
    ///
    /// 所以这里自己按 2x 画成位图交出去 —— 位图跨进程无损 —— 并且
    /// **按高度归一而不是塞进方框**：SF Symbols 的设计就是同一 pointSize 下
    /// 视觉高度一致、宽度随字形变化，按框等比缩会把 `</>` 这类宽符号压得明显偏小。
    private func symbolImage(_ name: String) -> NSImage? {
        if let cached = iconCache[name] { return cached }

        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize,
                                                        weight: .regular)
        let configured = symbol.withSymbolConfiguration(configuration) ?? symbol

        let natural = configured.size
        guard natural.width > 0, natural.height > 0 else { return nil }

        let box = Self.iconBox
        // 先按高度归一；个别特别宽的符号（如 23×16 的 `</>`）会超出画布宽度，
        // 那就退回按宽度收一下，绝不拉伸。
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
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: box)
        image.addRepresentation(rep)
        // 模板图：访达会按选中状态自己上色（未选中黑、选中白）。
        image.isTemplate = true

        iconCache[name] = image
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
            deliver(url) { [weak self] delivered in
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
    private func deliver(_ url: URL, completion: @escaping (Bool) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            completion(error == nil)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let url = try? SRTicket.write(ticket) else {
                    NSLog("[SwiftRight] 重试写入凭据仍然失败")
                    return
                }
                // 重试这一路同样不激活，理由见 deliver(_:completion:)。
                self.deliver(url) { delivered in
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
