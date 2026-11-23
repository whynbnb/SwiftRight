import AppKit
import SwiftUI

/// 关于窗口。
struct SRAboutView: View {

    /// 所有信息都从 Info.plist 读，不在代码里硬编码 ——
    /// 改了 project.yml 里的版本号或包名，这里自动跟上。
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "SwiftRight"
    }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "—"
    }

    private let repositorySlug = "whynbnb/SwiftRight"
    private let repositoryURL = URL(string: "https://github.com/whynbnb/SwiftRight")!
    private let licenseURL = URL(string: "https://github.com/whynbnb/SwiftRight/blob/main/LICENSE")!

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                icon
                Text(appName)
                    .font(.system(size: 34, weight: .bold))
                Text(L("访达右键菜单扩展 · 自定义命令 / 终端 / 编辑器 / 新建文件"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 26)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                row(L("版本")) { Text(version) }
                row(L("包名")) {
                    Text(bundleID)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                row(L("仓库")) { Link(repositorySlug, destination: repositoryURL) }
                row(L("开源协议")) { Link("MIT License", destination: licenseURL) }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var icon: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: 112, height: 112)
    }

    /// 左边标签右对齐、右边内容左对齐，各行的冒号位置才会齐。
    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }
}
