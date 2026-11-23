import AppKit
import SwiftUI

struct SRCommandEditorView: View {

    @Binding var command: SRCommand
    @EnvironmentObject private var model: SRAppModel
    @ObservedObject private var catalog = SRTerminalCatalog.shared

    @State private var pendingInsertion: String?
    @State private var extensionsText: String = ""
    @State private var isCustomShell = false

    private static let knownShells = [
        "/bin/zsh", "/bin/bash", "/bin/sh",
        "/usr/bin/python3", "/usr/bin/perl", "/usr/bin/ruby", "/usr/bin/osascript",
    ]

    var body: some View {
        // 详情列可能很宽（侧栏折叠后接近整个窗口），也可能很窄。
        // 宽度够时排成两列：左边基本信息和高级，右边运行设置；脚本单独
        // 占满一整行放在下面。窄了就按「基本 → 高级 → 运行 → 脚本」单列排。
        GeometryReader { proxy in
            ScrollView {
                Group {
                    if proxy.size.width >= 900 {
                        twoColumnForm
                    } else {
                        singleColumnForm
                    }
                }
                .padding(20)
                .frame(maxWidth: 1040, alignment: .leading)
            }
            // macOS 26 的 scroll edge effect 会在标题栏下方糊出一条矩形，
            // 鼠标移进去才明显。这里内容本身就是卡片化的，不需要这层模糊。
            .modifier(SRHideScrollEdgeEffect())
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: syncLocalState)
        .onChange(of: command.id) { syncLocalState() }
        .onChange(of: extensionsText) { applyExtensions() }
    }

    // MARK: - 排布

