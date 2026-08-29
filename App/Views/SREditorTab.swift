import AppKit
import SwiftUI

/// 设置 › 编辑器。扫描本机编辑器，一键生成「在此处打开 X」命令。
struct SREditorTab: View {

    @ObservedObject private var catalog = SREditorCatalog.shared
    @ObservedObject private var model = SRAppModel.shared
    @State private var scanMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            list
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    runScan()
                } label: {
                    Label(L("扫描本机编辑器"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)

                Button(L("手动添加…")) { addManually() }

                Button(L("为全部创建")) {
                    let n = model.addEditorCommands(for: catalog.editors)
                    scanMessage = n == 0 ? L("菜单里已经都有了。")
                                         : L("新增 %@ 条右键命令。", String(n))
                }

                Spacer()

                Text(L("共 %@ 个", String(catalog.editors.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(scanMessage ?? L("「加到菜单」会生成一条 open -b <bundle id> 的命令，按 bundle id 打开，应用升级搬家都不会失效。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(catalog.editors) { editor in
                    SREditorRow(editor: editor)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var footer: some View {
        Text(L("标着「工程」的编辑器能把文件夹当工程打开，生成的命令对文件和文件夹都生效；其余只对文件生效。判断不对的话可以在每一行里改。"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func runScan() {
        let result = catalog.scan()
        var parts: [String] = []
        if result.added.isEmpty {
            parts.append(L("没有发现新编辑器。"))
        } else {
            parts.append(L("新增 %@ 个：", String(result.added.count))
                         + result.added.map(\.name).joined(separator: "、"))
        }
        if result.refreshed > 0 { parts.append(L("%@ 个更新了路径。", String(result.refreshed))) }
        if !result.removed.isEmpty {
            parts.append(L("移除已不存在的：") + result.removed.joined(separator: "、"))
        }
        scanMessage = parts.joined(separator: " ")
    }

    private func addManually() {
        let panel = NSOpenPanel()
        panel.title = L("选择编辑器应用")
        panel.prompt = L("添加")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let added = catalog.add(appAt: url) {
            scanMessage = L("已添加 %@。", added.name)
        } else {
            scanMessage = L("这个应用没有 bundle identifier，无法添加。")
        }
    }
}

// MARK: - 单行

private struct SREditorRow: View {

    let editor: SREditor

    @ObservedObject private var catalog = SREditorCatalog.shared
    @ObservedObject private var model = SRAppModel.shared

    private var hasCommand: Bool { model.editorCommand(for: editor.id) != nil }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: editor.icon)
                .resizable()
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(editor.name)
                    if let version = editor.version {
                        Text(version)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if editor.opensFolders {
                        Text(L("工程"))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(editor.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Toggle(L("可开工程"), isOn: foldersBinding)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .labelsHidden()
                .help(L("能把文件夹当工程打开"))

            Button(hasCommand ? L("已在菜单中") : L("加到菜单")) {
                model.addEditorCommand(for: editor)
            }
            .controlSize(.small)
            .disabled(hasCommand)

            Button {
                catalog.remove(editor.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help(L("从列表移除"))
        }
        .padding(10)
        .padding(.horizontal, 6)
    }

    private var foldersBinding: Binding<Bool> {
        Binding(
            get: { editor.opensFolders },
            set: { newValue in
                var copy = editor
                copy.opensFolders = newValue
                copy.isBuiltin = false
                catalog.update(copy)
            }
        )
    }
}
