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

    var body: some View {
        // 履歴の保持件数(AppPreferences.recentFilesLimit)は環境設定で増やせるが、この画面の
        // 一覧は縦に伸びすぎないよう従来どおり10件までに留める(全件はサイドパネルの
        // 「履歴」モード、またはファイルメニューの「Open Recent」で見られる)。
        // シークレットウインドウでは履歴を一切見せない(AppState.isPrivateWindowのコメント参照)。
        let recentEntries = preferences.showRecentFilesOnWelcome && !appState.isPrivateWindow
            ? Array(recentFiles.entries.prefix(10))
            : []
        // 表示のたびにセキュリティスコープ付きブックマークの解決・存在確認を行うため、
        // bodyの中で1回だけ計算して使い回す(isEmptyの判定とForEachの両方で同じ結果を使う)。
        // 「最近のお気に入り」も同様に出さない(ユーザー要望。登録済みデータではあるが、
        // 「最近」という切り口自体が利用の痕跡を映すため)。
        let recentFavoriteBooks = preferences.showRecentFavoritesOnWelcome && !appState.isPrivateWindow
            ? favoritesStore.recentFavorites(limit: 10)
            : []

        VStack(spacing: 16) {
            if appState.isPrivateWindow {
                // シークレットウインドウであることと、その意味(何も記録されない)を、本を開く前に
                // 明示する。タイトルバーの「(シークレット)」だけでは見落とされるため。
                VStack(spacing: 6) {
                    Label("Private Window", systemImage: "eyeglasses")
                        .font(.headline)
                    Text("Books opened in this window leave no trace: no history, reading position, bookmarks, favorites, layouts, metadata, or thumbnail cache is saved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                // 文字だけの塊なので、面の「文字の影」設定に乗せる(すりガラス面の決まりごと。
                // CLAUDE.mdとpanelOutlinedContentのコメント参照。以下の文字・アイコンも同じ)。
                .panelOutlinedContent()
                .padding(.bottom, 8)
            }
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
            Text("Open a manga folder, or a\nzip/cbz, rar/cbr, 7z/cb7, PDF, or EPUB file")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
            // 「開く…」ボタンは自前の不透明な地を持つ部品なので、輪郭は付けない
            // (すりガラス面の決まりごとの例外側)。
            Button("Open…") {
                appState.openWithPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            Text("You can also open by dragging and dropping here")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .panelOutlinedContent()

            if !recentEntries.isEmpty || !recentFavoriteBooks.isEmpty {
                Divider()
                    .padding(.top, 8)

                HStack(alignment: .top, spacing: 32) {
                    if !recentEntries.isEmpty {
                        WelcomeQuickOpenList(
                            title: String(localized: "Recent Files"),
                            items: recentEntries.map { entry in
                                // bookIDはキャッシュ済みのパス。ここでブックマークを解決しては
                                // いけない(RecentFilesStoreの型コメント参照)。解決するのは
                                // 実際に選ばれた瞬間だけ。
                                WelcomeQuickOpenItem(id: entry.id, title: entry.displayName, bookID: entry.path) {
                                    guard let url = recentFiles.resolveForOpening(entry) else { return }
                                    appState.open(url: url)
                                }
                            }
                        )
                    }

                    if !recentFavoriteBooks.isEmpty {
                        WelcomeQuickOpenList(
                            title: String(localized: "Recent Favorites"),
                            items: recentFavoriteBooks.map { favorite in
                                WelcomeQuickOpenItem(id: favorite.id.uuidString, title: favorite.title, bookID: favorite.bookID) {
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
        // 環境設定「外観」の「ウェルカム画面」に従う背景。「ウインドウの背後を透かす」
        // (welcomeGlass。既定OFF)がONのときだけ、背後のウインドウ/デスクトップが
        // わずかに透けるすりガラス+重ね色を敷く(ユーザー要望: のっぺりして見える。
        // ただし既定では従来どおり、ウインドウの地の色のまま何も敷かない ―― 従来からの
        // ユーザーは設定を変更しなければ見た目が変わらないこと、というユーザーの指定)。
        // .underWindowBackgroundは「ウインドウのコンテンツ背景」用のいちばん控えめな
        // マテリアルで、メモ.appの本文背景などと同じもの。2層の構成の意味は
        // panelSurfaceBackgroundと同じだが、画面全体に敷くため安全領域も無視して広げる。
        .panelContentOutline(
            width: preferences.welcomeGlass
                ? PanelContentShadow.outlineWidth(
                    forLevel: preferences.welcomeSurfaceStyle.contentShadowLevel
                )
                : 0
        )
        .background {
            if preferences.welcomeGlass {
                ZStack {
                    BehindWindowVisualEffectView(material: .underWindowBackground)
                        .opacity(preferences.welcomeSurfaceStyle.materialOpacity)
                    preferences.welcomeSurfaceStyle.resolvedTint
                }
                .ignoresSafeArea()
            }
        }
        // ファイル/フォルダのドロップは、ウェルカム画面だけでなくビューア画面・サイドパネルも
        // 含めたウインドウ全体で受ける(ContentView.applyFileDropTarget参照)。
    }
}

/// ウェルカム画面の「最近開いたファイル」「最近お気に入りに追加したファイル」で共通して使う、
/// 1件分の項目。
private struct WelcomeQuickOpenItem: Identifiable {
    let id: String
    let title: String
    /// MangaBook.idと同じ形式(拡張子を含むフルパス)の文字列。同名のcbz/epubが並んだときに
    /// 拡張子バッジ(FormatBadgeView)で見分けられるようにするため保持する(ユーザー報告:
    /// タイトルは拡張子を除いた名前で表示するため、epubとcbzの見分けがつかない)。
    let bookID: String
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
                .panelOutlinedContent()
            ForEach(items) { item in
                Button {
                    item.action()
                } label: {
                    HStack(spacing: 6) {
                        // 輪郭は文字だけに掛ける。拡張子バッジ(FormatBadgeView)は自前の
                        // 塗り地を持つので付けない(すりガラス面の決まりごとの例外側)。
                        Text(item.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .panelOutlinedContent()
                        FormatBadgeView(bookID: item.bookID)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
