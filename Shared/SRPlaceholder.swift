import Foundation

/// 脚本占位符替换。
///
/// 默认所有替换结果都会做 shell 单引号转义，路径里有空格、引号、`$` 都不会出问题。
/// 需要原始文本（比如拼进字符串或者传给 `printf`）时加 `:raw` 后缀。
///
/// 可用占位符：
/// - `{path}`      第一个选中项的绝对路径
/// - `{paths}`     全部选中项，空格分隔
/// - `{name}`      第一个选中项的文件名（含扩展名）
/// - `{names}`     全部选中项的文件名
/// - `{basename}`  第一个选中项的文件名（不含扩展名）
/// - `{ext}`       第一个选中项的扩展名（不含点）
/// - `{dir}`       第一个选中项所在的文件夹
/// - `{target}`    当前 Finder 窗口对应的文件夹
/// - `{count}`     选中项数量
/// - `{home}`      用户主目录
/// - `{date}`      当前时间戳，格式 yyyyMMdd-HHmmss
enum SRPlaceholder {

    /// 一次替换所需的全部上下文。
    struct Context {
        var paths: [String]
        var targetPath: String?

        init(paths: [String], targetPath: String? = nil) {
            self.paths = paths
            self.targetPath = targetPath
        }

        var firstPath: String { paths.first ?? "" }

        var parentDirectory: String {
            guard let first = paths.first else { return targetPath ?? SRPaths.realHome.path }
            return (first as NSString).deletingLastPathComponent
        }
    }

    /// 面向用户的占位符清单，供编辑器界面展示。
    static let reference: [(token: String, detail: String)] = [
        ("{path}", "第一个选中项的完整路径"),
        ("{paths}", "全部选中项，空格分隔"),
        ("{name}", "文件名（含扩展名）"),
        ("{names}", "全部文件名"),
        ("{basename}", "文件名（不含扩展名）"),
        ("{ext}", "扩展名，不含点"),
        ("{dir}", "所在文件夹"),
        ("{target}", "当前 Finder 窗口文件夹"),
        ("{count}", "选中项数量"),
        ("{home}", "用户主目录"),
        ("{date}", "时间戳 yyyyMMdd-HHmmss"),
    ]

    private static let pattern = try! NSRegularExpression(
        pattern: "\\{([a-zA-Z]+)(:raw)?\\}"
    )

    /// 单次扫描完成替换。不会对替换结果二次展开，所以文件名里出现 `{path}`
    /// 这种字面量也不会被再解释一遍。
    ///
    /// - Parameter quoting: 是否对替换结果做 shell 转义。拼脚本时要开；
    ///   展开工作目录这类"直接当路径用"的字段时必须关，
    ///   否则 `{home}/Desktop` 会变成 `'/Users/x'/Desktop`。
    static func expand(_ template: String, context: Context, quoting: Bool = true) -> String {
        let ns = template as NSString
        let matches = pattern.matches(in: template, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return template }

        var result = ""
        var cursor = 0

        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length

            let token = ns.substring(with: match.range(at: 1))
            let isRaw = !quoting || match.range(at: 2).location != NSNotFound

            if let value = value(for: token, context: context, raw: isRaw) {
                result += value
            } else {
                // 不认识的占位符原样保留，避免悄悄吞掉用户写的内容。
                result += ns.substring(with: match.range)
            }
        }

        result += ns.substring(from: cursor)
        return result
    }

    private static func value(for token: String, context: Context, raw: Bool) -> String? {
        let first = context.firstPath
        let name = (first as NSString).lastPathComponent

        func one(_ s: String) -> String { raw ? s : s.shellQuoted }
        func many(_ list: [String]) -> String {
            raw ? list.joined(separator: " ") : list.map(\.shellQuoted).joined(separator: " ")
        }

        switch token.lowercased() {
        case "path":
            return one(first)
        case "paths":
            return many(context.paths)
        case "name":
            return one(name)
        case "names":
            return many(context.paths.map { ($0 as NSString).lastPathComponent })
        case "basename":
            return one((name as NSString).deletingPathExtension)
        case "ext":
            return one((name as NSString).pathExtension)
        case "dir":
            return one(context.parentDirectory)
        case "target":
            return one(context.targetPath ?? context.parentDirectory)
        case "count":
            return String(context.paths.count)
        case "home":
            return one(SRPaths.realHome.path)
        case "date":
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            return one(fmt.string(from: Date()))
        default:
            return nil
        }
    }
}

extension String {
    /// POSIX shell 单引号转义。单引号本身用 `'\''` 的方式闭合再拼接。
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
