import Foundation

// MARK: - 运行方式

/// 命令执行完成后的呈现方式。
///
/// 面向用户的名字见 App/SRCommandDisplay.swift —— 那些要走本地化，
/// 而本地化只存在于主 App，扩展 target 里没有。
enum SRRunMode: String, Codable, CaseIterable, Identifiable {
    /// 静默在后台跑，只有失败时才提示。
    case background
    /// 在 SwiftRight 的输出窗口里实时显示 stdout / stderr。
    case captureOutput
    /// 生成一个临时 .command 脚本，交给终端打开。
    case terminal

    var id: String { rawValue }
}

// MARK: - 工作目录

enum SRWorkingDirectory: String, Codable, CaseIterable, Identifiable {
    /// 第一个选中项所在的文件夹。
    case selectionParent
    /// 第一个选中项本身（仅当它是文件夹时有意义）。
    case selectionItself
    /// 当前 Finder 窗口所在文件夹。
    case targetFolder
    /// 用户自定义路径。
    case custom

    var id: String { rawValue }
}

// MARK: - 适用范围

enum SRSelectionKind: String, Codable, CaseIterable, Identifiable {
    case any
    case filesOnly
    case foldersOnly

    var id: String { rawValue }
}

// MARK: - 命令模型

/// 一条用户自定义的右键命令。这是 App 与 Finder 扩展之间唯一共享的数据结构。
struct SRCommand: Codable, Identifiable, Hashable {
    var id: UUID = UUID()

    /// 菜单里显示的标题。
    var title: String = "新建命令"
    /// SF Symbol 名称，用作菜单图标。留空则不显示图标。
    var symbol: String = "terminal"
    /// 可选的分组名。同名的命令会被收进同一个二级子菜单。
    var group: String = ""

    /// 脚本正文。支持 {path} {paths} {dir} 等占位符，详见 SRPlaceholder。
    var script: String = ""
    /// 解释器路径。脚本以 #! 开头时该字段被忽略。
    var shell: String = "/bin/zsh"
    /// 传给解释器的参数，脚本正文会追加在最后。
    var shellArguments: [String] = ["-c"]

    var runMode: SRRunMode = .background
    /// `runMode == .terminal` 时用哪个终端，存 bundle identifier。
    /// 留空表示跟随设置里的全局默认终端。
    ///
    /// 这里只存 ID 不存整个终端对象：终端清单是 App 独有的，
    /// 而这个结构体要能被沙盒扩展一起编译。
    var terminalID: String = ""
    var workingDirectory: SRWorkingDirectory = .selectionParent
    /// workingDirectory == .custom 时使用。
    var customWorkingDirectory: String = ""

    var appliesTo: SRSelectionKind = .any
    /// 允许的扩展名（不含点，小写）。空数组表示不限。
    var fileExtensions: [String] = []
    /// 允许多选。为 false 时，多选状态下该命令会被隐藏。
    var allowsMultipleSelection: Bool = true
    /// 对每个选中项各跑一次，而不是一次性把所有路径传进去。
    var runOncePerItem: Bool = false

    var isEnabled: Bool = true
    /// 执行前弹窗确认。
    var confirmBeforeRun: Bool = false
    /// 执行结束后发系统通知。
    var notifyOnFinish: Bool = false
    /// 超时秒数，0 表示不限制。
    var timeoutSeconds: Int = 0

    /// 排序权重，越小越靠前。
    var sortIndex: Int = 0

    // 旧版本配置里可能缺字段，给全部非必需字段兜底。
    enum CodingKeys: String, CodingKey {
        case id, title, symbol, group, script, shell, shellArguments
        case runMode, terminalID, workingDirectory, customWorkingDirectory
        case appliesTo, fileExtensions, allowsMultipleSelection, runOncePerItem
        case isEnabled, confirmBeforeRun, notifyOnFinish, timeoutSeconds, sortIndex
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "未命名"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "terminal"
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        shell = try c.decodeIfPresent(String.self, forKey: .shell) ?? "/bin/zsh"
        shellArguments = try c.decodeIfPresent([String].self, forKey: .shellArguments) ?? ["-c"]
        runMode = try c.decodeIfPresent(SRRunMode.self, forKey: .runMode) ?? .background
        terminalID = try c.decodeIfPresent(String.self, forKey: .terminalID) ?? ""
        workingDirectory = try c.decodeIfPresent(SRWorkingDirectory.self, forKey: .workingDirectory) ?? .selectionParent
        customWorkingDirectory = try c.decodeIfPresent(String.self, forKey: .customWorkingDirectory) ?? ""
        appliesTo = try c.decodeIfPresent(SRSelectionKind.self, forKey: .appliesTo) ?? .any
        fileExtensions = try c.decodeIfPresent([String].self, forKey: .fileExtensions) ?? []
        allowsMultipleSelection = try c.decodeIfPresent(Bool.self, forKey: .allowsMultipleSelection) ?? true
        runOncePerItem = try c.decodeIfPresent(Bool.self, forKey: .runOncePerItem) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        confirmBeforeRun = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeRun) ?? false
        notifyOnFinish = try c.decodeIfPresent(Bool.self, forKey: .notifyOnFinish) ?? false
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 0
        sortIndex = try c.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
    }
}

