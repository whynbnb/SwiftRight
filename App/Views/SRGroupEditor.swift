import SwiftUI

/// 分组设置弹窗：启用、标题、图标，以及是否收进共用二级菜单。
///
/// 主窗口侧栏和排序窗口的分组标题点开都是这一个弹窗，
/// 所以分组的配置跟着分组本身走，不再堆在设置页里。
struct SRGroupEditor: View {

    @EnvironmentObject private var model: SRAppModel

    /// 改名成功后通知调用方（排序窗口要同步筛选条件）。
    private let onRenamed: ((String, String) -> Void)?

    /// 当前分组名。改名成功后跟着更新，后续设置写到新名字上。
    @State private var name: String
    @State private var title: String
    @State private var symbol: String
    @State private var enabled: Bool
    @State private var inSubmenu: Bool

    init(group: String,
         model: SRAppModel,
         onRenamed: ((String, String) -> Void)? = nil) {
        self.onRenamed = onRenamed
        _name = State(initialValue: group)
        _title = State(initialValue: group)
        _symbol = State(initialValue: model.settings.symbol(for: group))
        _enabled = State(initialValue: !model.settings.isGroupHidden(group))
        _inSubmenu = State(initialValue: model.settings.isInSubmenu(group))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L("启用（显示在右键菜单中）"), isOn: $enabled)
                .toggleStyle(.switch)
                .onChange(of: enabled) { _, on in
                    model.setGroupHidden(!on, for: name)
                }

            Divider()

            LabeledContent(L("标题")) {
                TextField(L("分组名称"), text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitTitle)
            }

            LabeledContent(L("图标")) {
                SRSymbolPicker(symbol: $symbol)
            }
            .onChange(of: symbol) { _, newValue in
                model.setGroupSymbol(newValue, for: name)
            }

            Toggle(L("收进二级菜单"), isOn: $inSubmenu)
                .onChange(of: inSubmenu) { _, on in
                    model.setGroupInSubmenu(on, for: name)
                }

            Text(L("收进二级菜单后，这个分组会出现在「%@」下面。", secondaryMenuTitle))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
        // 点弹窗外面关闭时，把还没提交的标题改名补上。
        .onDisappear(perform: commitTitle)
    }

    private var secondaryMenuTitle: String {
        let title = model.settings.menuTitle.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "SwiftRight" : title
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            title = name
            return
        }
        guard trimmed != name else { return }
        model.renameGroup(from: name, to: trimmed)
        onRenamed?(name, trimmed)
        name = trimmed
    }
}
