import AppKit
import Combine
import FinderSync
import SwiftUI

/// 管理界面的单一数据源。所有编辑都直接改内存里的 config，然后节流写盘。
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
            .sink { [weak self] _ in self?.save() }
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
        var command = SRCommand()
        command.title = L("新建命令")
        command.script = L("# 选中的路径会作为 $1 $2 … 传进来，也可以用 {paths}") + "\necho {paths}"
        command.runMode = .captureOutput
        command.sortIndex = commands.count
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

    func move(from source: IndexSet, to destination: Int) {
        commands.move(fromOffsets: source, toOffset: destination)
    }

    /// 已经用过的分组名，供编辑器做补全。
    var knownGroups: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for command in commands {
            let group = command.group.trimmingCharacters(in: .whitespaces)
            guard !group.isEmpty, !seen.contains(group) else { continue }
            seen.insert(group)
            result.append(group)
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
