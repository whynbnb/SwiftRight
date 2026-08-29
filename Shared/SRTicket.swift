import Foundation

/// 扩展 → App 的一次性调用凭据。
///
/// 之所以不把路径直接塞进 URL：多选几十个长路径很容易把 URL 撑到不可控的长度，
/// 而且路径里的特殊字符做百分号编码容易出错。统一走文件更稳。
struct SRTicket: Codable {
    var id: UUID = UUID()
    var commandID: UUID
    /// 选中的文件 / 文件夹绝对路径。空白处右键时是当前文件夹本身。
    var paths: [String]
    /// 当前 Finder 窗口对应的文件夹。
    var targetPath: String?
    /// 是否来自窗口空白处的右键菜单。
    var isContainerMenu: Bool
    var createdAt: Date = Date()

    init(commandID: UUID, paths: [String], targetPath: String?, isContainerMenu: Bool) {
        self.commandID = commandID
        self.paths = paths
        self.targetPath = targetPath
        self.isContainerMenu = isContainerMenu
    }

    enum CodingKeys: String, CodingKey {
        case id, commandID, paths, targetPath, isContainerMenu, createdAt
    }
}

extension SRTicket {

    /// 写进 pending 目录并返回可以直接 open 的 URL。
    static func write(_ ticket: SRTicket) throws -> URL {
        SRPaths.ensureDirectories()
        let file = SRPaths.pendingDirectory.appendingPathComponent("\(ticket.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ticket).write(to: file, options: .atomic)

        var comps = URLComponents()
        comps.scheme = SRPaths.urlScheme
        comps.host = "run"
        comps.queryItems = [URLQueryItem(name: "ticket", value: ticket.id.uuidString)]
        guard let url = comps.url else {
            throw NSError(domain: "SwiftRight", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法构造回调 URL"])
        }
        return url
    }

    /// App 侧读取并立刻删除，保证凭据只用一次。
    static func consume(id: UUID) -> SRTicket? {
        let file = SRPaths.pendingDirectory.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SRTicket.self, from: data)
    }

    /// 清理超过 10 分钟没人认领的凭据（比如 App 启动失败留下的垃圾）。
    static func pruneStale() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: SRPaths.pendingDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-600)
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}
