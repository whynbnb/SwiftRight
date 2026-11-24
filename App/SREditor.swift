import AppKit
import Foundation

/// 读取 .app 内部信息的共用工具。终端和编辑器的扫描都要用。
enum SRBundleInspector {

    /// 这个 app 是否为某类文件声明了指定的角色。
    ///
    /// `CFBundleTypeRole` 才是真正有区分度的信号：
    /// `Shell` = 我执行这类文件，`Editor` = 我编辑，`Viewer` = 我只看。
    /// 光看"能不能打开"会把一堆文本编辑器和浏览器混进来。
    static func declaresRole(_ role: String,
                             forAnyOf contentTypes: Set<String>,
                             at url: URL) -> Bool {
        guard let bundle = Bundle(url: url),
              let documents = bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]]
        else { return false }

        return documents.contains { entry in
            guard (entry["CFBundleTypeRole"] as? String) == role else { return false }
            guard !contentTypes.isEmpty else { return true }
            let declared = Set((entry["LSItemContentTypes"] as? [String]) ?? [])
            return !declared.isDisjoint(with: contentTypes)
        }
    }

    static func name(at url: URL) -> String {
        guard let bundle = Bundle(url: url) else {
            return url.deletingPathExtension().lastPathComponent
        }
        return (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    // MARK: - 扫描范围

    /// 自动扫描只认这几个标准安装目录（含子目录）：
    /// `/Applications`、`/System/Applications`、`~/Applications`。
    ///
    /// 别的地方（开发目录、下载目录、外置盘）里注册过的副本不算，
    /// 否则 LaunchServices 一查就会把一堆"还记得的"安装包带出来。
    /// 用户确实装在别处时，可以走「手动添加…」。
    static var standardApplicationRoots: [String] {
        var roots = ["/Applications", "/System/Applications"]
        roots.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path)
        return roots
    }

    static func isInStandardLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return standardApplicationRoots.contains { root in
            path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// LaunchServices 可能给出同一个 bundle ID 的多份副本，挑标准位置的那份。
    static func standardCopy(of urls: [URL]) -> URL? {
        urls.first(where: isInStandardLocation)
    }

    static func version(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }
}

// MARK: - 编辑器

/// 一个可以用来打开文件或工程的编辑器。
///
/// 比终端简单得多：终端要各写各的命令行配方，编辑器基本都能靠
/// `open -b <bundle id> <路径>` 打开，不需要 per-app 参数。
/// 真正需要逐个记录的只有一件事 —— 能不能把文件夹当工程打开。
struct SREditor: Codable, Identifiable, Hashable {

    var id: String
    var name: String
    var path: String
    /// 能把目录当工程 / 工作区打开。
    ///
    /// 不能靠 Info.plist 判断：VS Code / Zed / VSCodium 确实声明了 `public.folder`，
    /// 但 JetBrains 全家和 Qt Creator 都没声明，实际却完全支持。
    /// 所以已知编辑器按内置知识写死，未知的才退回去看声明。
    var opensFolders: Bool
    /// 可选的额外参数。留空就是最朴素的"把路径交给这个 app 打开"。
    var argumentTemplate: String
    var isBuiltin: Bool
    /// 由「手动添加…」加进来的条目，重新扫描时不会被标准目录规则清掉。
    var isManual: Bool?

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }
    var version: String? { SRBundleInspector.version(at: url) }
}

// MARK: - 内置清单

extension SREditor {

    /// 已知编辑器。`folders` 表示能不能把目录当工程打开。
    static let recipes: [(id: String, name: String, folders: Bool)] = [
        // VS Code 系
        ("com.microsoft.VSCode", "Visual Studio Code", true),
        ("com.microsoft.VSCodeInsiders", "VS Code Insiders", true),
        ("com.vscodium", "VSCodium", true),
        ("com.todesktop.230313mzl4w4u92", "Cursor", true),
        ("com.exafunction.windsurf", "Windsurf", true),

        ("dev.zed.Zed", "Zed", true),
        ("com.sublimetext.4", "Sublime Text", true),
        ("com.sublimetext.3", "Sublime Text 3", true),
        ("com.panic.Nova", "Nova", true),
        ("com.barebones.bbedit", "BBEdit", true),

        // JetBrains 全家。都不声明 public.folder，但 open 一个目录就是开工程。
        ("com.jetbrains.intellij", "IntelliJ IDEA", true),
        ("com.jetbrains.intellij.ce", "IntelliJ IDEA CE", true),
        ("com.jetbrains.CLion", "CLion", true),
        ("com.jetbrains.rider", "Rider", true),
        ("com.jetbrains.datagrip", "DataGrip", true),
        ("com.jetbrains.rustrover", "RustRover", true),
        ("com.jetbrains.pycharm", "PyCharm", true),
        ("com.jetbrains.pycharm.ce", "PyCharm CE", true),
        ("com.jetbrains.WebStorm", "WebStorm", true),
        ("com.jetbrains.goland", "GoLand", true),
        ("com.jetbrains.PhpStorm", "PhpStorm", true),
        ("com.jetbrains.rubymine", "RubyMine", true),
        ("com.google.android.studio", "Android Studio", true),

        ("org.qt-project.qtcreator", "Qt Creator", true),

        // Xcode 打开裸目录的行为在各版本间不一致，默认按"仅文件"处理，
        // 需要的话用户可以在设置里自己打开。
        ("com.apple.dt.Xcode", "Xcode", false),

        // 纯文本编辑器：开文件很好用，开目录没意义。
        ("com.coteditor.CotEditor", "CotEditor", false),
        ("abnerworks.Typora", "Typora", false),
        ("com.apple.TextEdit", "TextEdit", false),
        ("org.gnu.Emacs", "Emacs", true),
        ("org.vim.MacVim", "MacVim", true),
    ]

    static func make(bundleID: String, name: String, path: String, opensFolders: Bool? = nil) -> SREditor {
        if let recipe = recipes.first(where: { $0.id == bundleID }) {
            return SREditor(id: bundleID,
                            name: recipe.name,
                            path: path,
                            opensFolders: recipe.folders,
                            argumentTemplate: "",
                            isBuiltin: true)
        }
        return SREditor(id: bundleID,
                        name: name,
                        path: path,
                        opensFolders: opensFolders ?? false,
                        argumentTemplate: "",
                        isBuiltin: false)
    }
}
