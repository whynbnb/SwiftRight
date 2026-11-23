import AppKit
import SwiftUI

/// 独立的排序窗口：左边筛选/分组顺序，右边按分组展示命令。
///
/// 主窗口侧边栏负责「拖到哪个分组就是哪个分组」，这里则负责更细的管理：
/// 命令排序、启用/停用、换分组，以及分组之间的先后顺序。
struct SRSortView: View {

    @EnvironmentObject private var model: SRAppModel

    private enum SortFilter: Hashable {
        case all
        case ungrouped
        case group(String)
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
        .onChange(of: model.sections.map(\.name)) { names in
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
                        ForEach(model.sortGroupNames, id: \.self) { group in
                            Label(group, systemImage: "folder")
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

            Divider()

            Text(L("拖动调整分组顺序。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    // MARK: - 右侧：命令

    private var visibleSections: [SRCommandSection] {
        switch filter ?? .all {
        case .all:
            return model.sections
        case .ungrouped:
            return model.sections.filter { $0.name.isEmpty }
        case .group(let name):
            return model.sections.filter { $0.name == name }
        }
    }

    private var commandPane: some View {
        List {
            if visibleSections.isEmpty {
                Text(L("还没有命令"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleSections) { section in
                    Section {
                        ForEach(section.commands) { command in
                            if let binding = model.binding(for: command.id) {
                                SRSortRow(command: binding,
                                          groups: model.sortGroupNames) { newGroup in
                                    model.changeGroup(for: command.id, to: newGroup)
                                }
                                .listRowSeparator(.hidden, edges: .top)
                            }
                        }
                        .onMove { offsets, destination in
                            model.moveCommand(inSectionNamed: section.name,
                                              from: offsets,
                                              to: destination)
                        }
                    } header: {
                        Text(section.name.isEmpty ? L("未分组") : section.name)
                    }
                }
            }
        }
        .listStyle(.inset)
        // inset 列表在分组标题和第一行之间会叠两条线：一条是标题的
        // section separator，一条是第一行的 top separator。全部关掉，
        // 只留行与行之间的分隔线。
        .listSectionSeparator(.hidden)
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

            Image(systemName: iconName)
                .frame(width: 18)
                .foregroundStyle(command.isEnabled ? Color.accentColor : Color.secondary)

            Text(command.title)
                .lineLimit(1)
                .foregroundStyle(command.isEnabled ? .primary : .secondary)

            Spacer(minLength: 8)

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

    private var iconName: String {
        guard !command.symbol.isEmpty,
              NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) != nil
        else { return "terminal" }
        return command.symbol
    }
}
