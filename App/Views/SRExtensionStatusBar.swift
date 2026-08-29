import AppKit
import SwiftUI

/// 侧边栏底部常驻的扩展状态条。
///
/// 这是最容易踩坑的地方：命令配好了，但扩展没在系统设置里勾选，
/// 右键菜单就什么都不会出现。所以状态必须一直摆在眼前。
struct SRExtensionStatusBar: View {

    @EnvironmentObject private var model: SRAppModel
    @State private var showingHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 写盘失败必须让用户看见：否则改了半天命令，右键菜单纹丝不动，
            // 根本猜不到是权限或磁盘问题。
            if let error = model.lastSaveError {
                Label("配置保存失败：\(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(model.isExtensionEnabled ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                Text(model.isExtensionEnabled ? "扩展已启用" : "扩展未启用")
                    .font(.callout)

                Spacer(minLength: 4)

                Button {
                    showingHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("怎么让右键菜单出现")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .popover(isPresented: $showingHelp, arrowEdge: .top) {
            SRExtensionHelpView()
                .environmentObject(model)
        }
        .onAppear { model.refreshExtensionStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // 用户去系统设置勾完再切回来，状态要马上跟上。
            model.refreshExtensionStatus()
        }
    }
}

struct SRExtensionHelpView: View {

    @EnvironmentObject private var model: SRAppModel
    @State private var registerResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("让右键菜单出现")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "把 SwiftRight.app 放进「应用程序」文件夹并至少打开一次，"
                        + "系统才会登记它的 Finder 扩展。")
                step(2, "打开「系统设置 › 通用 › 登录项与扩展」，"
                        + "在「访达扩展」里勾选 SwiftRight。")
                step(3, "如果菜单还是不出现，重启一次访达。")
            }

            Divider()

            HStack(spacing: 8) {
                Button("打开系统设置") { model.openExtensionSettings() }
                Button("重新注册扩展") { registerResult = model.registerExtension() }
                Button("重启访达") { model.relaunchFinder() }
            }

            if let registerResult, !registerResult.isEmpty {
                Text(registerResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 380)
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
