import AppKit
import Combine
import UniformTypeIdentifiers

/// 终端清单：扫描、增删、选默认。
///
/// 存在 UserDefaults 而不是 commands.json —— 访达扩展用不到这些，
/// 没必要塞进那份共享配置。
@MainActor
final class SRTerminalCatalog: ObservableObject {

    static let shared = SRTerminalCatalog()

    @Published private(set) var terminals: [SRTerminal] = []

    /// 「在终端中运行」用哪个。空字符串表示还没选，回落到系统 Terminal。
    @Published var selectedID: String {
        didSet { defaults.set(selectedID, forKey: Keys.selected) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let terminals = "terminals"
        static let selected = "selectedTerminal"
    }

    private init() {
        selectedID = defaults.string(forKey: Keys.selected) ?? ""
        terminals = loadStored()

        // 旧版本会把开发目录 / 下载目录里注册过的副本也扫进来。
        // 升级后先清一遍，手动添加的条目保留。
        let outOfPlace = terminals.filter {
            $0.isManual != true && !SRBundleInspector.isInStandardLocation($0.url)
        }
        if !outOfPlace.isEmpty {
            terminals.removeAll { terminal in outOfPlace.contains { $0.id == terminal.id } }
            persist()
        }

        // 头一次运行先自动扫一遍，不然「在终端中运行」的列表是空的。
        if terminals.isEmpty {
            _ = scan()
            if selectedID.isEmpty {
                selectedID = terminals.first(where: { $0.id == "com.apple.Terminal" })?.id
                    ?? terminals.first?.id ?? ""
            }
        }
    }

    // MARK: - 选中

    var selected: SRTerminal? {
        terminals.first { $0.id == selectedID } ?? terminals.first
    }

    // MARK: - 扫描

    struct ScanResult {
        var added: [SRTerminal] = []
        var refreshed: Int = 0
        var removed: [String] = []
    }

    /// 两路并行地找终端：
    ///
    /// 1. 拿内置配方里的 bundle ID 逐个问 LaunchServices；
    /// 2. 反查"谁能打开 shell 脚本" —— 用来捞内置清单里没有的终端。
    ///
    /// 两路都只保留标准应用目录里的副本（/Applications、/System/Applications、
    /// ~/Applications），开发目录或下载目录里注册过的副本不算 —— 那些多半是
    /// 解压出来还没装、或者早就删了的残留。
    ///
    /// 已在列表里的只更新路径（应用可能被挪过位置），不覆盖用户改过的参数模板。
    @discardableResult
    func scan() -> ScanResult {
        var result = ScanResult()
        var found: [String: (name: String, path: String)] = [:]

        let workspace = NSWorkspace.shared

        for recipe in SRTerminal.recipes {
            let copies = workspace.urlsForApplications(withBundleIdentifier: recipe.id)
            guard let url = SRBundleInspector.standardCopy(of: copies) else { continue }
            found[recipe.id] = (recipe.name, url.path)
        }

        for url in shellScriptHandlers() {
            guard SRBundleInspector.isInStandardLocation(url),
                  let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier,
                  found[id] == nil
            else { continue }
            let name = (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            found[id] = (name, url.path)
        }

        for (id, info) in found {
            if let index = terminals.firstIndex(where: { $0.id == id }) {
                // 只同步路径，用户自定义的模板保持不动。
                if terminals[index].path != info.path {
                    terminals[index].path = info.path
                    result.refreshed += 1
                }
            } else {
                let terminal = SRTerminal.make(bundleID: id, name: info.name, path: info.path)
                terminals.append(terminal)
                result.added.append(terminal)
            }
        }

        // 已经删掉的应用没必要继续留着；以前扫描留下的、位于非标准目录的
        // 自动条目也一并清掉（手动添加的保留）。
        let stale = terminals.filter { terminal in
            !terminal.exists
                || (terminal.isManual != true
                    && !SRBundleInspector.isInStandardLocation(terminal.url))
        }
        if !stale.isEmpty {
            result.removed = stale.map(\.name)
            terminals.removeAll { terminal in
                stale.contains { $0.id == terminal.id }
            }
        }

        sortAndPersist()

        if terminals.first(where: { $0.id == selectedID }) == nil {
            selectedID = terminals.first(where: { $0.id == "com.apple.Terminal" })?.id
                ?? terminals.first?.id ?? ""
        }
        return result
    }

    /// 系统里真正会"执行"shell 脚本的应用。
    ///
    /// 光问 LaunchServices"谁能打开 shell 脚本"是不够的 —— Chrome、备忘录、
    /// Pages、TextEdit、Xcode 这些能*编辑*脚本的应用会一起被捞出来，
    /// 实测 30 个结果里有 19 个是噪音。
    ///
    /// 真正的判据是 Info.plist 里 `CFBundleTypeRole == "Shell"`：
    /// 那是应用在声明"我执行这类文件"。Terminal / Ghostty / kitty / WezTerm
    /// 都是 Shell，Chrome 是 Viewer，编辑器则根本不声明这个角色。
    private func shellScriptHandlers() -> [URL] {
        var candidates: [URL] = []
        for type in [UTType.shellScript, UTType("com.apple.terminal.shell-script")].compactMap({ $0 }) {
            candidates.append(contentsOf: NSWorkspace.shared.urlsForApplications(toOpen: type))
        }

        var seen = Set<String>()
        return candidates.filter { url in
            guard seen.insert(url.path).inserted else { return false }
            return declaresShellRole(at: url)
        }
    }

    private func declaresShellRole(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url),
              let types = bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]]
        else { return false }

        return types.contains { entry in
            (entry["CFBundleTypeRole"] as? String) == "Shell"
        }
    }

    // MARK: - 手动增删

    /// 手动挑一个 .app 加进来。扫描漏掉的终端可以这样补。
    @discardableResult
    func add(appAt url: URL) -> SRTerminal? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        if let existing = terminals.first(where: { $0.id == id }) { return existing }

        let name = (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        var terminal = SRTerminal.make(bundleID: id, name: name, path: url.path)
        terminal.isManual = true
        terminals.append(terminal)
        sortAndPersist()
        return terminal
    }

    func remove(_ id: String) {
        terminals.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = terminals.first?.id ?? ""
        }
        sortAndPersist()
    }

    func update(_ terminal: SRTerminal) {
        guard let index = terminals.firstIndex(where: { $0.id == terminal.id }) else { return }
        terminals[index] = terminal
        persist()
    }

    /// 把某一项恢复成内置配方。改坏了参数模板可以用这个救回来。
    func resetToRecipe(_ id: String) {
        guard let index = terminals.firstIndex(where: { $0.id == id }),
              let recipe = SRTerminal.recipes.first(where: { $0.id == id })
        else { return }
        terminals[index].launchStyle = recipe.style
        terminals[index].argumentTemplate = recipe.template
        terminals[index].isBuiltin = true
        persist()
    }

    // MARK: - 存取

    private func sortAndPersist() {
        // 有内置配方的排前面，其余按名字。
        terminals.sort { lhs, rhs in
            if lhs.isBuiltin != rhs.isBuiltin { return lhs.isBuiltin }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(terminals) else { return }
        defaults.set(data, forKey: Keys.terminals)
    }

    private func loadStored() -> [SRTerminal] {
        guard let data = defaults.data(forKey: Keys.terminals),
              let decoded = try? JSONDecoder().decode([SRTerminal].self, from: data)
        else { return [] }
        return decoded
    }
}
