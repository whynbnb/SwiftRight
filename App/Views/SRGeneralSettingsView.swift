import AppKit
import SwiftUI

/// 全局设置：决定右键菜单长什么样。
struct SRGeneralSettingsView: View {

    @EnvironmentObject private var model: SRAppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SRDefaults.openOutputOnFailure) private var openOutputOnFailure = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(.title2.bold())
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    menuSection
                    behaviourSection
                    storageSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            Divider()

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
    }

    private var menuSection: some View {
        SRSection("菜单外观") {
            Toggle("收进一个二级菜单", isOn: $model.settings.useSubmenu)
            Text(model.settings.useSubmenu
                 ? "右键菜单里只出现一项「\(model.settings.menuTitle)」，命令都在它的子菜单下。"
                 : "所有命令直接平铺在右键菜单里。命令多了会很长，慎用。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.settings.useSubmenu {
                LabeledContent("菜单名称") {
                    TextField("SwiftRight", text: $model.settings.menuTitle)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("菜单图标") {
                    SRSymbolPicker(symbol: $model.settings.menuSymbol)
                }
            }

            Toggle("在菜单项上显示图标", isOn: $model.settings.showIcons)
        }
    }

    private var behaviourSection: some View {
        SRSection("行为") {
            Toggle("后台命令失败时自动打开输出窗口", isOn: $openOutputOnFailure)
            Text("否则后台命令失败只会静静地记在「运行输出」里。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        SRSection("配置文件") {
            Text(SRPaths.configFile.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([SRPaths.configFile])
                }
                Button("重新载入") { model.load() }
                Spacer()
                Button("恢复示例命令") { restoreExamples() }
            }

            Text("App 与访达扩展共用这一份文件，改完立即生效，不需要重启访达。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func restoreExamples() {
        let alert = NSAlert()
        alert.messageText = "恢复示例命令？"
        alert.informativeText = "示例命令会追加到现有列表末尾，不会删除你已有的命令。"
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var examples = SRCommand.builtinExamples()
        for index in examples.indices {
            examples[index].id = UUID()
            examples[index].sortIndex = model.commands.count + index
        }
        model.commands.append(contentsOf: examples)
    }
}
