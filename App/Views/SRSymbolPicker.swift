import SwiftUI

/// SF Symbol 选择器：一个可直接输入的名字输入框 + 常用图标网格。
struct SRSymbolPicker: View {

    @Binding var symbol: String
    @State private var showingGrid = false

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
        HStack(spacing: 8) {
            symbolPreview

            TextField("SF Symbol 名称", text: $symbol)
                .textFieldStyle(.roundedBorder)

            Button {
                showingGrid.toggle()
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .buttonStyle(.bordered)
            .help("从常用图标里挑一个")
            .popover(isPresented: $showingGrid, arrowEdge: .bottom) {
                grid
            }
        }
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

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8), spacing: 4) {
                ForEach(Self.suggestions, id: \.self) { name in
                    Button {
                        symbol = name
                        showingGrid = false
                    } label: {
                        Image(systemName: name)
                            .font(.system(size: 14))
                            .frame(width: 28, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(name == symbol
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
