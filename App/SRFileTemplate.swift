import Foundation

/// 新建文件的模板。
///
/// 生成出来的是一条普通的后台命令，脚本用 heredoc 把内容写进去 ——
/// 不需要新的运行方式，也不用给 SRCommand 加字段，用户还能直接看懂和修改。
struct SRFileTemplate: Codable, Identifiable, Hashable {

    var id: UUID = UUID()
    /// 菜单里显示的名字，如「Markdown」。
    var name: String = ""
    /// 新建时的默认主文件名，不含扩展名。
    var defaultName: String = ""
    /// 扩展名，不含点。留空则不加扩展名。
    var fileExtension: String = ""
    /// 文件初始内容。空字符串就是空文件。
    var content: String = ""
    /// SF Symbol。
    var symbol: String = "doc.text"
    /// 建完给个可执行位。脚本类模板需要。
    var isExecutable: Bool = false
    var sortIndex: Int = 0

    init() {}

    enum CodingKeys: String, CodingKey {
        case id, name, defaultName, fileExtension, content, symbol, isExecutable, sortIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        defaultName = try c.decodeIfPresent(String.self, forKey: .defaultName) ?? ""
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "doc.text"
        isExecutable = try c.decodeIfPresent(Bool.self, forKey: .isExecutable) ?? false
        sortIndex = try c.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
    }

    /// 带点的完整后缀，供界面展示。
    var displayExtension: String {
        fileExtension.isEmpty ? "" : ".\(fileExtension)"
    }
}

// MARK: - 脚本生成

extension SRFileTemplate {

    /// 写在脚本首行的标记，用来认出"这条命令是哪个模板生成的"。
    ///
    /// 不靠脚本全文比对：用户改了模板内容之后全文就对不上了，
    /// 而这个标记跟着模板 id 走，改内容也认得出来。
    var marker: String { "# swiftright-template: \(id.uuidString)" }

    static func markerPrefix(for id: UUID) -> String {
        "# swiftright-template: \(id.uuidString)"
    }

    /// heredoc 的结束标记。用足够独特的字符串，避免和模板内容里的行撞上。
    private static let heredocDelimiter = "SWIFTRIGHT_TEMPLATE_EOF"

    /// 生成完整脚本。
    ///
    /// 重名处理：`未命名.md` 被占了就试 `未命名 2.md`、`未命名 3.md`，
    /// 和访达自己的行为一致。
    func generatedScript() -> String {
        let base = defaultName.isEmpty ? "untitled" : defaultName
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"

        var lines: [String] = []
        lines.append(marker)
        // {path} 就是右键所在的文件夹：空白处右键时它是当前窗口的文件夹，
        // 选中文件夹时它是那个文件夹本身。
        lines.append("dir={path}")
        lines.append("target=\"$dir/\(base)\(suffix)\"")
        lines.append("n=2")
        lines.append("while [ -e \"$target\" ]; do")
        lines.append("  target=\"$dir/\(base) $n\(suffix)\"")
        lines.append("  n=$((n + 1))")
        lines.append("done")
        lines.append("")

        if content.isEmpty {
            lines.append(": > \"$target\"")
        } else {
            // 单引号包住结束标记 = heredoc 里不做任何展开，
            // 模板内容里的 $ ` \ 都会原样落盘。
            lines.append("cat > \"$target\" <<'\(Self.heredocDelimiter)'")
            lines.append(content)
            lines.append(Self.heredocDelimiter)
        }

        if isExecutable {
            lines.append("chmod +x \"$target\"")
        }

        lines.append("")
        lines.append("# 在访达里选中刚建好的文件，按 Return 即可改名。")
        lines.append("open -R \"$target\"")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 内置模板

extension SRFileTemplate {

    private static func make(_ name: String,
                             defaultName: String,
                             ext: String,
                             symbol: String,
                             content: String = "",
                             executable: Bool = false,
                             index: Int) -> SRFileTemplate {
        var t = SRFileTemplate()
        t.name = name
        t.defaultName = defaultName
        t.fileExtension = ext
        t.symbol = symbol
        t.content = content
        t.isExecutable = executable
        t.sortIndex = index
        return t
    }

    /// 首次运行时装进模板库的一批。纯文本排第一 —— 那是最常用的一个。
    static func builtins() -> [SRFileTemplate] {
        let untitled = L("未命名")
        var list: [SRFileTemplate] = []

        list.append(make(L("纯文本"), defaultName: untitled, ext: "txt",
                         symbol: "doc.plaintext", index: 0))

        list.append(make("Markdown", defaultName: untitled, ext: "md",
                         symbol: "doc.richtext",
                         content: "# \(L("标题"))\n\n", index: 1))

        list.append(make("JSON", defaultName: untitled, ext: "json",
                         symbol: "curlybraces",
                         content: "{\n  \n}\n", index: 2))

        list.append(make("HTML", defaultName: "index", ext: "html",
                         symbol: "chevron.left.forwardslash.chevron.right",
                         content: """
                         <!DOCTYPE html>
                         <html lang="zh-CN">
                         <head>
                           <meta charset="UTF-8">
                           <meta name="viewport" content="width=device-width, initial-scale=1">
                           <title>\(L("文档"))</title>
                         </head>
                         <body>

                         </body>
                         </html>
                         """, index: 3))

        list.append(make("CSS", defaultName: "style", ext: "css",
                         symbol: "paintbrush",
                         content: ":root {\n  \n}\n", index: 4))

        list.append(make("JavaScript", defaultName: untitled, ext: "js",
                         symbol: "curlybraces.square", index: 5))

        list.append(make("YAML", defaultName: untitled, ext: "yaml",
                         symbol: "list.bullet.indent", index: 6))

        list.append(make("XML", defaultName: untitled, ext: "xml",
                         symbol: "chevron.left.slash.chevron.right",
                         content: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n", index: 7))

        list.append(make(L("Shell 脚本"), defaultName: "script", ext: "sh",
                         symbol: "terminal",
                         content: "#!/bin/zsh\nset -euo pipefail\n\n",
                         executable: true, index: 8))

        list.append(make("Python", defaultName: untitled, ext: "py",
                         symbol: "chevron.left.forwardslash.chevron.right",
                         content: "#!/usr/bin/env python3\n\n\ndef main() -> None:\n    pass\n\n\n"
                                  + "if __name__ == \"__main__\":\n    main()\n",
                         executable: true, index: 9))

        return list
    }
}