    private var twoColumnForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    basicsSection
                    advancedSection
                }
                VStack(alignment: .leading, spacing: 18) {
                    runSection
                }
                // 右列都是短表单，限宽避免输入框被拉得太长。
                .frame(width: 380)
            }
            // 脚本编辑器需要横向空间，单独占一整行放在下面。
            scriptSection
        }
    }

    private var singleColumnForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            basicsSection
            advancedSection
            runSection
            scriptSection
        }
    }

    // MARK: - 基本信息

    private var basicsSection: some View {
        SRSection(L("基本信息")) {
            // 侧边栏只显示状态点，启用/停用的操作放在这里和右键菜单里。
            Toggle(L("启用（显示在右键菜单中）"), isOn: $command.isEnabled)
                .toggleStyle(.switch)
                .help(L("停用后不会出现在访达的右键菜单里。"))

            Divider()

            LabeledContent(L("标题")) {
                TextField(L("显示在右键菜单里的名字"), text: $command.title)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L("图标")) {
                SRSymbolPicker(symbol: $command.symbol)
            }

            LabeledContent(L("分组")) {
                HStack(spacing: 6) {
                    TextField(L("留空则直接放在菜单里"), text: $command.group)
                        .textFieldStyle(.roundedBorder)
                    if !model.knownGroups.isEmpty {
                        Menu {
                            Button(L("不分组")) { command.group = "" }
                            Divider()
                            ForEach(model.knownGroups, id: \.self) { group in
                                Button(group) { command.group = group }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    // 规则说明收进悬浮提示，省掉一行常驻说明文字。
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help(L("同名分组的命令会被收进同一个二级子菜单。"))
                }
            }
        }
    }

    // MARK: - 脚本

    private var scriptSection: some View {
        // 占位符与 shebang 的说明收进标题旁的悬浮提示。
        SRSection(L("脚本"),
                  hint: L("选中的路径同时会作为 $1 $2 … 传给脚本，写 \"$@\" 与写 {paths} 等价。")
                      + "\n"
                      + L("占位符默认已做 shell 转义；需要原始文本时用 {path:raw} 这种写法。")
                      + "\n"
                      + L("脚本以 #! 开头时会按 shebang 执行，下面的解释器设置将被忽略。")) {
            SRScriptEditor(text: $command.script, pendingInsertion: $pendingInsertion)
                .frame(minHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(L("插入占位符"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 92, maximum: 140), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(SRPlaceholder.reference, id: \.token) { entry in
                        Button(entry.token) { pendingInsertion = entry.token }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(L(entry.detail))
                    }
                }
            }

            LabeledContent(L("解释器")) {
                HStack(spacing: 6) {
                    Picker("", selection: shellSelection) {
                        ForEach(Self.knownShells, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text(L("自定义…")).tag("__custom__")
                    }
                    .labelsHidden()
                    .fixedSize()

                    if isCustomShell {
                        TextField(L("解释器绝对路径"), text: $command.shell)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            // 试运行的入口跟着脚本走，放在脚本区最下面。
            HStack(spacing: 10) {
                Button {
                    testRun()
                } label: {
                    Label(L("试运行…"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .help(L("挑几个文件当作选中项，立刻跑一次并显示输出"))
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    private var shellSelection: Binding<String> {
        Binding(
            get: { isCustomShell ? "__custom__" : command.shell },
            set: { newValue in
                if newValue == "__custom__" {
                    isCustomShell = true
                } else {
                    isCustomShell = false
                    command.shell = newValue
                }
            }
        )
    }

    // MARK: - 运行设置

    /// 运行方式和适用范围的字段合并成一张卡片，只用「运行设置」一个标题，
    /// 两组之间用细分割线隔开。
    private var runSection: some View {
        SRSection(L("运行设置")) {
            behaviourFields
            Divider()
            scopeFields
        }
    }

    @ViewBuilder
    private var behaviourFields: some View {
        Picker(L("完成后"), selection: $command.runMode) {
            ForEach(SRRunMode.allCases) { Text($0.displayName).tag($0) }
        }
        .fixedSize()

        if command.runMode == .terminal {
            terminalPicker
        }

        Picker(L("工作目录"), selection: $command.workingDirectory) {
            ForEach(SRWorkingDirectory.allCases) { Text($0.displayName).tag($0) }
        }
        .fixedSize()

        if command.workingDirectory == .custom {
            LabeledContent(L("路径")) {
                TextField(L("支持占位符，例如 {home}/Desktop"),
                          text: $command.customWorkingDirectory)
                    .textFieldStyle(.roundedBorder)
            }
        }

        HStack(spacing: 16) {
            // 两项没有依赖关系，只是都影响执行过程，并排省一行高度。
            Toggle(L("执行前弹窗确认"), isOn: $command.confirmBeforeRun)
            Toggle(L("完成后发送通知"), isOn: $command.notifyOnFinish)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 终端选择

    /// 让这条命令单独指定终端。留空则跟随设置里的全局默认。
    @ViewBuilder
    private var terminalPicker: some View {
        LabeledContent(L("使用终端")) {
            HStack(spacing: 6) {
                Picker("", selection: $command.terminalID) {
                    Text(L("跟随全局设置") + globalTerminalSuffix).tag("")
                    if !catalog.terminals.isEmpty {
                        Divider()
                        ForEach(catalog.terminals) { terminal in
                            Text(terminal.name).tag(terminal.id)
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()

                // 这条命令指定的终端被卸载了的话，得让用户看见，
                // 否则运行时会静默回落到全局默认，很难察觉。
                if !command.terminalID.isEmpty,
                   catalog.terminals.first(where: { $0.id == command.terminalID }) == nil {
                    Label(L("该终端已不在列表中"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button(L("管理…")) { SRWindowManager.shared.showSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var globalTerminalSuffix: String {
        guard let name = catalog.selected?.name else { return "" }
        return "（\(name)）"
    }

    @ViewBuilder
    private var scopeFields: some View {
        Picker(L("适用于"), selection: $command.appliesTo) {
            ForEach(SRSelectionKind.allCases) { Text($0.displayName).tag($0) }
        }
        .fixedSize()

        LabeledContent(L("扩展名")) {
            TextField(L("留空表示不限，多个用逗号分隔，如 jpg, png"), text: $extensionsText)
                .textFieldStyle(.roundedBorder)
        }

        HStack(spacing: 16) {
            Toggle(L("允许多选"), isOn: $command.allowsMultipleSelection)
                .help(L("关掉之后，选中多个文件时这条命令不会出现在菜单里。"))

            // 只有允许多选时这条才有意义，放在多选开关后面并跟着禁用。
            Toggle(L("每个选中项各跑一次"), isOn: $command.runOncePerItem)
                .help(command.allowsMultipleSelection
                      ? L("关掉的话，所有选中路径会一次性传给同一个进程。")
                      : L("先把上面的「允许多选」打开。"))
                .disabled(!command.allowsMultipleSelection)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var timeoutField: some View {
        // 常用档位直接摆一行，指向同一个值；右侧的后进器留给自定义秒数。
        LabeledContent(L("超时")) {
            HStack(spacing: 6) {
                ForEach(Self.timeoutPresets, id: \.self) { seconds in
                    if command.timeoutSeconds == seconds {
                        Button(timeoutLabel(seconds)) { command.timeoutSeconds = seconds }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    } else {
                        Button(timeoutLabel(seconds)) { command.timeoutSeconds = seconds }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                Spacer(minLength: 6)

                Stepper(value: $command.timeoutSeconds, in: 0...3600, step: 10) {
                    Text(timeoutLabel(command.timeoutSeconds))
                        .monospacedDigit()
                }
                .fixedSize()
            }
        }
    }

    private static let timeoutPresets = [0, 15, 30, 45, 60]

    private func timeoutLabel(_ seconds: Int) -> String {
        if seconds == 0 { return L("不限制") }
        if seconds % 60 == 0 { return L("%@ 分钟", String(seconds / 60)) }
        return L("%@ 秒", String(seconds))
    }

    // MARK: - 高级

    private var advancedSection: some View {
        SRSection(L("高级")) {
            timeoutField
        }
    }

    // MARK: - 动作

    private func testRun() {
        let panel = NSOpenPanel()
        panel.title = L("选择用于试运行的文件或文件夹")
        panel.prompt = L("试运行")
        panel.canChooseFiles = command.appliesTo != .foldersOnly
        panel.canChooseDirectories = command.appliesTo != .filesOnly
        panel.allowsMultipleSelection = command.allowsMultipleSelection

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        SRCommandRunner.shared.testRun(command: command, paths: panel.urls.map(\.path)) {
            SRWindowManager.shared.showOutput()
        }
    }

    // MARK: - 本地状态同步

    private func syncLocalState() {
        extensionsText = command.fileExtensions.joined(separator: ", ")
        isCustomShell = !Self.knownShells.contains(command.shell)
    }

    private func applyExtensions() {
        let parsed = extensionsText
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "." })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if parsed != command.fileExtensions {
            command.fileExtensions = parsed
        }
    }
}

/// macOS 26 起 ScrollView 默认会在标题栏/安全区交界处加一层 scroll edge effect。
/// 内容是放大版表单，这层模糊只会让顶部多出一条矩形，直接关掉。
private struct SRHideScrollEdgeEffect: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden()
        } else {
            content
        }
    }
}

// MARK: - 分区容器

struct SRSection<Content: View>: View {

    private let title: String
    private let hint: String?
    private let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        // 标题和卡片之间收得紧一点，表单整体更紧凑。
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                if let hint {
                    // 常驻说明太长时收进标题旁的悬浮提示。
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(hint)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }
}
