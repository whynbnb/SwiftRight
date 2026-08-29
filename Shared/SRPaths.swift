import Foundation

/// App（非沙盒）和 Finder 扩展（沙盒）都要读写同一份配置，
/// 所以路径必须绕开沙盒容器重定向，直接落到真实的 home 目录。
///
/// 扩展侧靠 FinderExtension.entitlements 里的
/// `com.apple.security.temporary-exception.files.home-relative-path.read-write`
/// 拿到 `~/Library/Application Support/SwiftRight/` 的读写权限。
enum SRPaths {

    /// 沙盒里 `NSHomeDirectory()` 返回的是容器路径，`getpwuid` 才是真实 home。
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// ~/Library/Application Support/SwiftRight/
    static var supportDirectory: URL {
        realHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("SwiftRight", isDirectory: true)
    }

    /// 命令与全局设置。
    static var configFile: URL {
        supportDirectory.appendingPathComponent("commands.json")
    }

    /// 扩展把「点了哪条命令 + 选中了哪些文件」写在这里，App 再来取。
    static var pendingDirectory: URL {
        supportDirectory.appendingPathComponent("pending", isDirectory: true)
    }

    /// `在终端中运行` 模式生成的临时 .command 脚本。
    static var scratchDirectory: URL {
        supportDirectory.appendingPathComponent("scratch", isDirectory: true)
    }

    /// 幂等地建好目录树。任何一次读写前调用都安全。
    @discardableResult
    static func ensureDirectories() -> Bool {
        let fm = FileManager.default
        for dir in [supportDirectory, pendingDirectory, scratchDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    return false
                }
            }
        }
        return true
    }

    /// URL scheme：swiftright://run?ticket=<uuid>
    static let urlScheme = "swiftright"
}
