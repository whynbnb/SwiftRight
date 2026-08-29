import AppKit
import UserNotifications

/// 真正执行命令的地方。
///
/// 必须待在主 App 里：Finder 扩展是强制沙盒的，在那边 `Process` 起不了外部程序。
final class SRCommandRunner: ObservableObject {

    static let shared = SRCommandRunner()

    /// 最近的执行记录，新的在前。
    @Published private(set) var sessions: [SRRunSession] = []
    /// 需要被输出窗口展示的会话。
    @Published var focusedSession: SRRunSession?

    private let historyLimit = 50

    private init() {}

    // MARK: - 入口

    /// 执行一条命令。`onNeedsOutputWindow` 由调用方决定怎么把窗口开出来。
    func run(command: SRCommand,
             paths: [String],
             targetPath: String?,
             onNeedsOutputWindow: @escaping () -> Void) {

        guard !paths.isEmpty else { return }

        if command.confirmBeforeRun, !confirm(command: command, paths: paths) {
            return
        }

        // runOncePerItem：每个选中项各起一次进程，互不影响。
        let batches: [[String]] = command.runOncePerItem ? paths.map { [$0] } : [paths]

        for batch in batches {
            let context = SRPlaceholder.Context(paths: batch, targetPath: targetPath)
            let script = SRPlaceholder.expand(command.script, context: context)
            let workDir = resolveWorkingDirectory(command: command, context: context)

            switch command.runMode {
            case .terminal:
                launchInTerminal(command: command, script: script, workDir: workDir, context: context)
            case .background, .captureOutput:
                let session = SRRunSession(commandID: command.id,
                                           title: command.title,
                                           resolvedScript: script,
                                           workingDirectory: workDir,
                                           paths: batch,
                                           targetPath: targetPath)
                record(session)
                if command.runMode == .captureOutput {
                    focusedSession = session
                    onNeedsOutputWindow()
                }
                spawn(command: command,
                      script: script,
                      workDir: workDir,
                      context: context,
                      session: session,
                      onNeedsOutputWindow: onNeedsOutputWindow)
            }
        }
    }

    /// 编辑器里的「试运行」：强制捕获输出，不管命令本身配的是什么模式。
    func testRun(command: SRCommand, paths: [String], onNeedsOutputWindow: @escaping () -> Void) {
        var probe = command
        probe.runMode = .captureOutput
        probe.confirmBeforeRun = false
        probe.runOncePerItem = false
        let target = paths.first.map { ($0 as NSString).deletingLastPathComponent }
        run(command: probe,
            paths: paths,
            targetPath: target,
            onNeedsOutputWindow: onNeedsOutputWindow)
    }

    // MARK: - 进程

    private func spawn(command: SRCommand,
                       script: String,
                       workDir: String,
                       context: SRPlaceholder.Context,
                       session: SRRunSession,
                       onNeedsOutputWindow: @escaping () -> Void) {

        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: workDir, isDirectory: true)
        process.environment = environment(for: context)

        do {
            try configureExecutable(process, command: command, script: script, paths: context.paths)
        } catch {
            session.finish(exitCode: nil, failureReason: error.localizedDescription)
            return
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        // readabilityHandler 边读边收，避免管道缓冲区写满把子进程卡死。
        stdout.fileHandleForReading.readabilityHandler = { handle in
            session.append(handle.availableData, from: .standardOutput)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            session.append(handle.availableData, from: .standardError)
        }

        let didTimeOut = SRFlag()
        process.terminationHandler = { proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            // 收尾：handler 停掉后管道里可能还有残留。
            if let rest = try? stdout.fileHandleForReading.readToEnd() {
                session.append(rest, from: .standardOutput)
            }
            if let rest = try? stderr.fileHandleForReading.readToEnd() {
                session.append(rest, from: .standardError)
            }

            session.finish(exitCode: proc.terminationStatus, timedOut: didTimeOut.value)

            DispatchQueue.main.async {
                self.handleCompletion(command: command,
                                      session: session,
                                      onNeedsOutputWindow: onNeedsOutputWindow)
            }
        }

        do {
            try process.run()
            session.attach(process)
        } catch {
            session.finish(exitCode: nil, failureReason: L("无法启动：") + error.localizedDescription)
            return
        }

        if command.timeoutSeconds > 0 {
            let deadline = DispatchTime.now() + .seconds(command.timeoutSeconds)
            DispatchQueue.global().asyncAfter(deadline: deadline) { [weak process] in
                guard let process, process.isRunning else { return }
                didTimeOut.value = true
                process.terminate()
            }
        }
    }

