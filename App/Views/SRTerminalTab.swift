import AppKit
import SwiftUI

/// 设置 › 终端。扫描本机终端、选默认、按需调启动参数。
struct SRTerminalTab: View {

    @ObservedObject private var catalog = SRTerminalCatalog.shared
    @ObservedObject private var preferences = SRPreferences.shared
    @State private var scanMessage: String?
    @State private var editingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            list
            options
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    runScan()
                } label: {
                    Label(L("扫描本机终端"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)

                Button(L("手动添加…")) { addManually() }

                Spacer()

                Text(L("共 %@ 个", String(catalog.terminals.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let scanMessage {
                Text(scanMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("「在终端中运行」的命令会交给这里选中的终端。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 列表

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(catalog.terminals) { terminal in
                    SRTerminalRow(
                        terminal: terminal,
                        isSelected: terminal.id == catalog.selectedID,
                        isExpanded: editingID == terminal.id,
                        onSelect: { catalog.selectedID = terminal.id },
                        onToggleEdit: {
                            editingID = editingID == terminal.id ? nil : terminal.id
                        }
                    )
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

    // MARK: - 底部选项

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("命令结束后保持终端打开"), isOn: $preferences.keepTerminalOpen)

            Text(L("kitty、WezTerm、Ghostty、rio 这类终端在命令退出时会连窗口一起关掉，短命令基本一闪而过。打开这项会在命令末尾接一个交互式 shell，并打印退出码。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L("各家终端的命令行约定不同，SwiftRight 为常见终端内置了启动配方。扫描到清单之外的应用时会退回到「用脚本文件打开」，能不能用请点「测试」验证。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 动作

    private func runScan() {
        let result = catalog.scan()
        var parts: [String] = []
        if result.added.isEmpty {
            parts.append(L("没有发现新终端。"))
        } else {
            parts.append(L("新增 %@ 个：", String(result.added.count))
                         + result.added.map(\.name).joined(separator: "、"))
        }
        if result.refreshed > 0 {
            parts.append(L("%@ 个更新了路径。", String(result.refreshed)))
        }
        if !result.removed.isEmpty {
            parts.append(L("移除已不存在的：") + result.removed.joined(separator: "、"))
        }
        scanMessage = parts.joined(separator: " ")
    }

    private func addManually() {
        let panel = NSOpenPanel()
        panel.title = L("选择终端应用")
        panel.prompt = L("添加")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let added = catalog.add(appAt: url) {
            scanMessage = L("已添加 %@。", added.name)
            editingID = added.id
        } else {
            scanMessage = L("这个应用没有 bundle identifier，无法添加。")
        }
    }
}

// MARK: - 单行

private struct SRTerminalRow: View {

    let terminal: SRTerminal
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggleEdit: () -> Void

    @ObservedObject private var catalog = SRTerminalCatalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            main
            if isExpanded {
                Divider().padding(.horizontal, 10)
                editor
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear)
        )
        .padding(.horizontal, 6)
    }

    private var main: some View {
        HStack(spacing: 10) {
            Image(nsImage: terminal.icon)
                .resizable()
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(terminal.name)
                        .fontWeight(isSelected ? .semibold : .regular)
                    if let version = terminal.version {
                        Text(version)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !terminal.isBuiltin {
                        Text(L("无内置配方"))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                }
                Text(terminal.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Button(L("测试")) {
                SRCommandRunner.shared.testTerminal(terminal)
            }
            .controlSize(.small)

            Button {
                onToggleEdit()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help(L("调整启动参数"))
        }
        .padding(10)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("启动方式"), selection: styleBinding) {
                ForEach(SRTerminalLaunchStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .fixedSize()

            if terminal.launchStyle == .arguments {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("参数模板"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", text: templateBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    Text(L("可用占位符：{dir} 工作目录、{shell} 解释器、{script} 脚本路径。按空格分词后再替换，所以路径里有空格也不会被拆开。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L("把生成的脚本当作文档交给这个应用打开。终端需要声明自己能处理 shell 脚本才有效。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if SRTerminal.recipes.contains(where: { $0.id == terminal.id }) {
                    Button(L("恢复内置配方")) { catalog.resetToRecipe(terminal.id) }
                        .controlSize(.small)
                }
                Spacer()
                Button(L("从列表移除"), role: .destructive) { catalog.remove(terminal.id) }
                    .controlSize(.small)
            }
        }
        .padding(10)
    }

    // MARK: - 绑定

    private var styleBinding: Binding<SRTerminalLaunchStyle> {
        Binding(
            get: { terminal.launchStyle },
            set: { newValue in
                var copy = terminal
                copy.launchStyle = newValue
                copy.isBuiltin = false
                catalog.update(copy)
            }
        )
    }

    private var templateBinding: Binding<String> {
        Binding(
            get: { terminal.argumentTemplate },
            set: { newValue in
                var copy = terminal
                copy.argumentTemplate = newValue
                copy.isBuiltin = false
                catalog.update(copy)
            }
        )
    }
}
