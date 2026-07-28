import SwiftUI
import UniformTypeIdentifiers

/// 起動時、まだ何も開いていないときに表示する画面。
/// 本棚は持たないので、ここから「開く」パネル、またはドラッグ&ドロップで
/// フォルダ/アーカイブファイルを直接開く。
///
/// 要望7により、「最近開いたファイル」「最近お気に入りに追加したファイル」を各最大10件表示し、
/// クリックで直接開けるようにしている。どちらも表示前に存在確認済みのものだけが渡ってくる
/// (RecentFilesStore.entries / FavoritesStore.recentFavorites(limit:)参照)。
/// それぞれ環境設定でON/OFFできる(既定はON。AppPreferences.showRecentFilesOnWelcome /
/// showRecentFavoritesOnWelcome、GeneralSettingsView.swift参照)。
struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var recentFiles: RecentFilesStore
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @State private var isTargeted = false

    var body: some View {
        let recentEntries = preferences.showRecentFilesOnWelcome ? recentFiles.entries : []
        // 表示のたびにセキュリティスコープ付きブックマークの解決・存在確認を行うため、
        // bodyの中で1回だけ計算して使い回す(isEmptyの判定とForEachの両方で同じ結果を使う)。
        let recentFavoriteBooks = preferences.showRecentFavoritesOnWelcome
            ? favoritesStore.recentFavorites(limit: 10)
            : []

        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Open a manga folder, or a\nzip/cbz, rar/cbr, 7z/cb7, PDF, or EPUB file")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open…") {
                appState.openWithPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            Text("You can also open by dragging and dropping here")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if !recentEntries.isEmpty || !recentFavoriteBooks.isEmpty {
                Divider()
                    .padding(.top, 8)

                HStack(alignment: .top, spacing: 32) {
                    if !recentEntries.isEmpty {
                        WelcomeQuickOpenList(
                            title: String(localized: "Recent Files"),
                            items: recentEntries.map { entry in
                                WelcomeQuickOpenItem(id: entry.id, title: entry.displayName) {
                                    appState.open(url: entry.url)
                                }
                            }
                        )
                    }

                    if !recentFavoriteBooks.isEmpty {
                        WelcomeQuickOpenList(
                            title: String(localized: "Recent Favorites"),
                            items: recentFavoriteBooks.map { favorite in
                                WelcomeQuickOpenItem(id: favorite.id.uuidString, title: favorite.title) {
                                    appState.openFavorite(favorite)
                                }
                            }
                        )
                    }
                }
                .frame(maxWidth: 520)
            }
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

/// ウェルカム画面の「最近開いたファイル」「最近お気に入りに追加したファイル」で共通して使う、
/// 1件分の項目。
private struct WelcomeQuickOpenItem: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
}

private struct WelcomeQuickOpenList: View {
    let title: String
    let items: [WelcomeQuickOpenItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                Button(item.title) {
                    item.action()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
