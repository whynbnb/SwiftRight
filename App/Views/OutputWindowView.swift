import AppKit
import SwiftUI

/// 运行输出窗口：左边是最近的执行记录，右边是对应的 stdout / stderr。
struct OutputWindowView: View {

    @EnvironmentObject private var runner: SRCommandRunner
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            sessionList
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 480, minHeight: 300)
        .onAppear(perform: syncSelection)
        .onChange(of: runner.focusedSession?.id) { syncSelection() }
    }

    // MARK: - 记录列表

    private var sessionList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(runner.sessions) { session in
                    SRSessionRow(session: session)
                        .tag(session.id)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Text("\(runner.sessions.count) 条记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空") { runner.clearHistory() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(runner.sessions.allSatisfy(\.isRunning))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session = runner.sessions.first(where: { $0.id == selection }) {
            SRSessionDetailView(session: session)
                .id(session.id)
        } else {
            ContentUnavailableView("还没有运行记录",
                                   systemImage: "text.alignleft",
                                   description: Text("从访达右键菜单执行一条命令，或者在编辑器里点「试运行」。"))
        }
    }

    private func syncSelection() {
        if let focused = runner.focusedSession {
            selection = focused.id
        } else if selection == nil || !runner.sessions.contains(where: { $0.id == selection }) {
            selection = runner.sessions.first?.id
        }
    }
}

// MARK: - 行

private struct SRSessionRow: View {

    @ObservedObject var session: SRRunSession

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .lineLimit(1)
                Text(session.startedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if session.isRunning {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16)
        } else if session.succeeded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 16)
        } else {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .frame(width: 16)
        }
    }
}

// MARK: - 详情

private struct SRSessionDetailView: View {

    @ObservedObject var session: SRRunSession
    @State private var showingScript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            outputArea
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(session.title)
                    .font(.headline)

                Text(session.statusText)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(statusColor.opacity(0.18))
                    )
                    .foregroundStyle(statusColor)

                Spacer()

                if session.isRunning {
                    Button("停止") { session.cancel() }
                        .controlSize(.small)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.output, forType: .string)
                } label: {
                    Label("拷贝输出", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(session.output.isEmpty)
            }

            HStack(spacing: 6) {
                Text("耗时 \(String(format: "%.2f", session.duration))s")
                Text("·")
                Text("\(session.paths.count) 个项目")
                Text("·")
                Button(session.workingDirectory) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: session.workingDirectory)]
                    )
                }
                .buttonStyle(.link)
                .lineLimit(1)
                .truncationMode(.head)
                Spacer()
                Button(showingScript ? "隐藏脚本" : "查看脚本") {
                    showingScript.toggle()
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if showingScript {
                ScrollView {
                    Text(session.resolvedScript)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
            }
        }
        .padding(14)
    }

    private var statusColor: Color {
        if session.isRunning { return .accentColor }
        return session.succeeded ? .green : .orange
    }

    private var outputArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(session.output.isEmpty
                     ? (session.isRunning ? "等待输出…" : "（没有输出）")
                     : session.output)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(session.output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .id("output-bottom")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: session.output) {
                // 跟着新输出往下滚，像终端一样。
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("output-bottom", anchor: .bottom)
                }
            }
        }
    }
}
