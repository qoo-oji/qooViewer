import AppKit
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
    /// アプリ内の表示言語(CLAUDE.md参照。OSのロケールとは独立)。一覧の見出しと形式バッジの
    /// 幅を実測するために、表示に使うのと同じ訳語を引く必要がある。
    @Environment(\.locale) private var locale
    /// この画面が実際に描画されている幅(= ウインドウの内容領域の幅)。
    /// 一覧の列幅の上限として使う(WelcomeQuickOpenWidth参照)。
    @State private var containerWidth: CGFloat = 0

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

        // 見出しは表示用と幅の実測用で同じ文字列でなければならないため、環境のロケール
        // (アプリ内の表示言語)で1回だけ解決してから両方に使う。
        let columns = [
            recentEntries.isEmpty ? nil : WelcomeQuickOpenColumn(
                title: String(localized: "Recent Files", language: locale),
                items: recentEntries.map { entry in
                    // bookIDはキャッシュ済みのパス。ここでブックマークを解決しては
                    // いけない(RecentFilesStoreの型コメント参照)。解決するのは
                    // 実際に選ばれた瞬間だけ。
                    WelcomeQuickOpenItem(
                        id: entry.id,
                        title: entry.displayName,
                        bookID: entry.path,
                        action: {
                            guard let url = recentFiles.resolveForOpening(entry) else { return }
                            appState.open(url: url)
                        },
                        // ユーザー要望: 履歴から1件だけ消せるようにする。
                        // ファイルの実体には触れない(サイドパネルの「履歴」モードの
                        // 同じ項目と対になる操作。RecentFilesStore.remove(_:)参照)。
                        destructiveActionTitleKey: "Remove from History",
                        destructiveAction: { recentFiles.remove(entry) }
                    )
                }
            ),
            recentFavoriteBooks.isEmpty ? nil : WelcomeQuickOpenColumn(
                title: String(localized: "Recent Favorites", language: locale),
                items: recentFavoriteBooks.map { favorite in
                    WelcomeQuickOpenItem(
                        id: favorite.id.uuidString, title: favorite.title, bookID: favorite.bookID
                    ) {
                        appState.openFavorite(favorite)
                    }
                }
            ),
        ].compactMap { $0 }

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

            if !columns.isEmpty {
                Divider()
                    .padding(.top, 8)

                // 列幅は固定値ではなく、実際に並ぶファイル名と形式バッジの幅、そして
                // ウインドウの幅から決める(ユーザー要望: 幅が狭くてファイル名が省略され、
                // 何の本か分からない)。WelcomeQuickOpenWidth参照。
                let widths = WelcomeQuickOpenWidth.resolved(
                    for: columns, availableWidth: containerWidth, locale: locale
                )
                HStack(alignment: .top, spacing: WelcomeQuickOpenWidth.columnSpacing) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        WelcomeQuickOpenList(column: column, width: widths[index])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 列幅の上限に使うウインドウ幅。測っているのは「画面いっぱいに広がる外枠」なので、
        // ここで決まる列幅が測定対象の幅を変えることはなく、レイアウトのループにはならない。
        // 1px単位のちらつきで再計算が走らないよう丸めてから受け取る。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width.rounded()
        } action: { newWidth in
            containerWidth = newWidth
        }
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
    /// 非nilなら右クリックメニューに破壊的な項目を1つ出す(「最近開いたファイル」の
    /// 「履歴から削除」用。ユーザー要望)。「最近お気に入りに追加したファイル」側は
    /// nilのまま ―― そちらで消せるのは登録そのもの(お気に入りの削除)で、意味が違う。
    /// お気に入りの整理は専用の「お気に入りを整理」ウインドウが担う。
    var destructiveActionTitleKey: LocalizedStringKey?
    var destructiveAction: (() -> Void)?
}

/// 一覧1つ分(「最近開いたファイル」または「最近のお気に入り」)。
private struct WelcomeQuickOpenColumn: Identifiable {
    /// 画面には同じ見出しの列が2つ並ぶことはないので、見出しをそのままIDにできる。
    var id: String { title }
    /// ロケール解決済みの見出し。表示にも幅の実測にも同じ文字列を使う。
    let title: String
    let items: [WelcomeQuickOpenItem]
}

/// ウェルカム画面の「最近開いたファイル」「最近のお気に入り」の列幅を決める計算。
///
/// ユーザー要望: 列が狭くてファイル名が「…」で省略され、何の本か分からないので、実際に
/// 表示するファイル名の長さを実測し、ウインドウの幅を考慮して自動調整してほしい。加えて、
/// 行末に付く形式バッジ(FormatBadgeView)の幅も見込むこと ―― バッジは「7Z」から
/// 「フォルダ」まで幅が違うので、一律の固定値では足りないか広すぎるかになる。
///
/// SidebarWidthEstimator / ExportColumnWidthEstimatorと同じ考え方(NSStringの実測)だが、
/// あちらが「ウインドウを開いた時点で1回だけ決める」のに対し、こちらはウインドウの幅に
/// 収める必要があるため、リサイズに追従して毎回計算し直す。
private enum WelcomeQuickOpenWidth {
    /// 2つの列の間隔。HStackのspacingと、ここでの見積もりで同じ値を使う。
    static let columnSpacing: CGFloat = 32
    /// 行の中の「ファイル名 ↔ 形式バッジ」の間隔。row(for:)のHStackと共通。
    static let rowBadgeSpacing: CGFloat = 6
    /// 名前が短いときでも、これより狭くはしない下限。
    private static let minColumn: CGFloat = 160
    /// 名前が極端に長くても、ウェルカム画面の中央の塊が横に伸びすぎないための上限。
    /// SidebarWidthEstimatorの上限と同じ値。
    private static let maxColumn: CGFloat = 560
    /// ウインドウの左右の端に残す余白。一覧が窓枠に張り付いて見えないようにするため。
    private static let windowMargin: CGFloat = 32
    /// 幅の実測(onGeometryChange)が届く前の最初の1フレームで使う想定幅。従来の固定幅と
    /// 同じ520にしてあるので、狭いウインドウでも初回に横へはみ出すことはない。
    private static let assumedWidth: CGFloat = 520

