import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口。从菜单栏的「设置…」打开。
///
/// 原来导入导出挂在主窗口工具栏的「更多」菜单里，和这里的设置分成两处，
/// 现在统一收进来 —— 凡是"配置这个 App 本身"的操作都在这个窗口。
struct SRSettingsView: View {

    @EnvironmentObject private var model: SRAppModel
    @EnvironmentObject private var preferences: SRPreferences

    var body: some View {
        TabView {
            SRGeneralTab()
                .tabItem { Label(L("通用"), systemImage: "gearshape") }
            SRMenuAppearanceTab()
                .tabItem { Label(L("菜单"), systemImage: "list.bullet.indent") }
            SRTerminalTab()
                .tabItem { Label(L("终端"), systemImage: "terminal") }
            SREditorTab()
                .tabItem { Label(L("编辑器"), systemImage: "chevron.left.forwardslash.chevron.right") }
            SRConfigTab()
                .tabItem { Label(L("配置"), systemImage: "doc.text") }
            SRExtensionTab()
                .tabItem { Label(L("扩展"), systemImage: "puzzlepiece.extension") }
        }
        .padding(20)
        .frame(width: 600, height: 520)
    }
}

// MARK: - 通用

private struct SRGeneralTab: View {

    @EnvironmentObject private var preferences: SRPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SRSection(L("外观")) {
                    Picker(L("语言"), selection: $preferences.language) {
                        ForEach(SRLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .fixedSize()

                    Picker(L("主题"), selection: $preferences.theme) {
                        ForEach(SRThemePreference.allCases) { theme in
                            Text(theme.localizedName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(L("语言切换即时生效，无需重启。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SRSection(L("行为")) {
                    Toggle(L("后台命令失败时自动打开输出窗口"),
                           isOn: $preferences.openOutputOnFailure)
                    Text(L("关掉之后，后台命令失败只会静静地记在「运行输出」里。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 菜单外观

private struct SRMenuAppearanceTab: View {

    @EnvironmentObject private var model: SRAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SRSection(L("右键菜单")) {
                    Toggle(L("收进一个二级菜单"), isOn: $model.settings.useSubmenu)

                    Text(model.settings.useSubmenu
                         ? L("右键菜单里只出现一项，命令都在它的子菜单下。")
                         : L("所有命令直接平铺在右键菜单里。命令多了会很长，慎用。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.settings.useSubmenu {
                        LabeledContent(L("菜单名称")) {
                            TextField("SwiftRight", text: $model.settings.menuTitle)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent(L("菜单图标")) {
                            SRSymbolPicker(symbol: $model.settings.menuSymbol)
                        }
                    }

                    Toggle(L("在菜单项上显示图标"), isOn: $model.settings.showIcons)
                }

                SRSection(L("生效方式")) {
                    Text(L("改动会立即写入配置文件，访达扩展下一次右键就会读到，不需要重启访达。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 配置文件

private struct SRConfigTab: View {

    @EnvironmentObject private var model: SRAppModel

    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDocument: SRConfigDocument?
    @State private var importMerge = false
    @State private var alert: SRAlert?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SRSection(L("导入与导出")) {
                    Text(L("命令列表和菜单设置会被完整导出为一个 JSON 文件，方便在多台机器之间同步。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button(L("导出…")) {
                            exportDocument = SRConfigDocument(model: model)
                            showingExporter = true
                        }
                        Button(L("导入并追加…")) {
                            importMerge = true
                            showingImporter = true
                        }
                        Button(L("导入并替换…")) {
                            importMerge = false
                            showingImporter = true
                        }
                    }

                    Text(L("「追加」会保留你现有的命令；ID 冲突时导入的那条会重新分配 ID，不会覆盖。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SRSection(L("配置文件位置")) {
                    Text(SRPaths.configFile.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button(L("在访达中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([SRPaths.configFile])
                        }
                        Button(L("重新载入")) { model.load() }
                        Spacer()
                        Button(L("恢复示例命令")) { restoreExamples() }
                    }

                    Text(L("App 与访达扩展共用这一份文件。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
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
                alert = SRAlert(title: L("导出失败"), message: error.localizedDescription)
            }
        }
        .alert(alert?.title ?? "", isPresented: alertPresented, presenting: alert) { _ in
            Button(L("好"), role: .cancel) { alert = nil }
        } message: { item in
            Text(item.message)
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
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
                alert = SRAlert(title: L("导入失败"), message: error.localizedDescription)
            }
        case .failure(let error):
            alert = SRAlert(title: L("导入失败"), message: error.localizedDescription)
        }
    }

    private func restoreExamples() {
        let panel = NSAlert()
        panel.messageText = L("恢复示例命令？")
        panel.informativeText = L("示例命令会追加到现有列表末尾，不会删除你已有的命令。")
        panel.addButton(withTitle: L("追加"))
        panel.addButton(withTitle: L("取消"))
        guard panel.runModal() == .alertFirstButtonReturn else { return }

        var examples = SRCommand.builtinExamples()
        for index in examples.indices {
            examples[index].id = UUID()
            examples[index].sortIndex = model.commands.count + index
        }
        model.commands.append(contentsOf: examples)
    }
}

// MARK: - 扩展

private struct SRExtensionTab: View {

    @EnvironmentObject private var model: SRAppModel
    @State private var registerResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SRSection(L("访达扩展")) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.isExtensionEnabled ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(model.isExtensionEnabled ? L("扩展已启用") : L("扩展未启用"))
                            .font(.callout.weight(.medium))
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        step(1, L("把 SwiftRight.app 放进「应用程序」文件夹并至少打开一次，系统才会登记它的访达扩展。"))
                        step(2, L("打开「系统设置 › 通用 › 登录项与扩展」，在「访达扩展」里勾选 SwiftRight。"))
                        step(3, L("如果菜单还是不出现，重启一次访达。"))
                    }
                    .padding(.top, 2)

                    HStack(spacing: 8) {
                        Button(L("打开系统设置")) { model.openExtensionSettings() }
                        Button(L("重新注册扩展")) { registerResult = model.registerExtension() }
                        Button(L("重启访达")) { model.relaunchFinder() }
                    }

                    if let registerResult, !registerResult.isEmpty {
                        Text(registerResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .onAppear { model.refreshExtensionStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshExtensionStatus()
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
