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

    private func symbolImage(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let configured = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        ) ?? image
        configured.isTemplate = true
        return configured
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
            if !NSWorkspace.shared.open(url) {
                // URL scheme 还没被 LaunchServices 认到。
                launchHostApp(thenRetry: ticket)
            }
        } catch {
            // 多半是 ~/Library/Application Support/SwiftRight/ 还不存在：
            // 沙盒例外只覆盖这个目录本身，建不了它的父目录，得靠 App 首次启动来创建。
            NSLog("[SwiftRight] 写入调用凭据失败，尝试拉起宿主 App: \(error.localizedDescription)")
            launchHostApp(thenRetry: ticket)
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
                NSWorkspace.shared.open(url)
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
