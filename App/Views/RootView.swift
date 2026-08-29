import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {

    @EnvironmentObject private var model: SRAppModel
    @State private var showingSettings = false
    @State private var importMerge = false
    @State private var showingImporter = false
    @State private var showingExporter = false
    /// 只在真要导出时才构造。放在 body 里会每次重绘都把整份配置编码一遍。
    @State private var exportDocument: SRConfigDocument?
    @State private var alert: SRAlert?

    // 拆成三段是为了给 SwiftUI 的类型检查器减负。
    // 十来个修饰符堆在一个 body 里，编译时间会失控甚至直接超时。
    var body: some View {
        splitView
            .modifier(FilePanels(model: model,
                                 showingImporter: $showingImporter,
                                 showingExporter: $showingExporter,
                                 exportDocument: $exportDocument,
                                 importMerge: $importMerge,
                                 alert: $alert))
            .modifier(SettingsSheet(model: model, isPresented: $showingSettings))
            .alert(alert?.title ?? "", isPresented: alertPresented, presenting: alert) { _ in
                Button("好", role: .cancel) { alert = nil }
            } message: { item in
                Text(item.message)
            }
            .onAppear { model.refreshExtensionStatus() }
    }

    private var splitView: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 460)
        .toolbar { toolbarContent }
    }

    private var alertPresented: Binding<Bool> {
        Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
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
                    Button("复制一份") { model.duplicate(id) }
                    Button("删除", role: .destructive) { model.delete(id) }
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
                Label("还没有命令", systemImage: "bolt.circle")
            } description: {
                Text("点左下角的 + 新建一条，它会立刻出现在 Finder 的右键菜单里。")
            } actions: {
                Button("新建命令") { model.addCommand() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.addCommand()
            } label: {
                Label("新建", systemImage: "plus")
            }
            .help("新建命令")

            Button {
                if let id = model.selection { model.delete(id) }
            } label: {
                Label("删除", systemImage: "minus")
            }
            .disabled(model.selection == nil)
            .help("删除选中的命令")
        }

        ToolbarItemGroup {
            Button {
                SRWindowManager.shared.showOutput()
            } label: {
                Label("运行输出", systemImage: "text.alignleft")
            }
            .help("查看运行输出")

            Menu {
                Button("导出为 JSON…") {
                    exportDocument = SRConfigDocument(model: model)
                    showingExporter = true
                }
                Button("导入并追加…") { importMerge = true; showingImporter = true }
                Button("导入并替换…") { importMerge = false; showingImporter = true }
                Divider()
                Button("在访达中显示配置文件") {
                    NSWorkspace.shared.activateFileViewerSelecting([SRPaths.configFile])
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }

            Button {
                showingSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .help("菜单外观与扩展设置")
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
                .help(command.isEnabled ? "已启用" : "已停用")
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

/// 导入 / 导出面板。单独抽成 ViewModifier，让 RootView.body 的表达式短一点。
private struct FilePanels: ViewModifier {

    let model: SRAppModel
    @Binding var showingImporter: Bool
    @Binding var showingExporter: Bool
    @Binding var exportDocument: SRConfigDocument?
    @Binding var importMerge: Bool
    @Binding var alert: SRAlert?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .fileExporter(isPresented: $showingExporter,
                          document: exportDocument,
                          contentType: .json,
                          defaultFilename: "SwiftRight-commands") { result in
                exportDocument = nil
                if case .failure(let error) = result {
                    alert = SRAlert(title: "导出失败", message: error.localizedDescription)
                }
            }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                try model.importConfig(from: url, merge: importMerge)
            } catch {
                alert = SRAlert(title: "导入失败", message: error.localizedDescription)
            }
        case .failure(let error):
            alert = SRAlert(title: "导入失败", message: error.localizedDescription)
        }
    }
}

private struct SettingsSheet: ViewModifier {

    let model: SRAppModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            SRGeneralSettingsView()
                .environmentObject(model)
        }
    }
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
