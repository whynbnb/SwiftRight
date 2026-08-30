import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {

    @EnvironmentObject private var model: SRAppModel
    @ObservedObject private var catalog = SRTerminalCatalog.shared
    @ObservedObject private var editors = SREditorCatalog.shared
    @ObservedObject private var templates = SRTemplateStore.shared

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 460)
        .toolbar { toolbarContent }
        .onAppear { model.refreshExtensionStatus() }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach($model.commands) { $command in
                    SRCommandRow(command: $command)
                        .tag(command.id)
                }
                .onMove { model.move(from: $0, to: $1) }
                .onDelete { offsets in
                    // 先取 id 再删。边遍历索引边删会因为位移而删错项。
                    let ids = offsets.map { model.commands[$0].id }
                    for id in ids { model.delete(id) }
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first {
                    Button(L("复制一份")) { model.duplicate(id) }
                    Button(L("删除"), role: .destructive) { model.delete(id) }
                }
            }

            Divider()
            SRExtensionStatusBar()
                .environmentObject(model)
        }
    }

    // MARK: - 详情

    @ViewBuilder
    private var detail: some View {
        if let id = model.selection, let binding = model.binding(for: id) {
            SRCommandEditorView(command: binding)
                .environmentObject(model)
                .id(id)
        } else {
            ContentUnavailableView {
                Label(L("还没有命令"), systemImage: "bolt.circle")
            } description: {
                Text(L("点左上角的 + 新建一条，它会立刻出现在访达的右键菜单里。"))
            } actions: {
                Button(L("新建命令")) { model.addCommand() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // 主动作还是"新建空白命令"，点箭头才展开终端列表 ——
            // 从已扫描的终端一键生成「在此处打开 kitty」这类命令。
            Menu {
                Button(L("空白命令")) { model.addCommand() }

                if !catalog.terminals.isEmpty {
                    Divider()
                    Section(L("在此处打开终端…")) {
                        ForEach(catalog.terminals) { terminal in
                            Button {
                                model.addTerminalCommand(for: terminal)
                            } label: {
                                // 已经建过的打个勾，省得重复点。
                                if model.terminalCommand(for: terminal.id) != nil {
                                    Label(terminal.name, systemImage: "checkmark")
                                } else {
                                    Text(terminal.name)
                                }
                            }
                        }
                    }
                }

                if !editors.editors.isEmpty {
                    Divider()
                    Section(L("在此处打开编辑器…")) {
                        ForEach(editors.editors) { editor in
                            Button {
                                model.addEditorCommand(for: editor)
                            } label: {
                                if model.editorCommand(for: editor.id) != nil {
                                    Label(editor.name, systemImage: "checkmark")
                                } else {
                                    Text(editor.name)
                                }
                            }
                        }
                    }
                }

                if !templates.templates.isEmpty {
                    Divider()
                    Section(L("新建文件…")) {
                        ForEach(templates.templates) { template in
                            Button {
                                model.addTemplateCommand(for: template)
                            } label: {
                                if model.templateCommand(for: template.id) != nil {
                                    Label(template.name, systemImage: "checkmark")
                                } else {
                                    Text(template.name)
                                }
                            }
                        }
                    }
                }

                if !catalog.terminals.isEmpty || !editors.editors.isEmpty {
                    Divider()
                    Button(L("为全部终端和编辑器创建")) {
                        model.addTerminalCommands(for: catalog.terminals)
                        model.addEditorCommands(for: editors.editors)
                    }
                }
            } label: {
                Label(L("新建"), systemImage: "plus")
            } primaryAction: {
                model.addCommand()
            }
            .help(L("新建命令"))

            Button {
                if let id = model.selection { model.delete(id) }
            } label: {
                Label(L("删除"), systemImage: "minus")
            }
            .disabled(model.selection == nil)
            .help(L("删除选中的命令"))
        }

        ToolbarItemGroup {
            Button {
                SRWindowManager.shared.showOutput()
            } label: {
                Label(L("运行输出"), systemImage: "text.alignleft")
            }
            .help(L("查看运行输出"))

            // 导入导出、菜单外观、语言主题现在统一在设置窗口里，
            // 工具栏不再各开一个入口。
            Button {
                SRWindowManager.shared.showSettings()
            } label: {
                Label(L("设置"), systemImage: "gearshape")
            }
            .help(L("设置"))
        }
    }
}

// MARK: - 列表行

private struct SRCommandRow: View {

    @Binding var command: SRCommand

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .frame(width: 18)
                .foregroundStyle(command.isEnabled ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .lineLimit(1)
                    .foregroundStyle(command.isEnabled ? .primary : .secondary)
                if !command.group.isEmpty {
                    Text(command.group)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            Toggle("", isOn: $command.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(command.isEnabled ? L("已启用") : L("已停用"))
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        guard !command.symbol.isEmpty,
              NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) != nil
        else { return "terminal" }
        return command.symbol
    }
}

// MARK: - 辅助

struct SRAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// fileExporter 需要一个 FileDocument。这里只做导出，读取路径用不到。
struct SRConfigDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    private let data: Data

    init(model: SRAppModel) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = (try? encoder.encode(SRConfig(settings: model.settings,
                                             commands: model.commands))) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
