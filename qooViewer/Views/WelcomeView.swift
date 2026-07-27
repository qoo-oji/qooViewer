import SwiftUI
import UniformTypeIdentifiers

/// 起動時、まだ何も開いていないときに表示する画面。
/// 本棚は持たないので、ここから「開く」パネル、またはドラッグ&ドロップで
/// フォルダ/アーカイブファイルを直接開く。
struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Open a manga folder, or a\nzip/cbz, rar/cbr, 7z/cb7, or PDF file")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open…") {
                appState.openWithPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            Text("You can also open by dragging and dropping here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    appState.open(url: url)
                }
            }
            return true
        }
    }
}
