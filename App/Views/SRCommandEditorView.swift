import AppKit
import SwiftUI

struct SRCommandEditorView: View {

    @Binding var command: SRCommand
    @EnvironmentObject private var model: SRAppModel

    @State private var pendingInsertion: String?
    @State private var extensionsText: String = ""
    @State private var isCustomShell = false

    private static let knownShells = [
        "/bin/zsh", "/bin/bash", "/bin/sh",
        "/usr/bin/python3", "/usr/bin/perl", "/usr/bin/ruby", "/usr/bin/osascript",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                basicsSection
                scriptSection
                behaviourSection
                scopeSection
                advancedSection
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: syncLocalState)
        .onChange(of: command.id) { syncLocalState() }
        .onChange(of: extensionsText) { applyExtensions() }
    }

    // MARK: - 基本信息

    private var basicsSection: some View {
        SRSection(L("基本信息")) {
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
                }
            }
            Text(L("同名分组的命令会被收进同一个二级子菜单。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 脚本

    private var scriptSection: some View {
        SRSection(L("脚本")) {
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

            Text(L("选中的路径同时会作为 $1 $2 … 传给脚本，写 \"$@\" 与写 {paths} 等价。")
                 + "\n"
                 + L("占位符默认已做 shell 转义；需要原始文本时用 {path:raw} 这种写法。")
                 + "\n"
                 + L("脚本以 #! 开头时会按 shebang 执行，下面的解释器设置将被忽略。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

    // MARK: - 运行行为

    private var behaviourSection: some View {
        SRSection(L("运行方式")) {
            Picker(L("完成后"), selection: $command.runMode) {
                ForEach(SRRunMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.radioGroup)

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

            Toggle(L("每个选中项各跑一次"), isOn: $command.runOncePerItem)
                .help(L("关掉的话，所有选中路径会一次性传给同一个进程。"))
            Toggle(L("执行前弹窗确认"), isOn: $command.confirmBeforeRun)
            Toggle(L("完成后发送通知"), isOn: $command.notifyOnFinish)
        }
    }

    // MARK: - 适用范围

    private var scopeSection: some View {
        SRSection(L("适用范围")) {
            Picker(L("适用于"), selection: $command.appliesTo) {
                ForEach(SRSelectionKind.allCases) { Text($0.displayName).tag($0) }
            }
            .fixedSize()

            LabeledContent(L("扩展名")) {
                TextField(L("留空表示不限，多个用逗号分隔，如 jpg, png"), text: $extensionsText)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle(L("允许多选"), isOn: $command.allowsMultipleSelection)
                .help(L("关掉之后，选中多个文件时这条命令不会出现在菜单里。"))
            Toggle(L("启用（显示在右键菜单中）"), isOn: $command.isEnabled)
        }
    }

    // MARK: - 高级

    private var advancedSection: some View {
        SRSection(L("高级")) {
            LabeledContent(L("超时")) {
                Stepper(value: $command.timeoutSeconds, in: 0...3600, step: 10) {
                    Text(command.timeoutSeconds == 0
                         ? L("不限制")
                         : L("%@ 秒", String(command.timeoutSeconds)))
                }
                .fixedSize()
            }

            HStack(spacing: 10) {
                Button {
                    testRun()
                } label: {
                    Label(L("试运行…"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .help(L("挑几个文件当作选中项，立刻跑一次并显示输出"))

                Button {
                    model.duplicate(command.id)
                } label: {
                    Label(L("复制一份"), systemImage: "plus.square.on.square")
                }

                Spacer()

                Button(role: .destructive) {
                    model.delete(command.id)
                } label: {
                    Label(L("删除"), systemImage: "trash")
                }
            }
            .padding(.top, 2)
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

// MARK: - 分区容器

struct SRSection<Content: View>: View {

    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
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