    /// 脚本以 `#!` 开头时落成临时可执行文件，由内核按 shebang 分发；
    /// 否则交给命令自己配置的解释器。两种情况下选中的路径都会作为 `$1 $2 …` 传进去，
    /// 所以脚本里写 `"$@"` 和写 `{paths}` 是等价的。
    private func configureExecutable(_ process: Process,
                                     command: SRCommand,
                                     script: String,
                                     paths: [String]) throws {
        if script.hasPrefix("#!") {
            SRPaths.ensureDirectories()
            let file = SRPaths.scratchDirectory
                .appendingPathComponent("run-\(UUID().uuidString).sh")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            process.executableURL = file
            process.arguments = paths
        } else {
            let shell = command.shell.isEmpty ? "/bin/zsh" : command.shell
            guard FileManager.default.isExecutableFile(atPath: shell) else {
                throw NSError(domain: "SwiftRight", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: L("解释器不存在或不可执行：") + shell
                ])
            }
            process.executableURL = URL(fileURLWithPath: shell)
            // "swiftright" 占掉 $0，选中的路径才会落在 $1 起。
            process.arguments = command.shellArguments + [script, "swiftright"] + paths
        }
    }

    // MARK: - 终端模式

    private func launchInTerminal(command: SRCommand,
                                  script: String,
                                  workDir: String,
                                  context: SRPlaceholder.Context) {
        SRPaths.ensureDirectories()
        // 标题是用户随便填的，可能带 `/` 或者超长，不能直接拿来当文件名。
        let safeTitle = command.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\u{0}"))
            .joined(separator: "-")
            .prefix(40)
        let file = SRPaths.scratchDirectory
            .appendingPathComponent("SwiftRight-\(safeTitle)-\(UUID().uuidString.prefix(8)).command")

        var exports = ""
        for (key, value) in environment(for: context) where key.hasPrefix("SR_") {
            exports += "export \(key)=\(value.shellQuoted)\n"
        }

        let shell = command.shell.isEmpty ? "/bin/zsh" : command.shell

        // 现代终端（kitty / WezTerm / Ghostty / rio / Alacritty）用 -e 方式启动时，
        // 命令一退出窗口就跟着关。`ls` 这种秒完的命令会一闪而过，等于什么都没看见。
        // 所以默认在末尾接一个交互式 shell 把窗口留住，顺便报出退出码。
        let tail = SRPreferences.shared.keepTerminalOpen ? """


        __sr_status=$?
        echo
        echo "[SwiftRight] exit $__sr_status"
        exec "$SHELL" -i
        """ : ""

        let body = """
        #!\(shell)
        cd \(workDir.shellQuoted)
        \(exports)
        \(script)\(tail)
        """

        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            presentError(L("无法生成终端脚本：") + error.localizedDescription)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        guard let terminal = SRTerminalCatalog.shared.selected, terminal.exists else {
            // 一个终端都没有的机器不存在，但配置被删空是可能的，退回系统 Terminal。
            openWithSystemTerminal(file, configuration: configuration)
            return
        }
        launch(terminal: terminal, scriptAt: file, workDir: workDir,
               shell: shell, configuration: configuration)
    }

    /// 按终端自己的配方把脚本跑起来。
    ///
    /// 两种方式的差别不只是参数：`.openScript` 是把脚本当文档交给应用打开，
    /// `.arguments` 是新起一个实例并把命令行传进去。现代终端只认后者。
    private func launch(terminal: SRTerminal,
                        scriptAt file: URL,
                        workDir: String,
                        shell: String,
                        configuration: NSWorkspace.OpenConfiguration) {

        let onError: (Error?) -> Void = { error in
            guard let error else { return }
            DispatchQueue.main.async {
                self.presentError(L("无法启动终端：") + error.localizedDescription)
            }
        }

        switch terminal.launchStyle {
        case .openScript:
            NSWorkspace.shared.open([file],
                                    withApplicationAt: terminal.url,
                                    configuration: configuration) { _, error in onError(error) }

        case .arguments:
            configuration.arguments = terminal.arguments(script: file.path,
                                                         directory: workDir,
                                                         shell: shell)
            // createsNewApplicationInstance 对应 `open -n`。
            // 不加的话，终端已经开着时参数会被直接丢弃，什么都不会发生。
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: terminal.url,
                                               configuration: configuration) { _, error in
                onError(error)
            }
        }
    }

    private func openWithSystemTerminal(_ file: URL,
                                        configuration: NSWorkspace.OpenConfiguration) {
        if let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) {
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration)
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    /// 设置里的「测试」：拿这一项自己的配方开一个终端，跑一句能一眼看出成败的命令。
    func testTerminal(_ terminal: SRTerminal) {
        SRPaths.ensureDirectories()
        let file = SRPaths.scratchDirectory
            .appendingPathComponent("SwiftRight-test-\(UUID().uuidString.prefix(8)).command")
        // 这里不看 keepTerminalOpen 设置：测试的全部意义就是让人看见输出，
        // 窗口一闪而过等于没测。
        let body = """
        #!/bin/zsh
        echo "SwiftRight → \(terminal.name)"
        echo "\(L("工作目录")): $PWD"
        echo
        echo "\(L("看到这段文字说明这个终端的启动配方是对的。"))"
        echo
        exec "$SHELL" -i
        """
        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: file.path)
        } catch {
            presentError(L("无法生成终端脚本：") + error.localizedDescription)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        launch(terminal: terminal,
               scriptAt: file,
               workDir: SRPaths.realHome.path,
               shell: "/bin/zsh",
               configuration: configuration)
    }

    // MARK: - 环境与工作目录

    private func environment(for context: SRPlaceholder.Context) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // GUI 进程继承到的 PATH 通常很窄，补上常见的包管理器目录，
        // 否则 brew 装的工具在脚本里会 command not found。
        let extras = ["/opt/homebrew/bin", "/opt/homebrew/sbin",
                      "/usr/local/bin", "/usr/local/sbin",
                      "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var pathParts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for extra in extras where !pathParts.contains(extra) {
            pathParts.append(extra)
        }
        env["PATH"] = pathParts.joined(separator: ":")

        let first = context.firstPath
        let name = (first as NSString).lastPathComponent
        env["SR_PATH"] = first
        env["SR_PATHS"] = context.paths.joined(separator: "\n")
        env["SR_DIR"] = context.parentDirectory
        env["SR_TARGET"] = context.targetPath ?? context.parentDirectory
        env["SR_NAME"] = name
        env["SR_BASENAME"] = (name as NSString).deletingPathExtension
        env["SR_EXT"] = (name as NSString).pathExtension
        env["SR_COUNT"] = String(context.paths.count)
        env["SR_HOME"] = SRPaths.realHome.path
        return env
    }

    private func resolveWorkingDirectory(command: SRCommand, context: SRPlaceholder.Context) -> String {
        let fm = FileManager.default
        let candidate: String

        switch command.workingDirectory {
        case .selectionParent:
            candidate = context.parentDirectory
        case .selectionItself:
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: context.firstPath, isDirectory: &isDir), isDir.boolValue {
                candidate = context.firstPath
            } else {
                candidate = context.parentDirectory
            }
        case .targetFolder:
            candidate = context.targetPath ?? context.parentDirectory
        case .custom:
            // 这里展开出来的东西要直接当路径用，绝不能带 shell 引号。
            candidate = SRPlaceholder.expand(command.customWorkingDirectory,
                                             context: context,
                                             quoting: false)
        }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
            return candidate
        }
        return SRPaths.realHome.path
    }

    // MARK: - 收尾

    private func handleCompletion(command: SRCommand,
                                  session: SRRunSession,
                                  onNeedsOutputWindow: @escaping () -> Void) {
        let failed = !session.succeeded

        if command.notifyOnFinish {
            notify(title: command.title,
                   body: failed ? L("执行失败（%@）", session.statusText) : L("执行完成"))
        }

        // 后台命令失败时如果什么都不提示，用户根本不知道出了事。
        if failed, command.runMode == .background, SRPreferences.shared.openOutputOnFailure {
            focusedSession = session
            onNeedsOutputWindow()
        }
    }

    /// `run()` 只会在主线程被调用（AppDelegate 的 URL 回调、SwiftUI 的按钮）。
    /// 这里同步插入，输出窗口才不会先看到一个空列表再补上。
    private func record(_ session: SRRunSession) {
        dispatchPrecondition(condition: .onQueue(.main))
        sessions.insert(session, at: 0)
        if sessions.count > historyLimit {
            sessions.removeLast(sessions.count - historyLimit)
        }
    }

    func clearHistory() {
        sessions.removeAll { !$0.isRunning }
    }

    // MARK: - 提示

    private func confirm(command: SRCommand, paths: [String]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("确定要执行「%@」吗？", command.title)
        alert.informativeText = paths.count == 1
            ? paths[0]
            : L("将作用于 %@ 个项目：", String(paths.count)) + "\n"
                + paths.prefix(5).map { ($0 as NSString).lastPathComponent }
                    .joined(separator: "\n")
                + (paths.count > 5 ? "\n…" : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("执行"))
        alert.addButton(withTitle: L("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "SwiftRight"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: nil)
            center.add(request)
        }
    }
}

/// App 自身的偏好键（不与扩展共享，所以放 UserDefaults 就够了）。
enum SRDefaults {
    static let openOutputOnFailure = "openOutputOnFailure"
}

/// 跨线程共享的一个布尔位。
///
/// 超时定时器和 `terminationHandler` 分别跑在不同队列上，
/// 直接捕获局部 `var` 在并发检查下是数据竞争。
final class SRFlag {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