// MARK: - 匹配逻辑

extension SRCommand {
    /// 判断这条命令是否应该出现在当前选择下的右键菜单里。
    /// 扩展和 App 共用同一份逻辑，避免菜单显示与实际可执行性不一致。
    func matches(paths: [String], isContainerMenu: Bool) -> Bool {
        guard isEnabled else { return false }
        guard !paths.isEmpty else { return false }
        if paths.count > 1 && !allowsMultipleSelection { return false }

        // 空白处右键作用于当前文件夹，此时只检查“仅文件”这一种冲突。
        if isContainerMenu {
            return appliesTo != .filesOnly
        }

        for path in paths {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            // 路径可能来自网络卷等，取不到就放行，交给脚本自己处理。
            guard exists else { continue }

            switch appliesTo {
            case .any: break
            case .filesOnly: if isDir.boolValue { return false }
            case .foldersOnly: if !isDir.boolValue { return false }
            }

            if !fileExtensions.isEmpty {
                let ext = (path as NSString).pathExtension.lowercased()
                if !fileExtensions.contains(ext) { return false }
            }
        }
        return true
    }
}

// MARK: - 全局设置

/// 与命令列表一起存盘的全局偏好。
struct SRSettings: Codable, Hashable {
    /// 收进二级菜单的分组共用的菜单项名字。
    var menuTitle: String = "SwiftRight"
    /// 共用的二级菜单项的 SF Symbol。
    var menuSymbol: String = "bolt.circle"
    /// 在菜单项里显示图标。
    var showIcons: Bool = true
    /// 分组的显示顺序。允许包含还没有命令的空分组。
    var groupOrder: [String] = []
    /// 分组的自定义图标（SF Symbol），没有记录时用默认的 folder。
    var groupIcons: [String: String] = [:]
    /// 哪些分组收进「菜单名称」那个二级菜单里。没列进来的分组直接出现在
    /// 右键菜单顶层（各自仍是一个分组子菜单）。
    var submenuGroups: [String] = []
    /// 不显示在右键菜单里的分组（分组级别的启用开关）。
    var hiddenGroups: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case menuTitle, menuSymbol, showIcons, groupOrder, groupIcons,
             submenuGroups, hiddenGroups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menuTitle = try c.decodeIfPresent(String.self, forKey: .menuTitle) ?? "SwiftRight"
        menuSymbol = try c.decodeIfPresent(String.self, forKey: .menuSymbol) ?? "bolt.circle"
        showIcons = try c.decodeIfPresent(Bool.self, forKey: .showIcons) ?? true
        groupOrder = try c.decodeIfPresent([String].self, forKey: .groupOrder) ?? []
        groupIcons = try c.decodeIfPresent([String: String].self, forKey: .groupIcons) ?? [:]
        submenuGroups = try c.decodeIfPresent([String].self, forKey: .submenuGroups) ?? []
        hiddenGroups = try c.decodeIfPresent([String].self, forKey: .hiddenGroups) ?? []
    }

    /// 这个分组是否要收进共用的二级菜单。
    func isInSubmenu(_ group: String) -> Bool {
        let name = group.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        return submenuGroups.contains(name)
    }

    /// 这个分组是否在右键菜单里被隐藏。
    func isGroupHidden(_ group: String) -> Bool {
        let name = group.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        return hiddenGroups.contains(name)
    }

    /// 分组在菜单 / 侧边栏里显示的图标。
    func symbol(for group: String) -> String {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let symbol = groupIcons[trimmed],
              !symbol.isEmpty
        else { return "folder" }
        return symbol
    }
}

extension SRSettings {
    /// 按配置的 `groupOrder` 排分组，没列进去的按首次出现顺序补在后面。
    /// App 的侧边栏、排序窗口和访达菜单共用这一份顺序。
    func orderedGroups(for commands: [SRCommand]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for name in groupOrder {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            ordered.append(trimmed)
        }

        for command in commands.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            let trimmed = command.group.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            ordered.append(trimmed)
        }

        return ordered
    }
}

/// commands.json 的顶层结构。
struct SRConfig: Codable {
    var version: Int = 1
    var settings: SRSettings = SRSettings()
    var commands: [SRCommand] = []

    init() {}

    init(settings: SRSettings, commands: [SRCommand]) {
        self.settings = settings
        self.commands = commands
    }

    enum CodingKeys: String, CodingKey { case version, settings, commands }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        settings = try c.decodeIfPresent(SRSettings.self, forKey: .settings) ?? SRSettings()
        commands = try c.decodeIfPresent([SRCommand].self, forKey: .commands) ?? []
    }
}
