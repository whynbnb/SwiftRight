import Foundation

/// 增量 UTF-8 解码。
///
/// 管道是按块给数据的，一个中文字符（3 字节）完全可能被切在两个块里。
/// 直接对每块 `String(decoding:)` 会在断点处吐出 U+FFFD，中文输出必然乱码。
/// 这里把尾部不完整的序列留到下一块再解。
final class SRUTF8Decoder {

    private var buffer = Data()

    func feed(_ data: Data) -> String {
        buffer.append(data)
        guard !buffer.isEmpty else { return "" }

        let cut = completePrefixLength()
        guard cut > 0 else { return "" }

        let head = buffer.prefix(cut)
        buffer.removeFirst(cut)
        return String(decoding: head, as: UTF8.self)
    }

    /// 冲掉残留。进程结束后调用，避免最后几个字节被静默丢弃。
    func flush() -> String {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? "" : String(decoding: buffer, as: UTF8.self)
    }

    /// 从尾部往回最多看 3 个字节，找到最后一个序列首字节；
    /// 如果它要求的长度超过了剩余字节数，就把这段留下。
    private func completePrefixLength() -> Int {
        let count = buffer.count
        var offset = 1
        while offset <= 4, offset <= count {
            let byte = buffer[buffer.startIndex + count - offset]
            if byte & 0b1100_0000 != 0b1000_0000 {
                // 找到首字节了。
                let expected = Self.sequenceLength(byte)
                return offset < expected ? count - offset : count
            }
            offset += 1
        }
        // 连着 4 个以上的续字节，本身就是坏数据，整段交出去让替换字符去表示。
        return count
    }

    private static func sequenceLength(_ byte: UInt8) -> Int {
        switch byte {
        case 0x00...0x7F: return 1
        case 0xC0...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF7: return 4
        default: return 1
        }
    }
}

/// 一次命令执行的可观察状态。输出窗口直接绑定它。
final class SRRunSession: ObservableObject, Identifiable {

    enum Stream { case standardOutput, standardError }

    let id = UUID()
    let commandID: UUID
    let title: String
    /// 占位符展开后的最终脚本，方便用户核对到底跑了什么。
    let resolvedScript: String
    let workingDirectory: String
    /// 这次执行作用到的路径，用于展示和排查。
    let paths: [String]
    let targetPath: String?
    let startedAt = Date()

    @Published private(set) var output: String = ""
    @Published private(set) var isRunning: Bool = true
    @Published private(set) var exitCode: Int32?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var failureReason: String?
    @Published private(set) var timedOut: Bool = false

    private var process: Process?

    /// stdout / stderr 各有各的读取队列，缓冲区必须分开，
    /// 混在一起会把两条流的字节交错成无效序列。
    private let lock = NSLock()
    private let outDecoder = SRUTF8Decoder()
    private let errDecoder = SRUTF8Decoder()

    /// 输出上限，防止 `find /` 这类命令把内存吃光。
    private let outputLimit = 512 * 1024
    /// 每次 append 都算一遍 `output.utf8.count` 是 O(n²)，这里自己记账。
    private var outputBytes = 0
    private var truncated = false

    init(commandID: UUID,
         title: String,
         resolvedScript: String,
         workingDirectory: String,
         paths: [String],
         targetPath: String?) {
        self.commandID = commandID
        self.title = title
        self.resolvedScript = resolvedScript
        self.workingDirectory = workingDirectory
        self.paths = paths
        self.targetPath = targetPath
    }

    var succeeded: Bool { exitCode == 0 && failureReason == nil }

    var duration: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var statusText: String {
        if isRunning { return "运行中…" }
        if timedOut { return "超时中止" }
        if let failureReason { return failureReason }
        if let exitCode {
            return exitCode == 0 ? "完成" : "退出码 \(exitCode)"
        }
        return "已结束"
    }

    // MARK: - 输出

    func attach(_ process: Process) {
        self.process = process
    }

    func append(_ data: Data, from stream: Stream) {
        guard !data.isEmpty else { return }
        lock.lock()
        let text = (stream == .standardOutput ? outDecoder : errDecoder).feed(data)
        lock.unlock()
        appendText(text)
    }

    /// 把两条流里残留的字节冲出来。
    func flushStreams() {
        lock.lock()
        let text = outDecoder.flush() + errDecoder.flush()
        lock.unlock()
        appendText(text)
    }

    func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            guard !self.truncated else { return }
            let incoming = text.utf8.count
            if self.outputBytes + incoming > self.outputLimit {
                let room = max(0, self.outputLimit - self.outputBytes)
                self.output += String(text.prefix(room))
                self.output += "\n\n… 输出过长，已截断 …\n"
                self.truncated = true
            } else {
                self.output += text
                self.outputBytes += incoming
            }
        }
    }

    // MARK: - 生命周期

    func finish(exitCode: Int32?, failureReason: String? = nil, timedOut: Bool = false) {
        flushStreams()
        DispatchQueue.main.async {
            guard self.isRunning else { return }
            self.isRunning = false
            self.exitCode = exitCode
            self.failureReason = failureReason
            self.timedOut = timedOut
            self.finishedAt = Date()
            self.process = nil
        }
    }

    func cancel() {
        guard isRunning, let process, process.isRunning else { return }
        process.terminate()
        // SIGTERM 不理会的话补一刀。
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            kill(pid, SIGKILL)
        }
        finish(exitCode: nil, failureReason: "已取消")
    }
}