    /// 各列に実際に与える幅。全部の列の希望幅がウインドウに収まるならそのまま、収まらない
    /// ときは希望幅の比で按分する(長い名前が並ぶ列のほうを広くする)。
    static func resolved(
        for columns: [WelcomeQuickOpenColumn], availableWidth: CGFloat, locale: Locale
    ) -> [CGFloat] {
        guard !columns.isEmpty else { return [] }
        let ideals = columns.map { ideal(for: $0, locale: locale) }
        let spacing = columnSpacing * CGFloat(columns.count - 1)
        let outerWidth = availableWidth > 0 ? availableWidth - windowMargin * 2 : assumedWidth
        // どんなに窓が狭くても下限は割らない(その場合だけ横にはみ出すのを許す。
        // 名前が1文字も読めない列を並べるよりはましなため)。
        let budget = max(minColumn * CGFloat(columns.count) + spacing, outerWidth) - spacing
        let total = ideals.reduce(0, +)
        guard total > budget else { return ideals }

        var widths = ideals.map { budget * $0 / total }
        // 按分の結果が下限を割った列は下限に固定し、残りを他の列へ配り直す。budgetは
        // 「下限×列数」以上であることが上で保証されているので、この画面のように列が
        // 最大2つなら1回の配り直しで必ず収まる。
        let pinned = widths.indices.filter { widths[$0] < minColumn }
        guard !pinned.isEmpty else { return widths.map { $0.rounded(.down) } }
        let free = widths.indices.filter { widths[$0] >= minColumn }
        let remaining = budget - minColumn * CGFloat(pinned.count)
        let freeTotal = free.reduce(CGFloat(0)) { $0 + ideals[$1] }
        for index in pinned {
            widths[index] = minColumn
        }
        for index in free {
            widths[index] = freeTotal > 0
                ? remaining * ideals[index] / freeTotal
                : remaining / CGFloat(free.count)
        }
        return widths.map { $0.rounded(.down) }
    }

    /// 1列が「省略なしで全部読める」ために欲しい幅。見出し(headline)と、各行の
    /// 「ファイル名(body)+間隔+形式バッジ」のいちばん長いものの、どちらも収まる幅。
    private static func ideal(for column: WelcomeQuickOpenColumn, locale: Locale) -> CGFloat {
        let headerFont = NSFont.preferredFont(forTextStyle: .headline)
        let headerWidth = (column.title as NSString).size(withAttributes: [.font: headerFont]).width
        let rowsWidth = ExportColumnWidthEstimator.idealWidth(
            for: column.items.map { item in
                (
                    text: item.title,
                    extraChrome: rowBadgeSpacing
                        + FormatBadgeView.estimatedWidth(bookID: item.bookID, locale: locale)
                )
            },
            minWidth: minColumn,
            maxWidth: maxColumn
        )
        return min(maxColumn, max(rowsWidth, headerWidth.rounded(.up)))
    }
}

private struct WelcomeQuickOpenList: View {
    let column: WelcomeQuickOpenColumn
    /// 実測から決まったこの列の幅(WelcomeQuickOpenWidth.resolved参照)。
    /// maxWidth: .infinityで等分するのをやめ、列ごとに必要な幅を与えている。
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 見出しはロケール解決済みの文字列。Text(_:)のLocalizedStringKey版に渡すと
            // 二重にローカライズを試みることになるため、String版が選ばれる形のまま渡す。
            Text(column.title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
            ForEach(column.items) { item in
                row(for: item)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// 1行分。破壊的な項目を持つ項目にだけ右クリックメニューを付ける。
    ///
    /// **.contextMenuを付けたうえで中身をifで空にする書き方は避ける。** 項目が1つも無い
    /// コンテキストメニューは、macOSでは空の枠が一瞬出るだけの当たり所になり、右クリックが
    /// 「何も起きない」のか「壊れている」のか分からない。付けるか付けないかで分岐する。
    @ViewBuilder
    private func row(for item: WelcomeQuickOpenItem) -> some View {
        let button = Button {
            item.action()
        } label: {
            HStack(spacing: WelcomeQuickOpenWidth.rowBadgeSpacing) {
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

        if let titleKey = item.destructiveActionTitleKey,
           let destructiveAction = item.destructiveAction {
            // コンテキストメニューの中身はmacOSが不透明に描くので、すりガラス面の
            // 決まりごと(輪郭)は不要(CLAUDE.md参照)。
            button.contextMenu {
                Button(titleKey, role: .destructive) { destructiveAction() }
            }
        } else {
            button
        }
    }
}
