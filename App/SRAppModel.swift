import AppKit
import Combine
import FinderSync
import SwiftUI

/// 管理界面的单一数据源。所有编辑都直接改内存里的 config，然后节流写盘。
@MainActor
final class SRAppModel: ObservableObject {

    static let shared = SRAppModel()

    @Published var commands: [SRCommand] = []
    @Published var settings = SRSettings()
    @Published var selection: UUID?
    @Published private(set) var lastSaveError: String?

    /// Finder 扩展当前是否已在系统设置里启用。
    @Published private(set) var isExtensionEnabled: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var isLoading = false
    /// save() 内部会重排 sortIndex，那次写入不该再触发一轮防抖保存。
    private var isSaving = false

    private init() {
        SRPaths.ensureDirectories()
        load()
        refreshExtensionStatus()

        // 任何改动都触发一次延迟落盘。扩展是按 mtime 判断是否重读的，
        // 所以写盘即生效，不需要额外通知。
        Publishers.CombineLatest($commands, $settings)
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { @MainActor [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }

    // MARK: - 读写

    func load() {
        isLoading = true
        defer { isLoading = false }

        SRConfigStore.shared.invalidate()
        let config = SRConfigStore.shared.load()
        settings = config.settings

        if config.commands.isEmpty && !SRConfigStore.shared.configFileExists {
            commands = SRCommand.builtinExamples()
            save()
        } else {
            commands = config.commands.sorted { $0.sortIndex < $1.sortIndex }
        }

        if selection == nil || !commands.contains(where: { $0.id == selection }) {
            selection = commands.first?.id
        }
    }

    func save() {
        guard !isLoading, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        normalizeSortIndexes()
        do {
            try SRConfigStore.shared.save(SRConfig(settings: settings, commands: commands))
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    private func normalizeSortIndexes() {
        for index in commands.indices where commands[index].sortIndex != index {
            commands[index].sortIndex = index
        }
    }

    // MARK: - 增删改

    var selectedCommand: SRCommand? {
        get {
            guard let selection else { return nil }
            return commands.first { $0.id == selection }
        }
        set {
            guard let newValue, let index = commands.firstIndex(where: { $0.id == newValue.id })
            else { return }
            commands[index] = newValue
        }
    }

    /// 按 id 而不是按下标做绑定。
    /// 下标会在侧边栏拖拽排序之后失效，编辑器就会把内容写到另一条命令上。
    func binding(for id: UUID) -> Binding<SRCommand>? {
        guard commands.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.commands.first { $0.id == id } ?? SRCommand()
            },
            set: { [weak self] newValue in
                guard let self,
                      let index = self.commands.firstIndex(where: { $0.id == id })
                else { return }
                self.commands[index] = newValue
            }
        )
    }

    @discardableResult
    func addCommand() -> UUID {
        addCommand(in: "")
    }

    /// 新建命令。`group` 非空时直接放进对应分组，排序窗口里会追加到组末。
    @discardableResult
    func addCommand(in group: String) -> UUID {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        var command = SRCommand()
        command.title = L("新建命令")
        command.script = L("# 选中的路径会作为 $1 $2 … 传进来，也可以用 {paths}") + "\necho {paths}"
        command.runMode = .captureOutput
        command.group = trimmed
        command.sortIndex = commands.count

        if !trimmed.isEmpty, !settings.groupOrder.contains(trimmed) {
            settings.groupOrder.append(trimmed)
        }

        commands.append(command)
        selection = command.id
        return command.id
    }

    func duplicate(_ id: UUID) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        var copy = commands[index]
        copy.id = UUID()
        copy.title += L(" 副本")
        commands.insert(copy, at: index + 1)
        selection = copy.id
    }

    // MARK: - 从终端生成命令

    /// 已经有指向这个终端的「在此处打开」命令了吗。
    func terminalCommand(for terminalID: String) -> SRCommand? {
        commands.first { $0.runMode == .terminal && $0.terminalID == terminalID }
    }

    /// 为某个终端生成一条「在此处打开」命令。
    ///
    /// 已经有了就不重复添加，直接选中那一条 —— 重复的同名菜单项只会添乱。
    @discardableResult
    func addTerminalCommand(for terminal: SRTerminal) -> UUID {
        if let existing = terminalCommand(for: terminal.id) {
            selection = existing.id
            return existing.id
        }

        var command = SRCommand()
        command.title = L("在此处打开 %@", terminal.name)
        command.symbol = terminal.id == "com.apple.Terminal" ? "apple.terminal" : "terminal"
        command.runMode = .terminal
        command.terminalID = terminal.id
        // .selectionItself 三种情况都对：选中文件夹→进它，选中文件→进它所在目录，
        // 空白处右键→当前窗口的文件夹。
        command.workingDirectory = .selectionItself
        // 终端脚本开头已经 cd 过了，这里只需要留一个登录 shell。
        // 显式写出来是为了不依赖「命令结束后保持终端打开」那个开关。
        command.script = "exec $SHELL -l"
        command.allowsMultipleSelection = false
        command.sortIndex = commands.count

        commands.append(command)
        selection = command.id
        return command.id
    }

    /// 为清单里每个终端各生成一条，已存在的跳过。返回实际新增的条数。
    @discardableResult
    func addTerminalCommands(for terminals: [SRTerminal]) -> Int {
        var added = 0
        for terminal in terminals where terminalCommand(for: terminal.id) == nil {
            addTerminalCommand(for: terminal)
            added += 1
        }
        return added
    }

    // MARK: - 从编辑器生成命令

    /// 生成的编辑器命令长这样，用它反查是否已经建过。
    private func editorScript(for id: String) -> String {
        // 用 -b 按 bundle id 打开，而不是写死路径：
        // 应用升级、搬家、换盘都不会让这条命令失效。
        "open -b '\(id)' {paths}"
    }

    func editorCommand(for editorID: String) -> SRCommand? {
        let script = editorScript(for: editorID)
        return commands.first { $0.script == script }
    }

    /// 为某个编辑器生成一条「在此处打开」命令。
    ///
    /// 编辑器不需要像终端那样单开一种运行方式 —— 一条后台命令就够了，
    /// 而且脚本内容对用户完全透明，想改随时能改。
    @discardableResult
    func addEditorCommand(for editor: SREditor) -> UUID {
        if let existing = editorCommand(for: editor.id) {
            selection = existing.id
            return existing.id
        }

        var command = SRCommand()
        command.title = L("在此处打开 %@", editor.name)
        command.symbol = "chevron.left.forwardslash.chevron.right"
        command.runMode = .background
        command.script = editorScript(for: editor.id)
        // 直接把选中的东西丢给编辑器就行：点文件夹开文件夹，点文件开文件，
        // 空白处右键则是当前窗口这个文件夹。不必像终端那样绕工作目录。
        command.appliesTo = editor.opensFolders ? .any : .filesOnly
        command.allowsMultipleSelection = true
        command.sortIndex = commands.count

        commands.append(command)
        selection = command.id
        return command.id
    }

    @discardableResult
    func addEditorCommands(for editors: [SREditor]) -> Int {
        var added = 0
        for editor in editors where editorCommand(for: editor.id) == nil {
            addEditorCommand(for: editor)
            added += 1
        }
        return added
    }

    // MARK: - 从模板生成「新建文件」命令

    func templateCommand(for templateID: UUID) -> SRCommand? {
        let marker = SRFileTemplate.markerPrefix(for: templateID)
        return commands.first { $0.script.hasPrefix(marker) }
    }

    /// 为某个模板生成一条「新建 XX」命令。
    @discardableResult
    func addTemplateCommand(for template: SRFileTemplate) -> UUID {
        if let existing = templateCommand(for: template.id) {
            selection = existing.id
            return existing.id
        }

        var command = SRCommand()
        command.title = L("新建 %@", template.name)
        command.symbol = template.symbol
        // 收进一个分组，右键菜单里就是 Windows 那种「新建 ▸」的形状。
        command.group = L("新建文件")
        command.runMode = .background
        command.script = template.generatedScript()
        // 仅文件夹：空白处右键（作用于当前文件夹）和选中文件夹时出现，
        // 右键点在文件上时不出现 —— 和 Windows 的「新建」一致。
        command.appliesTo = .foldersOnly
        command.workingDirectory = .selectionItself
        command.allowsMultipleSelection = false
        command.sortIndex = commands.count

        commands.append(command)
        selection = command.id
        return command.id
    }

    @discardableResult
    func addTemplateCommands(for templates: [SRFileTemplate]) -> Int {
        var added = 0
        for template in templates where templateCommand(for: template.id) == nil {
            addTemplateCommand(for: template)
            added += 1
        }
        return added
    }

    /// 模板改动后同步到已生成的命令。
    ///
    /// 只覆盖标题、图标和脚本 —— 分组、启用状态、适用范围这些用户可能
    /// 自己调过，不该被模板编辑冲掉。
    func syncTemplateCommand(_ template: SRFileTemplate) {
        let marker = SRFileTemplate.markerPrefix(for: template.id)
        guard let index = commands.firstIndex(where: { $0.script.hasPrefix(marker) }) else { return }
        commands[index].title = L("新建 %@", template.name)
        commands[index].symbol = template.symbol
        commands[index].script = template.generatedScript()
    }

    /// 切换启用状态。侧边栏不再放开关，右键菜单和详情页都走这里。
    func toggleEnabled(_ id: UUID) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        commands[index].isEnabled.toggle()
    }

