import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {

    @EnvironmentObject private var model: SRAppModel
    @ObservedObject private var catalog = SRTerminalCatalog.shared
    @ObservedObject private var editors = SREditorCatalog.shared
    @ObservedObject private var templates = SRTemplateStore.shared

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 460)
        .toolbar { toolbarContent }
        .onAppear { model.refreshExtensionStatus() }
        .onChange(of: columnVisibility) { forceRelayout() }
    }

    /// macOS 26 折叠侧栏后，详情列的背景层有时还停在展开时的宽度，
    /// 鼠标移进去才刷新成一块矩形。主动让窗口重排 + 重绘一次。
    private func forceRelayout() {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible {
                window.contentView?.needsLayout = true
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
    }

    // MARK: - 侧边栏

    /// 侧边栏的扁平行：分组标题 + 命令。
    /// 拖拽时 `onMove` 给的是这个数组里的下标，模型据此判断落到了哪个分组。
    private enum SidebarRow: Identifiable {
        case header(String)
        case command(UUID)

        var id: String {
            switch self {
            case .header(let name): return "h:\(name)"
            case .command(let id): return "c:\(id.uuidString)"
            }
        }
    }

    private var sidebarRows: [SidebarRow] {
        model.sections.flatMap { section in
            [.header(section.name)] + section.commands.map { .command($0.id) }
        }
    }

    private func sidebarHeader(_ name: String) -> some View {
        Text(name.isEmpty ? L("未分组") : name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .selectionDisabled()
            .moveDisabled(true)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(sidebarRows) { row in
                    switch row {
                    case .header(let name):
                        sidebarHeader(name)
                    case .command(let id):
                        if let binding = model.binding(for: id) {
                            SRCommandRow(command: binding,
                                         isSelected: model.selection == id)
                                .tag(id)
                        }
                    }
                }
                .onMove { offsets, destination in
                    guard let source = offsets.first else { return }
                    model.moveSidebarRow(from: source, to: destination)
                }
                .onDelete { offsets in
                    // 标题行不参与删除，只取命令行。
                    let ids: [UUID] = offsets.compactMap { index in
                        guard sidebarRows.indices.contains(index),
                              case .command(let id) = sidebarRows[index] else { return nil }
                        return id
                    }
                    for id in ids { model.delete(id) }
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first {
                    if let command = model.commands.first(where: { $0.id == id }) {
                        Button(command.isEnabled ? L("停用") : L("启用")) {
                            model.toggleEnabled(id)
                        }
                        Divider()
                    }
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
        Group {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 折叠侧栏后，详情列的背景层有时还停在展开时的宽度，鼠标移进去
        // 才刷新成一块矩形。这里给详情列铺一层不随安全区收缩的背景，
        // 让它始终跟着列宽走。
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
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
        }

        ToolbarItemGroup {
            // 低频操作收进右侧的「更多」：删除和运行输出。
            // 设置不放在工具栏 —— 菜单栏和 ⌘, 都已经有入口了。
            Menu {
                Button {
                    SRWindowManager.shared.showSort()
                } label: {
                    Label(L("排序…"), systemImage: "arrow.up.arrow.down")
                }

                Button {
                    SRWindowManager.shared.showOutput()
                } label: {
                    Label(L("运行输出"), systemImage: "text.alignleft")
                }

                Divider()

                Button(role: .destructive) {
                    if let id = model.selection { model.delete(id) }
                } label: {
                    Label(L("删除"), systemImage: "trash")
                }
                .disabled(model.selection == nil)
            } label: {
                Label(L("更多"), systemImage: "ellipsis.circle")
            }
            .help(L("更多"))
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

            Text(command.title)
                .lineLimit(1)
                .foregroundStyle(titleStyle)

            Spacer(minLength: 4)

            statusDot
        }
        .padding(.vertical, 2)
    }

    /// 侧边栏只显示状态。开关会和蓝色高亮抢颜色，所以统一放到
    /// 右键菜单和右侧详情页里操作。
    private var statusDot: some View {
        Circle()
            .fill(command.isEnabled ? Color.green : Color.secondary.opacity(0.45))
            .frame(width: 8, height: 8)
            .help(command.isEnabled ? L("已启用") : L("已停用"))
            .accessibilityLabel(command.isEnabled ? L("已启用") : L("已停用"))
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
