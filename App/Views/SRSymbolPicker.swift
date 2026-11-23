import SwiftUI

/// SF Symbol 选择器：一个可直接输入的名字输入框 + 常用图标网格。
struct SRSymbolPicker: View {

    @Binding var symbol: String
    /// 紧凑模式：只显示图标本身，点击弹出选择器。用于列表行内。
    var compact: Bool = false
    var compactTint: Color? = nil
    @State private var showingGrid = false
    /// 紧凑模式下的临时选择。点「完成」才写回 symbol，
    /// 这样选图标时父视图不会因为绑定变化把弹窗刷新掉。
    @State private var draftSymbol = ""

    private static let suggestions: [String] = [
        "terminal", "apple.terminal", "bolt.circle", "wand.and.stars", "gearshape",
        "hammer", "wrench.and.screwdriver", "play.circle", "arrow.right.circle",
        "doc", "doc.on.clipboard", "doc.text.magnifyingglass", "folder", "folder.badge.gearshape",
        "archivebox", "shippingbox", "arrow.down.circle", "arrow.up.circle", "arrow.triangle.2.circlepath",
        "photo", "photo.on.rectangle", "film", "music.note", "waveform",
        "trash", "scissors", "square.on.square", "rectangle.and.pencil.and.ellipsis",
        "magnifyingglass", "number.square", "textformat.abc", "text.alignleft",
        "lock", "lock.open", "key", "shield", "checkmark.seal",
        "arrow.triangle.branch", "chevron.left.forwardslash.chevron.right", "curlybraces",
        "network", "globe", "link", "paperplane", "envelope",
        "internaldrive", "externaldrive", "server.rack", "cpu", "memorychip",
        "square.and.arrow.up", "square.and.arrow.down", "tray.and.arrow.down",
        "star", "flag", "tag", "bookmark", "pin", "clock", "calendar",
    ]

    var body: some View {
        if compact {
            compactButton
        } else {
            HStack(spacing: 8) {
                symbolPreview

                TextField(L("SF Symbol 名称"), text: $symbol)
                    .textFieldStyle(.roundedBorder)

                Button {
                    showingGrid.toggle()
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .buttonStyle(.bordered)
                .help(L("从常用图标里挑一个"))
                .popover(isPresented: $showingGrid, arrowEdge: .bottom) {
                    grid(selected: symbol)
                }
            }
        }
    }

    private var compactButton: some View {
        Button {
            draftSymbol = symbol
            showingGrid.toggle()
        } label: {
            Image(systemName: previewSymbol)
                .font(.system(size: 14))
                .foregroundStyle(compactTint ?? Color.primary)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("选择图标"))
        .popover(isPresented: $showingGrid, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField(L("SF Symbol 名称"), text: $draftSymbol)
                        .textFieldStyle(.roundedBorder)
                    Button(L("完成")) {
                        symbol = draftSymbol
                        showingGrid = false
                    }
                }
                grid(selected: draftSymbol)
            }
            .padding(10)
        }
    }

    private var previewSymbol: String {
        if !symbol.isEmpty,
           NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            return symbol
        }
        return "questionmark"
    }

    @ViewBuilder
    private var symbolPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
            if !symbol.isEmpty, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                Image(systemName: symbol)
                    .font(.system(size: 14))
            } else {
                // 名字打错时直接告诉用户，别等到菜单里才发现图标没了。
                Image(systemName: "questionmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 28, height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    private func grid(selected: String) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8), spacing: 4) {
                ForEach(Self.suggestions, id: \.self) { name in
                    Button {
                        if compact {
                            // 只改临时值，等「完成」再写回。
                            draftSymbol = name
                        } else {
                            symbol = name
                            showingGrid = false
                        }
                    } label: {
                        Image(systemName: name)
                            .font(.system(size: 14))
                            .frame(width: 28, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(name == selected
                                          ? Color.accentColor.opacity(0.25)
                                          : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            .padding(10)
        }
        .frame(width: 300, height: 260)
    }
}
