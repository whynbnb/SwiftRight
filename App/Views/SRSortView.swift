import AppKit
import SwiftUI

/// 独立的排序窗口：左边筛选/分组顺序，右边按分组展示命令。
///
/// 主窗口侧边栏负责「拖到哪个分组就是哪个分组」，这里则负责更细的管理：
/// 命令排序、启用/停用、换分组、直接改名和换图标，以及分组之间的顺序。
struct SRSortView: View {

    @EnvironmentObject private var model: SRAppModel
    @ObservedObject private var terminals = SRTerminalCatalog.shared
    @ObservedObject private var editors = SREditorCatalog.shared
    @ObservedObject private var templates = SRTemplateStore.shared

    private enum SortFilter: Hashable {
        case all
        case ungrouped
        case group(String)
    }

    /// 右侧扁平行：分组标题、空分组提示、命令。
    private enum SortRow: Identifiable {
        case header(SRCommandSection)
        case empty(String)
        case command(UUID, isLast: Bool)

        var id: String {
            switch self {
            case .header(let section): return "h:\(section.id)"
            case .empty(let name): return "e:\(name)"
            case .command(let id, _): return "c:\(id.uuidString)"
            }
        }
    }

    @State private var filter: SortFilter? = .all

    var body: some View {
        HStack(spacing: 0) {
            groupPane
                .frame(width: 220)
            Divider()
            commandPane
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.sections.map(\.name)) { _, names in
            // 当前筛选的分组被删空/改名后，回到「全部」。
            switch filter {
            case .ungrouped:
                if !names.contains("") { filter = .all }
            case .group(let name):
                if !names.contains(name) { filter = .all }
            default:
                break
            }
        }
    }

    // MARK: - 左侧：筛选和分组顺序

