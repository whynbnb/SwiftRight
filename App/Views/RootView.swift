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
                    SRCommandRow(command: $command,
                                 isSelected: model.selection == command.id)
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
            // 主动作是新建空白命令，点箭头展开生成器。
            // 三类生成器各收进一个子菜单：平铺的话终端 11 + 编辑器 15 +
            // 模板 10，一个菜单三十多项，根本没法看。
            Menu {
                Button(L("空白命令")) { model.addCommand() }
                Divider()
                terminalMenu
                editorMenu
                templateMenu
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

    // MARK: - 生成器子菜单

    /// 每组末尾都带自己的「全部添加」。原来只有一个「为全部终端和编辑器创建」，
    /// 加了模板之后它就漏了一类，而且用户多半只想一次加一类。
    @ViewBuilder
    private var terminalMenu: some View {
        if !catalog.terminals.isEmpty {
            Menu(L("在此处打开终端")) {
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
                Divider()
                Button(L("全部添加")) { model.addTerminalCommands(for: catalog.terminals) }
            }
        }
    }

    @ViewBuilder
    private var editorMenu: some View {
        if !editors.editors.isEmpty {
            Menu(L("在此处打开编辑器")) {
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
                Divider()
                Button(L("全部添加")) { model.addEditorCommands(for: editors.editors) }
            }
        }
    }

    @ViewBuilder
    private var templateMenu: some View {
        if !templates.templates.isEmpty {
            Menu(L("新建文件")) {
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
                Divider()
                Button(L("全部添加")) { model.addTemplateCommands(for: templates.templates) }
            }
        }
    }
}

// MARK: - 列表行

private struct SRCommandRow: View {

    @Binding var command: SRCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .frame(width: 18)
                .foregroundStyle(iconStyle)

            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .lineLimit(1)
                    .foregroundStyle(titleStyle)
                if !command.group.isEmpty {
                    Text(command.group)
                        .font(.caption2)
                        .foregroundStyle(groupStyle)
                }
            }

            Spacer(minLength: 4)

            Group {
                if isSelected {
                    Toggle("", isOn: $command.isEnabled)
                        .toggleStyle(SRSelectedSwitchStyle())
                } else {
                    Toggle("", isOn: $command.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            .labelsHidden()
            // mini 开关连同预留的标签位是 54×24，这样选中前后右侧不会跳。
            .frame(width: 54, height: 24, alignment: .trailing)
            .help(command.isEnabled ? L("已启用") : L("已停用"))
        }
        .padding(.vertical, 2)
    }

    // 选中行交给 SwiftUI 处理：`Color.primary` 在蓝底上会自动变成白，
    // 灰底（列表失焦）时则是正常的黑/白，不需要自己判断外观。
    // `.secondary` / `.tertiary` 不会跟着选中态走，只能用 primary 调透明度。
    private var iconStyle: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.primary.opacity(command.isEnabled ? 1 : 0.6))
        }
        return AnyShapeStyle(command.isEnabled ? Color.accentColor : Color.secondary)
    }

    private var titleStyle: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.primary.opacity(command.isEnabled ? 1 : 0.6))
        }
        return AnyShapeStyle(command.isEnabled ? .primary : .secondary)
    }

    private var groupStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.primary.opacity(0.75)) }
        return AnyShapeStyle(.tertiary)
    }

    private var iconName: String {
        guard !command.symbol.isEmpty,
              NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) != nil
        else { return "terminal" }
        return command.symbol
    }
}

/// 选中行上的开关。
///
/// 原生开关的蓝色轨道和选中行的蓝底完全同色，开着也只剩一个白点，
/// 看起来像状态丢了。选中时换成反色：白轨道 + 强调色滑块，不描边也能
/// 从蓝底里分出来；灰底（列表失焦）时同样成立。
///
/// 尺寸照 mini 开关实测的 36×15，外层仍占 54×24，所以选中前后不会跳。
private struct SRSelectedSwitchStyle: ToggleStyle {

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn
                          ? Color.white
                          : Color.primary.opacity(0.25))
                Circle()
                    .fill(configuration.isOn ? Color.accentColor : Color.white)
                    .padding(1)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
            .frame(width: 36, height: 15)
            .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
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
