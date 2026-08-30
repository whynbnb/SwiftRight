import AppKit
import SwiftUI

/// 设置 › 新建文件。管理模板，并把模板加成右键命令。
struct SRTemplateTab: View {

    @ObservedObject private var store = SRTemplateStore.shared
    @ObservedObject private var model = SRAppModel.shared
    @State private var selection: UUID?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            HStack(spacing: 10) {
                templateList
                    .frame(width: 176)
                detail
            }
            footer
        }
        .onAppear {
            if selection == nil { selection = store.templates.first?.id }
        }
    }

    // MARK: - 顶部

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    let t = store.add()
                    selection = t.id
                } label: {
                    Label(L("新建模板"), systemImage: "plus")
                }

                Button(L("加到菜单")) {
                    guard let template = selected else { return }
                    model.addTemplateCommand(for: template)
                    message = L("已加入右键菜单。")
                }
                .disabled(selected == nil || alreadyInMenu)

                Button(L("全部加入")) {
                    let n = model.addTemplateCommands(for: store.templates)
                    message = n == 0 ? L("菜单里已经都有了。")
                                     : L("新增 %@ 条右键命令。", String(n))
                }

                Spacer()

                Button(L("恢复内置模板")) {
                    let n = store.restoreBuiltins()
                    message = n == 0 ? L("内置模板都在。") : L("补回 %@ 个模板。", String(n))
                }
                .controlSize(.small)
            }

            Text(message ?? L("命令会出现在右键菜单的「新建文件」分组里，只在文件夹上和窗口空白处显示。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 左侧列表

    private var templateList: some View {
        List(selection: $selection) {
            ForEach(store.templates) { template in
                HStack(spacing: 7) {
                    Image(systemName: iconName(template))
                        .frame(width: 16)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(template.name).lineLimit(1)
                        Text(template.displayExtension)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if model.templateCommand(for: template.id) != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                .tag(template.id)
            }
            .onMove { store.move(from: $0, to: $1) }
        }
        .listStyle(.bordered)
    }

    // MARK: - 右侧编辑

    @ViewBuilder
    private var detail: some View {
        if let template = selected {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField(L("模板名称"), text: binding(\.name))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        store.remove(template.id)
                        selection = store.templates.first?.id
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(L("删除这个模板"))
                }

                HStack(spacing: 6) {
                    TextField(L("默认文件名"), text: binding(\.defaultName))
                        .textFieldStyle(.roundedBorder)
                    Text(".")
                        .foregroundStyle(.secondary)
                    TextField(L("后缀"), text: binding(\.fileExtension))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 66)
                }

                SRSymbolPicker(symbol: binding(\.symbol))

                Toggle(L("建好后加可执行权限"), isOn: binding(\.isExecutable))
                    .controlSize(.small)

                Text(L("文件初始内容"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SRScriptEditor(text: binding(\.content), pendingInsertion: .constant(nil))
                    .frame(minHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )

                Text(L("重名会自动加序号：%@ 被占用就建 %@。",
                       previewName(template, suffix: ""),
                       previewName(template, suffix: " 2")))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack {
                Spacer()
                Text(L("左边选一个模板，或者新建一个。"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        Text(L("生成的命令是一条普通脚本命令，可以在主窗口里继续改。改模板会自动同步到已生成的那条命令。"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 辅助

    private var selected: SRFileTemplate? {
        guard let selection else { return nil }
        return store.templates.first { $0.id == selection }
    }

    private var alreadyInMenu: Bool {
        guard let selected else { return false }
        return model.templateCommand(for: selected.id) != nil
    }

    private func iconName(_ template: SRFileTemplate) -> String {
        guard !template.symbol.isEmpty,
              NSImage(systemSymbolName: template.symbol, accessibilityDescription: nil) != nil
        else { return "doc" }
        return template.symbol
    }

    private func previewName(_ template: SRFileTemplate, suffix: String) -> String {
        let base = template.defaultName.isEmpty ? "untitled" : template.defaultName
        return base + suffix + template.displayExtension
    }

    /// 按 id 查而不是按下标 —— 列表可以拖拽排序，下标会失效。
    private func binding<Value>(_ keyPath: WritableKeyPath<SRFileTemplate, Value>)
        -> Binding<Value> {
        Binding(
            get: { selected?[keyPath: keyPath] ?? store.templates[0][keyPath: keyPath] },
            set: { newValue in
                guard var template = selected else { return }
                template[keyPath: keyPath] = newValue
                store.update(template)
            }
        )
    }
}
