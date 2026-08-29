import AppKit
import SwiftUI

/// 侧边栏底部常驻的扩展状态条。
///
/// 这是最容易踩坑的地方：命令配好了，但扩展没在系统设置里勾选，
/// 右键菜单就什么都不会出现。所以状态必须一直摆在眼前。
///
/// 具体的排查步骤和操作按钮都在设置窗口的「扩展」页，这里只做状态提示和入口。
struct SRExtensionStatusBar: View {

    @EnvironmentObject private var model: SRAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 写盘失败必须让用户看见：否则改了半天命令，右键菜单纹丝不动，
            // 根本猜不到是权限或磁盘问题。
            if let error = model.lastSaveError {
                Label(L("配置保存失败：") + error,
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(model.isExtensionEnabled ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                Text(model.isExtensionEnabled ? L("扩展已启用") : L("扩展未启用"))
                    .font(.callout)

                Spacer(minLength: 4)

                Button {
                    SRWindowManager.shared.showSettings()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help(L("怎么让右键菜单出现"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { model.refreshExtensionStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // 用户去系统设置勾完再切回来，状态要马上跟上。
            model.refreshExtensionStatus()
        }
    }
}
