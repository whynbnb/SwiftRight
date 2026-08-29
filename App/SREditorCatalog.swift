import AppKit
import Combine
import UniformTypeIdentifiers

/// 编辑器清单：扫描、增删。
///
/// 和 SRTerminalCatalog 结构相似但刻意没有合并 —— 两者的扫描判据、
/// 逐项属性、启动方式都不一样，硬抽出一个共同基类只会得到一个
/// 一半字段对另一半无意义的漏抽象。真正重合的那点（读 bundle 信息）
/// 已经提到 SRBundleInspector 里了。
///
/// 另一处不同：编辑器没有"全局默认"。终端需要它是因为「在终端中运行」
/// 这个运行方式本身要挑一个终端；而编辑器命令生成时就把 bundle id 写进
/// 脚本了，每条命令自带目标。
final class SREditorCatalog: ObservableObject {

    static let shared = SREditorCatalog()

    @Published private(set) var editors: [SREditor] = []

    private let defaults = UserDefaults.standard
    private enum Keys { static let editors = "editors" }

    private init() {
        editors = loadStored()
        if editors.isEmpty { _ = scan() }
    }

    // MARK: - 扫描

    struct ScanResult {
        var added: [SREditor] = []
        var refreshed: Int = 0
        var removed: [String] = []
    }

    /// 两路并行：
    /// 1. 内置清单的 bundle ID 逐个问 LaunchServices —— 装在 ~/Applications
    ///    的 JetBrains 全家也能找到；
    /// 2. 反查"谁把文件夹声明成可编辑的文档" —— 用来发现清单外的编辑器
    ///    （Cursor、Windsurf 这类新工具，以及我写死的 ID 过期时兜底）。
    ///
    /// 第 2 路必须要求角色是 Editor 而不是 Viewer：CotEditor 和 Typora
    /// 把文件夹声明成 Viewer，那只是"能浏览"，不是"能当工程打开"。
    @discardableResult
    func scan() -> ScanResult {
        var result = ScanResult()
        var found: [String: (name: String, path: String, folders: Bool?)] = [:]

        for recipe in SREditor.recipes {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: recipe.id)
            else { continue }
            found[recipe.id] = (recipe.name, url.path, recipe.folders)
        }

        for url in folderEditors() {
            guard let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier,
                  found[id] == nil
            else { continue }
            found[id] = (SRBundleInspector.name(at: url), url.path, true)
        }

        for (id, info) in found {
            if let index = editors.firstIndex(where: { $0.id == id }) {
                if editors[index].path != info.path {
                    editors[index].path = info.path
                    result.refreshed += 1
                }
            } else {
                let editor = SREditor.make(bundleID: id,
                                           name: info.name,
                                           path: info.path,
                                           opensFolders: info.folders)
                editors.append(editor)
                result.added.append(editor)
            }
        }

        let stale = editors.filter { !$0.exists }
        if !stale.isEmpty {
            result.removed = stale.map(\.name)
            editors.removeAll { !$0.exists }
        }

        sortAndPersist()
        return result
    }

    /// 声明了「文件夹是我可编辑的文档」的应用。
    private func folderEditors() -> [URL] {
        guard let folder = UTType("public.folder") else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: folder).filter { url in
            guard seen.insert(url.path).inserted else { return false }
            return SRBundleInspector.declaresRole("Editor",
                                                  forAnyOf: ["public.folder", "public.directory"],
                                                  at: url)
        }
    }

    // MARK: - 手动增删改

    @discardableResult
    func add(appAt url: URL) -> SREditor? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        if let existing = editors.first(where: { $0.id == id }) { return existing }

        // 手动添加的按声明推断能否开文件夹，猜错了用户可以在这一行直接改。
        let folders = SRBundleInspector.declaresRole("Editor",
                                                     forAnyOf: ["public.folder", "public.directory"],
                                                     at: url)
        let editor = SREditor.make(bundleID: id,
                                   name: SRBundleInspector.name(at: url),
                                   path: url.path,
                                   opensFolders: folders)
        editors.append(editor)
        sortAndPersist()
        return editor
    }

    func remove(_ id: String) {
        editors.removeAll { $0.id == id }
        sortAndPersist()
    }

    func update(_ editor: SREditor) {
        guard let index = editors.firstIndex(where: { $0.id == editor.id }) else { return }
        editors[index] = editor
        persist()
    }

    // MARK: - 存取

    private func sortAndPersist() {
        editors.sort { lhs, rhs in
            // 能开工程的排前面 —— 「在此处打开」多半是冲着开工程去的。
            if lhs.opensFolders != rhs.opensFolders { return lhs.opensFolders }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(editors) else { return }
        defaults.set(data, forKey: Keys.editors)
    }

    private func loadStored() -> [SREditor] {
        guard let data = defaults.data(forKey: Keys.editors),
              let decoded = try? JSONDecoder().decode([SREditor].self, from: data)
        else { return [] }
        return decoded
    }
}
