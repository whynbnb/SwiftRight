import AppKit
import Foundation

// MARK: - 启动方式

/// 各家终端的命令行约定完全不同，没有统一办法，只能一家一个配方。
enum SRTerminalLaunchStyle: String, Codable, CaseIterable {
    /// `open -a <App> <脚本>`。
    /// 适用于把 .command / public.shell-script 注册成自己能打开的终端，
    /// 比如系统自带的 Terminal 和 iTerm2。也是未知终端的兜底方式。
    case openScript
    /// `open -na <App> --args <展开后的参数>`。
    /// 现代终端（kitty / WezTerm / Ghostty / rio / Alacritty）都走这条。
    case arguments

    var displayName: String {
        switch self {
        case .openScript: return L("用脚本文件打开")
        case .arguments: return L("传命令行参数")
        }
    }
}

// MARK: - 终端

struct SRTerminal: Codable, Identifiable, Hashable {

    /// bundle identifier，同时用作列表里的唯一键。
    var id: String
    var name: String
    var path: String
    var launchStyle: SRTerminalLaunchStyle
    /// `.arguments` 模式下的参数模板。可用占位符：
    /// `{dir}` 工作目录、`{shell}` 解释器、`{script}` 生成的脚本路径。
    var argumentTemplate: String
    /// 来自内置配方（而非扫描出来的未知应用 / 手动添加）。
    var isBuiltin: Bool
    /// 由「手动添加…」加进来的条目。自动扫描只处理标准应用目录，
    /// 手动添加的位置不受限制，重新扫描时也不会被清掉。
    var isManual: Bool?

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    var version: String? {
        guard let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// 把模板展开成 argv。
    ///
    /// 关键点：先按空格切词、再在每个词内部替换占位符。
    /// 反过来做的话，工作目录里只要有空格就会被拆成两个参数。
    func arguments(script: String, directory: String, shell: String) -> [String] {
        argumentTemplate
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { token in
                String(token)
                    .replacingOccurrences(of: "{dir}", with: directory)
                    .replacingOccurrences(of: "{shell}", with: shell)
                    .replacingOccurrences(of: "{script}", with: script)
            }
    }
}

// MARK: - 内置配方

extension SRTerminal {

    /// 已知终端的启动配方。参数都是照着各家 `--help` 核实过的，不是猜的。
    ///
    /// 这里同时充当扫描时的"已知 bundle ID 清单"。
    static let recipes: [(id: String, name: String, style: SRTerminalLaunchStyle, template: String)] = [
        // 系统自带。.command 文件双击即由它接管，所以走脚本方式最省事。
        ("com.apple.Terminal", "Terminal", .openScript, ""),
        ("com.googlecode.iterm2", "iTerm2", .openScript, ""),

        // kitty：-d/--working-directory，其后跟要执行的程序。
        ("net.kovidgoyal.kitty", "kitty", .arguments,
         "--directory {dir} {shell} {script}"),

        // WezTerm：子命令 start，PROG 要放在 -- 之后。
        ("com.github.wez.wezterm", "WezTerm", .arguments,
         "start --cwd {dir} -- {shell} {script}"),

        // Ghostty：官方文档明确说 macOS 上必须用 open -na，-e 后接命令。
        ("com.mitchellh.ghostty", "Ghostty", .arguments,
         "--working-directory={dir} -e {shell} {script}"),

        // rio：-w/--working-dir，-e 必须是最后一个参数。
        ("com.raphaelamorim.rio", "Rio", .arguments,
         "--working-dir {dir} -e {shell} {script}"),

        // Alacritty：同 rio，-e 必须最后。
        ("org.alacritty", "Alacritty", .arguments,
         "--working-directory {dir} -e {shell} {script}"),

        ("co.zeit.hyper", "Hyper", .openScript, ""),
        ("org.tabby", "Tabby", .openScript, ""),
        ("com.termius-dmg.mac", "Termius", .openScript, ""),

        // 下面几个以 SSH 远程为主，本地执行能力不一定有。
        // 扫到了就列出来，但只能用兜底的脚本方式，能不能用要靠"测试"按钮验证。
        ("app.termora", "Termora", .openScript, ""),
        ("cn.xterminal.www", "XTerminal", .openScript, ""),
        ("cn.sshterm.pro", "SSH Term Pro", .openScript, ""),
        ("app.sshpilot", "SSHPilot", .openScript, ""),
        ("com.netcatty.app", "Netcatty", .openScript, ""),
    ]

    /// 按 bundle ID 取配方；没有就返回兜底的脚本方式。
    static func make(bundleID: String, name: String, path: String) -> SRTerminal {
        if let recipe = recipes.first(where: { $0.id == bundleID }) {
            return SRTerminal(id: bundleID,
                              name: recipe.name,
                              path: path,
                              launchStyle: recipe.style,
                              argumentTemplate: recipe.template,
                              isBuiltin: true)
        }
        return SRTerminal(id: bundleID,
                          name: name,
                          path: path,
                          launchStyle: .openScript,
                          argumentTemplate: "",
                          isBuiltin: false)
    }
}
