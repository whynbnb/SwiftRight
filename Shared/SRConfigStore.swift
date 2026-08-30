import Foundation

/// commands.json 的读写。App 侧负责写，扩展侧只读。
///
/// 扩展的 `menu(for:)` 每次右键都会被调用，所以这里按 mtime 做缓存，
/// 没改动就不重复解析 JSON。
final class SRConfigStore {

    static let shared = SRConfigStore()

    private let queue = DispatchQueue(label: "me.whynbnb.configstore")
    private var cached: SRConfig?
    private var cachedModificationDate: Date?

    private init() {}

    // MARK: - 读

    /// 读取配置。文件不存在时返回内置的默认配置（不落盘）。
    func load() -> SRConfig {
        queue.sync {
            let url = SRPaths.configFile
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate

            if let cached, let cachedModificationDate, let mtime, mtime == cachedModificationDate {
                return cached
            }

            guard let data = try? Data(contentsOf: url) else {
                // 文件还不存在（App 从没运行过）。
                // 这里绝不能回退成 builtinExamples()：那批示例每次调用都是新 UUID，
                // 扩展拿它拼出来的菜单，主 App 按 ID 一个也查不到，点了就是没反应。
                // 宁可先不显示菜单，等 App 首次启动把配置写出来。
                let empty = SRConfig()
                cached = empty
                cachedModificationDate = nil
                return empty
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let config = try? decoder.decode(SRConfig.self, from: data) else {
                // 配置损坏时宁可给空菜单，也不要拿旧缓存误导用户。
                let empty = SRConfig()
                cached = empty
                cachedModificationDate = mtime
                return empty
            }

            cached = config
            cachedModificationDate = mtime
            return config
        }
    }

    // MARK: - 写

    func save(_ config: SRConfig) throws {
        try queue.sync {
            SRPaths.ensureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(config)
            try data.write(to: SRPaths.configFile, options: .atomic)
            cached = config
            cachedModificationDate = (try? SRPaths.configFile
                .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    /// 强制下次 load() 重新读盘。
    func invalidate() {
        queue.sync {
            cached = nil
            cachedModificationDate = nil
        }
    }

    var configFileExists: Bool {
        FileManager.default.fileExists(atPath: SRPaths.configFile.path)
    }
}

// MARK: - 内置示例

extension SRCommand {

    private static func make(
        _ title: String,
        symbol: String,
        group: String = "",
        script: String,
        runMode: SRRunMode = .background,
        appliesTo: SRSelectionKind = .any,
        workingDirectory: SRWorkingDirectory = .selectionParent,
        sortIndex: Int
    ) -> SRCommand {
        var c = SRCommand()
        c.title = title
        c.symbol = symbol
        c.group = group
        c.script = script
        c.runMode = runMode
        c.appliesTo = appliesTo
        c.workingDirectory = workingDirectory
        c.sortIndex = sortIndex
        return c
    }

    /// 首次启动时写入的示例命令，同时充当占位符用法的说明书。
    static func builtinExamples() -> [SRCommand] {
        var list: [SRCommand] = []

        list.append(make(
            "在终端中打开",
            symbol: "apple.terminal",
            group: "打开方式",
            script: "cd {dir} && exec $SHELL -l",
            runMode: .terminal,
            sortIndex: 0
        ))

        list.append(make(
            "用 VS Code 打开",
            symbol: "chevron.left.forwardslash.chevron.right",
            group: "打开方式",
            script: """
            if [ -d "/Applications/Visual Studio Code.app" ]; then
              open -a "Visual Studio Code" {paths}
            else
              echo "未安装 Visual Studio Code" >&2
              exit 1
            fi
            """,
            sortIndex: 1
        ))

        list.append(make(
            "拷贝路径",
            symbol: "doc.on.clipboard",
            // 用 {paths} 而不是 {paths:raw}：路径里可能有空格和单引号，
            // 不转义直接拼进脚本会把 shell 语法搞坏。
            // printf 会为每个参数重用一次格式串，多选时正好一行一个。
            script: "printf '%s\\n' {paths} | pbcopy",
            sortIndex: 2
        ))

        list.append(make(
            "拷贝文件名",
            symbol: "textformat.abc",
            script: "printf '%s\\n' {names} | pbcopy",
            sortIndex: 3
        ))

        list.append(make(
            "计算 SHA-256",
            symbol: "number.square",
            group: "检查",
            script: "shasum -a 256 {paths}",
            runMode: .captureOutput,
            appliesTo: .filesOnly,
            sortIndex: 4
        ))

        list.append(make(
            "统计占用空间",
            symbol: "internaldrive",
            group: "检查",
            script: "du -sh {paths} | sort -h",
            runMode: .captureOutput,
            sortIndex: 5
        ))

        var zip = make(
            "压缩为 zip",
            symbol: "archivebox",
            group: "转换",
            script: """
            cd {dir}
            zip -r -X {basename}.zip {names}
            """,
            runMode: .captureOutput,
            sortIndex: 6
        )
        zip.notifyOnFinish = true
        list.append(zip)

        var png = make(
            "转换为 PNG",
            symbol: "photo",
            group: "转换",
            script: "sips -s format png {path} --out {dir}/{basename}.png",
            runMode: .captureOutput,
            appliesTo: .filesOnly,
            sortIndex: 7
        )
        png.fileExtensions = ["jpg", "jpeg", "heic", "tiff", "bmp", "gif", "webp"]
        png.runOncePerItem = true
        png.notifyOnFinish = true
        list.append(png)

        var gitStatus = make(
            "git status",
            symbol: "arrow.triangle.branch",
            group: "Git",
            script: "git -C {target} status",
            runMode: .captureOutput,
            workingDirectory: .targetFolder,
            sortIndex: 8
        )
        gitStatus.allowsMultipleSelection = false
        list.append(gitStatus)

        return list
    }
}