    private var groupPane: some View {
        VStack(spacing: 0) {
            List(selection: $filter) {
                Section {
                    Label(L("全部"), systemImage: "square.grid.2x2")
                        .tag(SortFilter.all)
                    if model.sections.contains(where: { $0.name.isEmpty }) {
                        Label(L("未分组"), systemImage: "tray")
                            .tag(SortFilter.ungrouped)
                    }
                }

                Section {
                    if model.sortGroupNames.isEmpty {
                        Text(L("还没有分组"))
                            .foregroundStyle(.secondary)
                    } else {
                        // 左侧只负责筛选和拖动排序，不改名、不换图标。
                        ForEach(model.sortGroupNames, id: \.self) { group in
                            Label(group, systemImage: model.settings.symbol(for: group))
                                .lineLimit(1)
                                .tag(SortFilter.group(group))
                        }
                        .onMove { model.moveGroup(from: $0, to: $1) }
                    }
                } header: {
                    Text(L("分组"))
                }
            }
            .listStyle(.sidebar)
            .contextMenu {
                Button(L("新建分组")) { addGroup() }
            }

            Divider()

            HStack(spacing: 8) {
                Text(L("拖动调整分组顺序。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Menu {
                    Button {
                        addCommandToCurrentGroup()
                    } label: {
                        Label(L("新建命令"), systemImage: "plus.square")
                    }
                    Button {
                        addGroup()
                    } label: {
                        Label(L("新建分组"), systemImage: "folder.badge.plus")
                    }
                    Divider()
                    terminalMenu
                    editorMenu
                    templateMenu
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("添加"))
            }
            .padding(10)
        }
    }

    // MARK: - 右侧：命令

    private var visibleSections: [SRCommandSection] {
        switch filter ?? .all {
        case .all:
            // 全部视图只展示有命令的分组，行结构和侧边栏保持一致，
            // 这样跨分组拖动可以直接复用 moveSidebarRow。
            return model.sections
        case .ungrouped:
            return model.sections.filter { $0.name.isEmpty }
        case .group(let name):
            if let section = model.sections.first(where: { $0.name == name }) {
                return [section]
            }
            // 空分组也要显示标题，才能改名和换图标。
            return [SRCommandSection(name: name, commands: [])]
        }
    }

    private var sortRows: [SortRow] {
        var rows: [SortRow] = []
        for section in visibleSections {
            rows.append(.header(section))
            if section.commands.isEmpty {
                rows.append(.empty(section.name))
            } else {
                for (index, command) in section.commands.enumerated() {
                    rows.append(.command(command.id,
                                         isLast: index == section.commands.count - 1))
                }
            }
        }
        return rows
    }

    private var commandPane: some View {
        List {
            if sortRows.isEmpty {
                Text(L("还没有命令"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortRows) { row in
                    switch row {
                    case .header(let section):
                        Group {
                            if section.name.isEmpty {
                                Label(L("未分组"), systemImage: "tray")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            } else {
                                SRGroupHeader(
                                    name: section.name,
                                    symbol: model.settings.symbol(for: section.name),
                                    onRename: { renameGroup(from: section.name, to: $0) },
                                    onSymbol: { model.setGroupSymbol($0, for: section.name) }
                                )
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 6, trailing: 16))
                        .moveDisabled(true)

                    case .empty:
                        Text(L("还没有命令"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
                            .moveDisabled(true)

                    case .command(let id, let isLast):
                        if let binding = model.binding(for: id) {
                            SRSortRow(command: binding,
                                      groups: model.sortGroupNames) { newGroup in
                                model.changeGroup(for: id, to: newGroup)
                            }
                            .listRowSeparator(.hidden,
                                              edges: isLast ? [.top, .bottom] : .top)
                        }
                    }
                }
                .onMove { offsets, destination in
                    guard let source = offsets.first else { return }
                    moveSortRow(from: source, to: destination)
                }
            }
        }
        .listStyle(.inset)
        .listSectionSeparator(.hidden)
        .contextMenu {
            Button(L("新建命令")) { addCommandToCurrentGroup() }
        }
    }

    // MARK: - 生成器

    @ViewBuilder
    private var terminalMenu: some View {
        if !terminals.terminals.isEmpty {
            Menu(L("在此处打开终端")) {
                ForEach(terminals.terminals) { terminal in
                    Button {
                        reveal(model.addTerminalCommand(for: terminal))
                    } label: {
                        if model.terminalCommand(for: terminal.id) != nil {
                            Label(terminal.name, systemImage: "checkmark")
                        } else {
                            Text(terminal.name)
                        }
                    }
                }
                Divider()
                Button(L("全部添加")) {
                    model.addTerminalCommands(for: terminals.terminals)
                    filter = .all
                }
            }
        }
    }

    @ViewBuilder
    private var editorMenu: some View {
        if !editors.editors.isEmpty {
            Menu(L("在此处打开编辑器")) {
                ForEach(editors.editors) { editor in
                    Button {
                        reveal(model.addEditorCommand(for: editor))
                    } label: {
                        if model.editorCommand(for: editor.id) != nil {
                            Label(editor.name, systemImage: "checkmark")
                        } else {
                            Text(editor.name)
                        }
                    }
                }
                Divider()
                Button(L("全部添加")) {
                    model.addEditorCommands(for: editors.editors)
                    filter = .all
                }
            }
        }
    }

    @ViewBuilder
    private var templateMenu: some View {
        if !templates.templates.isEmpty {
            Menu(L("新建文件")) {
                ForEach(templates.templates) { template in
                    Button {
                        reveal(model.addTemplateCommand(for: template))
                    } label: {
                        if model.templateCommand(for: template.id) != nil {
                            Label(template.name, systemImage: "checkmark")
                        } else {
                            Text(template.name)
                        }
                    }
                }
                Divider()
                Button(L("全部添加")) {
                    model.addTemplateCommands(for: templates.templates)
                    filter = .all
                }
            }
        }
    }

    // MARK: - 动作

    /// 生成命令后把筛选切到它所在的分组，确保立即可见。
    private func reveal(_ id: UUID) {
        guard let command = model.commands.first(where: { $0.id == id }) else { return }
        let group = command.group.trimmingCharacters(in: .whitespaces)
        filter = group.isEmpty ? .ungrouped : .group(group)
    }

    /// 右侧拖拽：全部视图下跨分组拖动会改分组；单分组视图下只重排组内顺序。
    private func moveSortRow(from source: Int, to destination: Int) {
        switch filter ?? .all {
        case .all:
            // 全部视图的行结构和 model.sections 完全一致，直接复用侧边栏的移动逻辑。
            model.moveSidebarRow(from: source, to: destination)
        case .ungrouped, .group(_):
            guard let section = visibleSections.first else { return }
            let headerRow = 0
            guard source > headerRow else { return }

            let sourceOffset = source - headerRow - 1
            var targetOffset = destination - headerRow - 1
            if targetOffset > sourceOffset { targetOffset -= 1 }
            let maxOffset = max(section.commands.count - 1, 0)
            targetOffset = min(max(targetOffset, 0), maxOffset)

            model.moveCommand(inSectionNamed: section.name,
                              from: IndexSet(integer: sourceOffset),
                              to: targetOffset)
        }
    }

    private func addGroup() {
        let name = model.addGroup()
        filter = .group(name)
    }

    private func addCommandToCurrentGroup() {
        let group: String
        switch filter ?? .all {
        case .group(let name):
            group = name
        case .ungrouped, .all:
            group = ""
        }
        model.addCommand(in: group)
    }

    /// 返回最终使用的分组名，供行内编辑框回填。
    private func renameGroup(from old: String, to draft: String) -> String {
        let target = draft.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, target != old else { return old }
        model.renameGroup(from: old, to: target)
        if case .group(let selected) = filter, selected == old {
            filter = .group(target)
        }
        return target
    }
}

// MARK: - 分组标题

/// 右侧每个分组的标题行：图标可点开选择器，名称直接编辑。
private struct SRGroupHeader: View {

    let name: String
    let symbol: String
    let onRename: (String) -> String
    let onSymbol: (String) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(name: String,
         symbol: String,
         onRename: @escaping (String) -> String,
         onSymbol: @escaping (String) -> Void) {
        self.name = name
        self.symbol = symbol
        self.onRename = onRename
        self.onSymbol = onSymbol
        _draft = State(initialValue: name)
    }

    var body: some View {
        HStack(spacing: 6) {
            SRSymbolPicker(
                symbol: Binding(get: { symbol }, set: { onSymbol($0) }),
                compact: true,
                compactTint: .accentColor
            )

            TextField(L("分组名称"), text: $draft)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }

            Spacer(minLength: 0)
        }
        .onChange(of: name) { _, newName in
            if !focused { draft = newName }
        }
    }

    private func commit() {
        draft = onRename(draft)
    }
}

// MARK: - 命令行

private struct SRSortRow: View {

    @Binding var command: SRCommand
    let groups: [String]
    let onChangeGroup: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help(L("拖动调整顺序"))

            SRSymbolPicker(
                symbol: $command.symbol,
                compact: true,
                compactTint: command.isEnabled ? .accentColor : .secondary
            )
            .frame(width: 24)

            TextField(L("命令名称"), text: $command.title)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: Binding(
                get: { command.group },
                set: { onChangeGroup($0) }
            )) {
                Text(L("未分组")).tag("")
                ForEach(groups, id: \.self) { group in
                    Text(group).tag(group)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 150)
            .help(L("更换分组"))

            Toggle("", isOn: $command.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(command.isEnabled ? L("已启用") : L("已停用"))
        }
        .padding(.vertical, 3)
    }
}