    func delete(_ id: UUID) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        commands.remove(at: index)
        selection = commands.indices.contains(index)
            ? commands[index].id
            : commands.last?.id
    }

    // MARK: - 分组与排序

    /// 侧边栏和排序窗口共用的分组视图。未分组永远在最前面。
    var sections: [SRCommandSection] {
        let ordered = settings.orderedGroups(for: commands)
        var result: [SRCommandSection] = []

        let ungrouped = commands
            .filter { $0.group.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.sortIndex < $1.sortIndex }
        if !ungrouped.isEmpty {
            result.append(SRCommandSection(name: "", commands: ungrouped))
        }

        for group in ordered {
            let items = commands
                .filter { $0.group.trimmingCharacters(in: .whitespaces) == group }
                .sorted { $0.sortIndex < $1.sortIndex }
            if !items.isEmpty {
                result.append(SRCommandSection(name: group, commands: items))
            }
        }
        return result
    }

    /// 排序窗口左侧的分组顺序。
    var sortGroupNames: [String] {
        settings.orderedGroups(for: commands)
    }

    /// 侧边栏拖拽。`from` / `to` 是「分组标题 + 命令」扁平行里的索引；
    /// 落到哪个分组，就把命令的 group 改到哪个分组。
    func moveSidebarRow(from sourceRow: Int, to destinationRow: Int) {
        let current = sections
        guard !current.isEmpty else { return }

        // 被拖的命令在第几个分组、组内第几项。
        var source: (section: Int, offset: Int)?
        var row = 0
        for (si, section) in current.enumerated() {
            row += 1 // 分组标题
            for ci in section.commands.indices {
                if row == sourceRow { source = (si, ci) }
                row += 1
            }
        }
        guard let source else { return } // 标题行不可拖

        // 落点对应的分组和组内偏移。
        var targetSection = current.count - 1
        var targetOffset = current.last?.commands.count ?? 0
        row = 0
        for (si, section) in current.enumerated() {
            let headerRow = row
            let firstRow = row + 1
            let lastRow = row + section.commands.count

            if destinationRow <= headerRow {
                if si == 0 {
                    targetSection = 0
                    targetOffset = 0
                } else {
                    // 落在标题上方 = 上一个分组的末尾
                    targetSection = si - 1
                    targetOffset = current[si - 1].commands.count
                }
                break
            }
            if destinationRow <= lastRow {
                targetSection = si
                targetOffset = destinationRow - firstRow
                break
            }
            row = lastRow + 1
        }

        var next = current
        let moved = next[source.section].commands.remove(at: source.offset)
        if targetSection == source.section && source.offset < targetOffset {
            targetOffset -= 1
        }
        targetOffset = min(max(targetOffset, 0), next[targetSection].commands.count)
        next[targetSection].commands.insert(moved, at: targetOffset)

        commit(sections: next)
    }

    /// 排序窗口：同一分组内拖动命令。按分组名定位，筛选状态下也不会错位。
    func moveCommand(inSectionNamed name: String, from offsets: IndexSet, to destination: Int) {
        var next = sections
        guard let index = next.firstIndex(where: { $0.name == name }) else { return }
        next[index].commands.move(fromOffsets: offsets, toOffset: destination)
        commit(sections: next)
    }

    /// 排序窗口：拖动分组调整分组之间的顺序。
    func moveGroup(from offsets: IndexSet, to destination: Int) {
        var names = settings.orderedGroups(for: commands)
        names.move(fromOffsets: offsets, toOffset: destination)
        settings.groupOrder = names
        commit(sections: sections)
    }

    /// 排序窗口：用下拉菜单更换命令的分组。
    func changeGroup(for id: UUID, to group: String) {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        guard commands[index].group.trimmingCharacters(in: .whitespaces) != trimmed else { return }

        var next = sections
        var moved: SRCommand?
        for si in next.indices {
            if let ci = next[si].commands.firstIndex(where: { $0.id == id }) {
                moved = next[si].commands.remove(at: ci)
                break
            }
        }
        guard let moved else { return }

        if trimmed.isEmpty {
            if next.first?.name == "" {
                next[0].commands.append(moved)
            } else {
                next.insert(SRCommandSection(name: "", commands: [moved]), at: 0)
            }
        } else if let si = next.firstIndex(where: { $0.name == trimmed }) {
            next[si].commands.append(moved)
        } else {
            // 新分组（或暂时没有命令的空分组）按配置顺序插到对应位置。
            let ordered = settings.orderedGroups(for: commands)
            let targetRank = ordered.firstIndex(of: trimmed) ?? ordered.count
            var insertAt = next.count
            for (i, section) in next.enumerated() {
                guard let rank = ordered.firstIndex(of: section.name) else { continue }
                if rank > targetRank {
                    insertAt = i
                    break
                }
            }
            next.insert(SRCommandSection(name: trimmed, commands: [moved]), at: insertAt)
        }

        commit(sections: next)
    }

    /// 新建一个空分组，返回最终使用的名称。
    @discardableResult
    func addGroup() -> String {
        let existing = Set(settings.orderedGroups(for: commands))
        var name = L("新分组")
        var index = 2
        while existing.contains(name) {
            name = L("新分组 %@", String(index))
            index += 1
        }
        var order = settings.groupOrder
        order.append(name)
        settings.groupOrder = order
        return name
    }

    /// 重命名分组：同步改所有命令的 group、分组顺序和图标。
    /// 新名字已经存在时直接合并到那个分组。
    func renameGroup(from old: String, to newRaw: String) {
        let oldName = old.trimmingCharacters(in: .whitespaces)
        let newName = newRaw.trimmingCharacters(in: .whitespaces)
        guard !oldName.isEmpty, !newName.isEmpty, oldName != newName else { return }

        for index in commands.indices
        where commands[index].group.trimmingCharacters(in: .whitespaces) == oldName {
            commands[index].group = newName
        }

        var icons = settings.groupIcons
        if let icon = icons.removeValue(forKey: oldName), icons[newName] == nil {
            icons[newName] = icon
        }
        settings.groupIcons = icons

        var order = settings.groupOrder
        if let index = order.firstIndex(of: oldName) {
            if order.contains(newName) {
                order.remove(at: index)
            } else {
                order[index] = newName
            }
        } else if !order.contains(newName) {
            order.append(newName)
        }
        settings.groupOrder = order

        commit(sections: sections)
    }

    /// 设置分组图标。空字符串或默认的 folder 会清除自定义图标。
    func setGroupSymbol(_ symbol: String, for group: String) {
        let name = group.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var icons = settings.groupIcons
        if symbol.isEmpty || symbol == "folder" {
            icons.removeValue(forKey: name)
        } else {
            icons[name] = symbol
        }
        settings.groupIcons = icons
    }

    /// 把「按分组展开」的数组写回 commands / settings.groupOrder，
    /// 同时把 sortIndex 重新编号。空分组会被丢掉。
    private func commit(sections: [SRCommandSection]) {
        var flattened: [SRCommand] = []
        var order: [String] = []
        var index = 0

        for section in sections {
            guard !section.commands.isEmpty else { continue }
            if !section.name.isEmpty { order.append(section.name) }
            for var command in section.commands {
                command.group = section.name
                command.sortIndex = index
                index += 1
                flattened.append(command)
            }
        }

        commands = flattened

        // 保留暂时没有命令的空分组，并尽量维持它们原来的位置。
        var groupOrder: [String] = []
        for section in sections where !section.name.isEmpty && !section.commands.isEmpty {
            groupOrder.append(section.name)
        }
        for (oldIndex, name) in settings.groupOrder.enumerated() {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !groupOrder.contains(trimmed) else { continue }

            var insertAt = 0
            for previous in settings.groupOrder[..<oldIndex].reversed() {
                let candidate = previous.trimmingCharacters(in: .whitespaces)
                if let index = groupOrder.firstIndex(of: candidate) {
                    insertAt = index + 1
                    break
                }
            }
            groupOrder.insert(trimmed, at: insertAt)
        }
        settings.groupOrder = groupOrder

        if let selection, !commands.contains(where: { $0.id == selection }) {
            self.selection = commands.first?.id
        }
    }

    /// 已经用过的分组名，供编辑器做补全。顺序跟右键菜单一致。
    var knownGroups: [String] {
        sortGroupNames
    }

    // MARK: - 导入导出

    func exportConfig(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SRConfig(settings: settings, commands: commands))
        try data.write(to: url, options: .atomic)
    }

    /// 导入。`merge` 为 true 时追加到现有列表，否则整体替换。
    func importConfig(from url: URL, merge: Bool) throws {
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(SRConfig.self, from: data)

        if merge {
            var incoming = config.commands
            let existing = Set(commands.map(\.id))
            for index in incoming.indices where existing.contains(incoming[index].id) {
                // ID 撞车就换一个，不要覆盖用户已有的命令。
                incoming[index].id = UUID()
            }
            commands.append(contentsOf: incoming)
        } else {
            settings = config.settings
            commands = config.commands
        }
        normalizeSortIndexes()
        save()
        selection = commands.first?.id
    }

    // MARK: - 扩展状态

    func refreshExtensionStatus() {
        isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
    }

    /// 打开「登录项与扩展」设置面板。系统版本之间 URL 有差异，逐个尝试。
    func openExtensionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.extensions",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// 手动把 appex 注册给 LaunchServices / pluginkit。
    /// App 从没被运行过、或者被移动过位置时，扩展可能不出现在设置列表里。
    func registerExtension() -> String {
        let appexPath = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("FinderExtension.appex")

        guard let appexPath, FileManager.default.fileExists(atPath: appexPath.path) else {
            return L("找不到扩展：") + (appexPath?.path ?? L("未知路径"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-a", appexPath.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0 {
                return text.isEmpty ? L("已注册，请到系统设置里勾选 SwiftRight。") : text
            }
            return L("注册失败（退出码 %@）", String(process.terminationStatus)) + text
        } catch {
            return L("注册失败：") + error.localizedDescription
        }
    }

    /// 重启 Finder。改了扩展之后菜单不刷新时用得上。
    func relaunchFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
    }
}

/// 侧边栏和排序窗口共用的分组视图。`name` 为空表示「未分组」。
struct SRCommandSection: Identifiable {
    let name: String
    var commands: [SRCommand]

    var id: String { name }
}
