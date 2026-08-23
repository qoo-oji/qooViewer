import SwiftUI
import AppKit

/// サイドパネル本体。既定では常時表示、表示メニューの「サイドパネルを隠す」がONのときだけ
/// ウインドウ端へのホバーで一時的に表示される(ContentView参照)。左右どちら側に表示するかは
/// 環境設定「一般」タブで選べる(SidePanelPosition。常時表示・ホバー表示のどちらにも効く)。
///
/// パネル最上部には、表示モード(SidePanelMode)をワンクリックで直接切り替えるスイッチ
/// (SidePanelModeSwitcher)を常に表示する。モードによって、その下に表示される内容が
/// 丸ごと入れ替わる。
///
/// **ブラウザモード**(既定): 上段(folderState、フォルダブラウザ)は常に表示し、下段
/// (bookContentsState、本の中身ブラウザ)は本を開いていて対応フォーマット(フォルダ、
/// zip/cbz/rar/cbr/7z/cb7、または直接渡された画像ファイル)のときだけ、ドラッグでサイズ
/// 調整可能な形で追加表示する。画像ファイルの本は辿るべき階層が無いため、渡された画像
/// そのものが平坦な1階層として並ぶ(BookEntryLevel.imageFileList参照)。
/// PDF/EPUBはページがファイル単位で存在しない、またはzipコンテナの生の中身を見せても
/// かえって分かりづらいため下段は非表示のまま(BookContentsBrowserState.init?がnilを返す)。
///
/// **ブックマークモード**: 上段はお気に入りのツリー、下段は今開いている本のブックマーク一覧。
/// どちらの段も「追加」「編集ウインドウを開く」の2ボタンを持つ(ユーザー要望)。実際の追加
/// (登録先フォルダの選択シート)・編集ウインドウの表示は、このViewではなく呼び出し側
/// (ContentView、およびそこからAppState経由でViewerView)が行う。
///
/// 背景はViewerView.swiftの他のパネル(サムネイル一覧・Get Info)と違い自身で持つ
/// (フローティングカードではなくウインドウ端のフル高さのサイドバーとして背景を持つ。
/// SidebarVisualEffectView参照)。ユーザー要望により、ページ表示エリアなどパネルの外側を
/// クリックしても閉じない(常時表示が既定のため、クリックで閉じる仕組みは本を読む操作の
/// 妨げになる)。
struct SidePanelView: View {
    /// 初期・既定の幅。ContentView側の@State(sidePanelWidth)の初期値として使う。
    static let defaultWidth: CGFloat = 280
    private static let widthRange: ClosedRange<CGFloat> = 220...480

    @EnvironmentObject private var preferences: AppPreferences
    /// ブックマークモード上段(お気に入りツリー)の表示元。アプリ全体で1つのインスタンスを
    /// 共有しているため(QooViewerApp参照)、@EnvironmentObjectとして受け取れば整理ウインドウ・
    /// メニューバー側での変更もそのまま反映される。
    @EnvironmentObject private var favoritesStore: FavoritesStore
    /// 履歴モードの表示元(favoritesStoreと同じくアプリ全体で1つ)。
    @EnvironmentObject private var recentFiles: RecentFilesStore
    @ObservedObject var folderState: SidePanelBrowserState
    var bookContentsState: BookContentsBrowserState?
    /// パネル最上部のスイッチで切り替える表示モード。実体はAppPreferences.sidePanelMode
    /// (アプリ全体で1つ、次回起動時にも引き継ぐ)。
    @Binding var mode: SidePanelMode
    /// パネルの幅。ContentViewが@Stateとして保持し、Bindingで渡す(ドッキング表示・
    /// ホバーオーバーレイ表示のどちらでも同じ幅を共有するため)。ビューア側の端にある
    /// ドラッグハンドルでユーザーが調整できる。
    @Binding var width: CGFloat
    /// パネルをウインドウのどちら側に表示しているか(環境設定。AppPreferences.sidePanelPosition)。
    /// パネル自体の配置はContentViewが行うため、ここで使うのは「パネルのどちらの端が
    /// ビューア側を向いているか」に依存する部分だけ ― 幅調整ハンドル・ドラッグ中の目印の位置と
    /// ドラッグ方向、およびページモードの拡大プレビューを出す向き。
    var position: SidePanelPosition
    /// 下段のダブルクリックで、クリックした画像が本の何ページ目かを特定するための一覧
    /// (AppState.currentBookPages。並び替え/除外の変更を追従できるよう、本を開いた時点の
    /// スナップショットではなく最新値をContentViewから渡してもらう)。
    var bookPages: [PageRef]
    /// リソースモードが、このウインドウで開いている本のメモリキャッシュの状態を取るための
    /// 橋渡し(AppState.fetchResourceSnapshot)。本を開いていなければnil。
    var fetchResourceSnapshot: (() async -> ResourceMonitorSnapshot?)?
    /// 今開いている本そのものの場所。右クリックの「Finderで開く」で、書庫の中のページを
    /// 右クリックしたときに書庫自体を指すために使う(PageFileAccess参照)。
    var bookSourceURL: URL?
    /// 右クリックの「画像をエクスポート」(ユーザー要望)。書き出しの実装はViewerViewが
    /// 持っているため、ページ番号を渡すクロージャとして受け取る(AppState.exportPageImage参照)。
    var onExportPage: ((Int) -> Void)?
    /// 一覧のファイル/フォルダを本として開く(上段のファイル・フォルダ行、下段の
    /// 「新しい本として開く」フォールバックの両方から呼ばれる)。呼び出し側でパネルを
    /// 閉じてからAppState.open(url:)を行う。
    var onOpen: (URL) -> Void
    /// フォルダブラウザの移動でたどり着いたフォルダの画像を表示する(moveAndShowImages)。
    /// `onOpen`と違い**履歴に残さない** ―― 目的の本を探して通り抜けただけのフォルダで履歴が
    /// 埋まらないようにするため(BookOpenRequest.recordsInHistory参照)。
    var onBrowseToFolder: (URL) -> Void
    /// 下段で、既に本のページ一覧に含まれている画像をダブルクリックしたときのジャンプ。
    var onJumpToPage: (Int) -> Void
    /// ページの右クリック →「このページをブックマークに追加/削除」(ユーザー要望)。
    /// ページモードと本の中身ブラウザの両方から呼ばれ、中身はページ一覧パネルと共通
    /// (PageContextMenuItems参照)。実装はViewerViewが持つため橋渡しのクロージャで受け取る。
    var onToggleBookmarkAtPage: (Int) -> Void
    /// 行の右クリックから、その本を新しいウインドウ/タブで開く(BookOpenContextMenuItems)。
    /// フォルダブラウザ(上段)と履歴モードの行から呼ばれる。お気に入りは対象がURLでは
    /// なくFavoriteBookなので、下の専用のクロージャを使う。
    ///
    /// `onOpen`と違い、パネルを閉じる処理は行わない ―― 開く先が別のウインドウ/タブなので、
    /// このウインドウのパネルは出したままのほうが「一覧から次々に開く」という使い方に合う
    /// (ユーザー要望の趣旨)。
    var onOpenInNewWindow: (URL, BookOpenDestination) -> Void

    // MARK: - ブックマークモード用

    /// 今開いている本のブックマーク一覧(AppState.currentBookmarks。ページ番号順)。
    /// 本を開いていないときは空。
    var bookmarks: [Bookmark]
    /// 今表示しているページ番号(0始まり)。一覧内で該当するブックマークをハイライトするために使う。
    var currentPageIndex: Int
    /// 本を開いているかどうか。「お気に入りに追加」「ブックマークを追加」の2ボタンは、本を
    /// 開いていない間は対象が無いため無効化する。
    var hasBook: Bool
    /// 今開いている本のパス(MangaBook.id)。履歴モードで、今読んでいる本の行を
    /// ハイライトするために使う。
    var currentBookPath: String?
    /// ページモードのサムネイル取得(AppState.loadPageThumbnail)と、その世代番号。
    /// 本を開いていないときはloadPageThumbnailがnilになる。
    var loadPageThumbnail: ((Int) async -> CGImage?)?
    /// このパネルを載せているウインドウがシークレットウインドウかどうか(AppState.isPrivateWindow)。
    /// trueなら履歴モードは一覧を出さない(ユーザー要望: シークレットウインドウでは通常ウインドウで
    /// 作られた履歴も見せない)。
    ///
    /// **＋/鉛筆ボタンの無効化はこちらではなくallowsLibraryEditingが担う。** 以前はこの1つの値が
    /// 「履歴を隠す」と「編集ボタンを無効にする」の両方を兼ねていたが、その場限りの本
    /// (MangaBook.isTransient)の導入で条件が食い違うようになったため分けた。ここへ単純にORして
    /// しまうと、**通常ウインドウでその場限りの本を開いた瞬間にサイドパネルの履歴が消える**。
    var isPrivateWindow: Bool = false
    /// お気に入り/ブックマークの＋(追加)・鉛筆(編集)ボタンを使えるかどうか。
    /// falseになるのは、シークレットウインドウか、その場限りの本を開いているとき
    /// (どちらもDBへ書けないため。ViewerViewModel.skipsPersistenceと同じ条件)。
    /// 一覧からのジャンプ・お気に入りを開く操作は読み取りなので、falseでも通常どおり使える。
    var allowsLibraryEditing: Bool = true
    /// ページモードのサムネイルをホバーしたときの拡大プレビュー用のフル解像度画像取得
    /// (AppState.loadPageImage)。loadPageThumbnailと同時に登録・解除される。
    var loadPageImage: ((Int) async -> CGImage?)?
    var pageThumbnailGeneration: Int
    /// 今開いている本を、お気に入りへ追加する(登録先フォルダの選択シートを開く)。
    var onAddFavorite: () -> Void
    /// 「お気に入りの編集」ウインドウを開く。
    var onEditFavorites: () -> Void
    /// お気に入りの行の右クリックから、その本を新しいウインドウ/タブで開く。
    /// URLの解決(見つからなければアラート)は呼び出し側が行う ―― 通常の`onOpenFavorite`と
    /// 同じ扱いにするため。
    var onOpenFavoriteInNewWindow: (FavoriteBook, BookOpenDestination) -> Void
    /// お気に入りツリーの本をクリックして開く(環境設定「お気に入りを開くとき」に従う)。
    var onOpenFavorite: (FavoriteBook) -> Void
    /// お気に入り(本・フォルダ)の名前を変更する / 削除する(行の右クリックから。ユーザー要望)。
    ///
    /// 入力欄と確認ダイアログをここではなくContentViewに持たせているのは、パネルを隠す設定で
    /// 使っている場合、ダイアログが出ている間だけホバーによる自動非表示を止める必要があるため
    /// (メニューを開いている間に止めるのと同じ理屈。ContentView.isMenuTrackingのコメント参照)。
    /// その判断はホバーの監視を持っているContentView側にしか書けない。
    var onRenameFavorite: (FavoriteListEntry) -> Void
    var onDeleteFavorite: (FavoriteListEntry) -> Void
    /// 今表示しているページをブックマークへ追加する。
    var onAddBookmark: () -> Void
    /// 「ブックマーク・レイアウトの編集」ウインドウを開く。
    var onEditBookmarks: () -> Void
    /// ブックマーク一覧の項目をクリックして、そのページへジャンプする。
    var onJumpToBookmark: (Bookmark) -> Void
    /// ブックマークの名前を変更する / 削除する(行の右クリックから。ユーザー要望)。
    /// ダイアログをContentViewに持たせている理由はonRenameFavoriteのコメント参照。
    var onRenameBookmark: (Bookmark) -> Void
    var onDeleteBookmark: (Bookmark) -> Void

    @State private var topSectionFraction: CGFloat = 0.5
    /// ブックマークモードの上下分割比。ブラウザモードのtopSectionFraction(フォルダブラウザと
    /// 本の中身ブラウザの分割)とは意味も見せたい比率も別物のため、状態自体を分けて持つ
    /// (モードを行き来しても、それぞれのモードで最後に調整した比率がそのまま残る)。
    @State private var bookmarksTopSectionFraction: CGFloat = 0.5
    /// お気に入りツリーで展開中のフォルダのid一覧(FavoritesOrganizerView.expandedFolderIDsと
    /// 同じ考え方)。パネルの生存期間中は保持され、モードを切り替えても展開状態は残る。
    @State private var expandedFavoriteFolderIDs: Set<UUID> = []
    /// 上段(フォルダブラウザ)の絞り込み検索欄の入力内容。フォルダを移動すると空に戻す
    /// (folderSection参照)。1つのフォルダに数百冊入っているケースで目的の本を素早く
    /// 見つけるための機能(ユーザー要望)。
    /// 右クリックされた行を枠で示すための状態(SidePanelContextMenuHighlight参照)。
    /// 各セクションのビューへは`.environmentObject`で配る。
    @StateObject private var contextHighlight = SidePanelContextMenuHighlight()
    @State private var folderFilterText = ""
    @GestureState private var dragOffset: CGFloat = 0
    @GestureState private var widthDragOffset: CGFloat = 0

    /// ドラッグ中、ContentView.body(HStack)がこのパネルのために確保する幅・パネル自身の
    /// 中身(panelBody)の幅とも、ライブな値(effectiveWidth)に追随させている。以前は
    /// どちらも確定値(width)のまま固定し、ドラッグ中はマテリアル背景だけを伸縮させていた
    /// (HStackの再レイアウトを通じてViewerView側のGeometryReaderによる画像再スケーリングや、
    /// panelBody自身のGeometryReader+ScrollView+LazyVStackが毎フレーム再計算されると
    /// 描画が追いつかず振動して見える不具合があったため)。ドラッグハンドル自体の震え
    /// (widthDragHitAreaのコメント参照、ハンドルの位置が自分自身のジェスチャー出力に
    /// 依存する自己参照ループが原因)を解決した後にあらためて試したところ問題なく追随できた
    /// ため、ライブ追従に戻した。実機で重さが気になるようなら、この2箇所を再びwidthへ
    /// 戻せば以前の(背景だけライブな)方式に戻せる。
    var body: some View {
        Color.clear
            .frame(width: effectiveWidth)
            .frame(maxHeight: .infinity)
            .transaction { $0.animation = nil }
            .overlay(alignment: .leading) {
                // すりガラスの濃さと重ね色は環境設定「外観」に従う(ユーザー要望)。
                // 既定値では従来どおり SidebarVisualEffectView をそのまま敷いたのと
                // 同じ描画になる(SidePanelSurfaceBackground参照)。
                SidePanelSurfaceBackground(style: preferences.sidePanelSurfaceStyle)
                    .frame(width: effectiveWidth)
                    .frame(maxHeight: .infinity)
                    .transaction { $0.animation = nil }
            }
            .overlay(alignment: .leading) {
                panelBody
                    .frame(width: effectiveWidth)
                    .frame(maxHeight: .infinity)
                    .transaction { $0.animation = nil }
                    // 文字・アイコンの輪郭の太さを配る。他の4面はpanelSurfaceBackgroundが
                    // 背景と一緒に面倒を見てくれるが、この面だけは背景がbackgroundではなく
                    // overlayの兄弟なので、ここで直接配る(panelContentOutlineのコメント参照)。
                    .panelContentOutline(
                        width: PanelContentShadow.outlineWidth(
                            forLevel: preferences.sidePanelSurfaceStyle.contentShadowLevel
                        )
                    )
            }
            // ドラッグの当たり判定を持つビュー(widthDragHitArea)自体は、レイアウト上も
            // 見た目上も一切動かさない(offsetも含めて)。ジェスチャーを載せているビュー
            // 自身の位置・オフセットがそのジェスチャー自身の出力(widthDragOffset)に
            // 依存してしまうと、値がわずかでも動くたびにジェスチャーの基準座標がずれて
            // 再計算され、それがまた値を動かす……という自己参照ループになり、ドラッグの
            // 方向・量に応じて震えて見える不具合になっていた(ユーザー報告: 縮小方向は
            // 小刻みに、拡大方向は大きく震える ― offset(x: effectiveWidth - 3)という、
            // ハンドル自身の出力に依存するoffsetを与えていたのが原因)。
            .overlay(alignment: .leading) {
                widthDragHitArea
            }
            // 見た目としてドラッグ位置を追従させる表示は、当たり判定を持たない別のビュー
            // (widthDragIndicator)に分離する。こちらはジェスチャーを一切持たないため、
            // 自己参照ループが起きようがない。
            .overlay(alignment: .leading) {
                widthDragIndicator
            }
            .zIndex(1)
    }

    private var panelBody: some View {
        panelSections
            .environmentObject(contextHighlight)
    }

    @ViewBuilder
    private var panelSections: some View {
        VStack(spacing: 0) {
            SidePanelModeSwitcher(mode: $mode)
            Divider()
            switch mode {
            case .browser:
                browserModeBody
            case .bookmarks:
                bookmarksModeBody
            case .history:
                if isPrivateWindow {
                    SidePanelEmptyMessage(textKey: "History is not shown in a private window.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SidePanelHistorySectionView(
                        recentFiles: recentFiles,
                        currentBookPath: currentBookPath,
                        onOpen: onOpen,
                        onOpenInNewWindow: onOpenInNewWindow
                    )
                }
            case .pages:
                SidePanelPagesSectionView(
                    pages: bookPages,
                    bookSourceURL: bookSourceURL,
                    currentPageIndex: currentPageIndex,
                    bookmarkedPageIndices: bookmarkedPageIndices,
                    allowsBookmarking: allowsLibraryEditing,
                    thumbnailGeneration: pageThumbnailGeneration,
                    loadThumbnail: loadPageThumbnail,
                    loadPageImage: loadPageImage,
                    previewArrowEdge: position.innerEdge,
                    onJumpToPage: onJumpToPage,
                    onExportPage: onExportPage,
                    onToggleBookmark: onToggleBookmarkAtPage
                )
            case .resources:
                SidePanelResourcesSectionView(fetchBookSnapshot: fetchResourceSnapshot)
            }
        }
    }

    /// ブラウザモード(従来のサイドパネル)の中身。
    @ViewBuilder
    private var browserModeBody: some View {
        if let bookContentsState {
            GeometryReader { geometry in
                let fraction = effectiveTopFraction(totalHeight: geometry.size.height, fraction: topSectionFraction)
                VStack(spacing: 0) {
                    folderSection
                        .frame(height: max(80, geometry.size.height * fraction - 4))
                        .clipped()
                    dragHandle(totalHeight: geometry.size.height, fraction: $topSectionFraction)
                    BookContentsSectionView(
                        state: bookContentsState,
                        bookPages: bookPages,
                        bookSourceURL: bookSourceURL,
                        bookmarkedPageIndices: bookmarkedPageIndices,
                        allowsBookmarking: allowsLibraryEditing,
                        onOpen: onOpen,
                        onJumpToPage: onJumpToPage,
                        onExportPage: onExportPage,
                        onToggleBookmark: onToggleBookmarkAtPage
                    )
                    .frame(maxHeight: .infinity)
                    .clipped()
                }
            }
        } else {
            folderSection
        }
    }

    /// ブックマークモード(上段=お気に入りツリー、下段=ブックマーク一覧)の中身。
    /// ブラウザモードと違い、上下どちらの段も常に表示する(本を開いていなくても、お気に入りの
    /// 閲覧・編集ウインドウの呼び出しはできる必要があり、ブックマーク側も「まだ何もない」
    /// ことが分かる形で見えていた方がよいため)。
    private var bookmarksModeBody: some View {
        GeometryReader { geometry in
            let fraction = effectiveTopFraction(
                totalHeight: geometry.size.height, fraction: bookmarksTopSectionFraction
            )
            VStack(spacing: 0) {
                SidePanelFavoritesSectionView(
                    favoritesStore: favoritesStore,
                    expandedFolderIDs: $expandedFavoriteFolderIDs,
                    hasBook: hasBook,
                    allowsEditing: allowsLibraryEditing,
                    onAdd: onAddFavorite,
                    onEdit: onEditFavorites,
                    onOpen: onOpenFavorite,
                    onOpenInNewWindow: onOpenFavoriteInNewWindow,
                    onRename: onRenameFavorite,
                    onDelete: onDeleteFavorite
                )
                .frame(height: max(80, geometry.size.height * fraction - 4))
                .clipped()
                dragHandle(totalHeight: geometry.size.height, fraction: $bookmarksTopSectionFraction)
                SidePanelBookmarksSectionView(
                    bookmarks: bookmarks,
                    currentPageIndex: currentPageIndex,
                    hasBook: hasBook,
                    allowsEditing: allowsLibraryEditing,
                    onAdd: onAddBookmark,
                    onEdit: onEditBookmarks,
                    onJump: onJumpToBookmark,
                    onRename: onRenameBookmark,
                    onDelete: onDeleteBookmark
                )
                .frame(maxHeight: .infinity)
                .clipped()
            }
        }
    }

    private var effectiveWidth: CGFloat {
        Self.clampWidth(width + widthDragOffset)
    }

    private static func clampWidth(_ value: CGFloat) -> CGFloat {
        min(max(value, widthRange.lowerBound), widthRange.upperBound)
    }

    /// パネルのビューア側の端(左配置なら右端、右配置なら左端)にある幅調整用の、ドラッグの
    /// 当たり判定だけを持つ透明な領域。
    /// 上下分割のdragHandleと違い、こちらは意図的に**見た目上・レイアウト上まったく
    /// 動かさない**(常に確定済みのwidth基準の位置に固定)。DragGesture自身の出力
    /// (widthDragOffset)にこのビュー自身の位置を依存させてしまうと、自己参照の
    /// フィードバックループでドラッグ中に震えて見える不具合になるため(widthDragIndicator
    /// 参照)。.overlay(alignment: .leading)の基準(x:0、パネル左端)から、確定済みの
    /// width(ドラッグ中も変化しない値なのでフィードバックループの心配は無い)を使って
    /// 境界へ移動させている(右配置ではパネル左端が境界のため、移動量は幅に依存しない)。
    private var widthDragHitArea: some View {
        Color.clear
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: position == .left ? width - 3 : -3)
            .onHover { isHovering in
                if isHovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($widthDragOffset) { value, state, _ in
                        state = widthDelta(forDragTranslationWidth: value.translation.width)
                    }
                    .onEnded { value in
                        width = Self.clampWidth(
                            width + widthDelta(forDragTranslationWidth: value.translation.width)
                        )
                    }
            )
    }

    /// 幅調整ハンドルの横移動量を、パネルの幅の増減量へ読み替える。左配置ではハンドルが
    /// パネルの右端にあるため右へ動かすと広がるが、右配置ではハンドルが左端にあるため
    /// 左へ動かすと広がる(符号が反転する)。
    private func widthDelta(forDragTranslationWidth translation: CGFloat) -> CGFloat {
        position == .left ? translation : -translation
    }

    /// ドラッグ中、現在の確定予定位置を示す見た目だけの縦線。widthDragHitAreaとは別の
    /// ビュー(ジェスチャーを持たない)にすることで、自己参照ループを避けている。
    ///
    /// 右配置のときはパネルの左端が境界になる。パネル自身はウインドウの右端に固定されたまま
    /// 左へ伸びるので、パネル座標系での境界の位置は幅に関わらず常にx:0(この縦線の中心が
    /// そこに来るようoffsetは-1)であり、線はドラッグに合わせて自然に追従する。
    @ViewBuilder
    private var widthDragIndicator: some View {
        if widthDragOffset != 0 {
            Rectangle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: position == .left ? effectiveWidth - 1 : -1)
                .allowsHitTesting(false)
                .transaction { $0.animation = nil }
        }
    }

    /// 上下分割の、ドラッグ中も含めた実際の分割比。fractionはモードごとに別の@State
    /// (topSectionFraction/bookmarksTopSectionFraction)を渡す。ドラッグ中の追従に使う
    /// dragOffsetは共用でよい(分割ハンドルは同時に1つしか表示されないため)。
    private func effectiveTopFraction(totalHeight: CGFloat, fraction: CGFloat) -> CGFloat {
        guard totalHeight > 0 else { return fraction }
        return Self.clampFraction(fraction + dragOffset / totalHeight)
    }

    private static func clampFraction(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.15), 0.85)
    }

    private func dragHandle(totalHeight: CGFloat, fraction: Binding<CGFloat>) -> some View {
        ZStack {
            Color.primary.opacity(0.0001)
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 2)
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { value in
                    guard totalHeight > 0 else { return }
                    fraction.wrappedValue = Self.clampFraction(
                        fraction.wrappedValue + value.translation.height / totalHeight
                    )
                }
        )
    }

    // MARK: - 上段(フォルダブラウザ)

    private var folderSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SidePanelNavButton(systemName: "chevron.left", isDisabled: !folderState.canGoBack, help: "Back") {
                    moveAndShowImages { folderState.goBack() }
                }
                SidePanelNavButton(systemName: "chevron.right", isDisabled: !folderState.canGoForward, help: "Forward") {
                    moveAndShowImages { folderState.goForward() }
                }
                SidePanelNavButton(systemName: "arrow.up", isDisabled: !folderState.canGoUp, help: "Enclosing Folder") {
                    moveAndShowImages { folderState.goUp() }
                }
                Spacer(minLength: 0)
                // 並べ替えの基準・向きの切替(ユーザー要望)。設定はアプリ全体で1つ
                // (AppPreferences.folderBrowserSortKey/Direction)で、次回起動時も引き継ぐ。
                //
                // 「Finderで表示」より**左**に置くこと(ユーザー要望)。並べ替えはこの一覧の
                // 中で完結する操作で、「Finderで表示」はアプリの外へ出る操作なので、
                // 影響範囲の小さいものから順に左から並ぶ形になる。
                SidePanelSortMenu(
                    key: $preferences.folderBrowserSortKey,
                    direction: $preferences.folderBrowserSortDirection
                )
                SidePanelNavButton(
                    systemName: "arrow.up.forward.square",
                    isDisabled: folderState.currentDirectory == nil,
                    help: "Show in Finder"
                ) {
                    folderState.openInFinder()
                }
            }
            .padding(10)

            Text(folderState.currentDirectory.map(DirectoryBrowser.displayName(for:)) ?? String(localized: "Computer"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .help(folderState.currentDirectory?.path ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)

            SidePanelSearchField(text: $folderFilterText)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                // フォルダを移動したら絞り込みは解除する(移動先でも前のフォルダ向けの
                // 絞り込みが効いたままだと、中身が空に見えて戸惑うため)。
                .onChange(of: folderState.currentDirectory) { _, _ in folderFilterText = "" }

            Divider()

            if folderState.needsFolderAccessGrant {
                VStack(spacing: 8) {
                    Text("This folder isn't accessible yet.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .panelOutlinedContent()
                    Button("Grant Access…") { folderState.requestFolderAccess() }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let entries = filteredFolderEntries
                if entries.isEmpty && !folderState.entries.isEmpty {
                    SidePanelEmptyMessage(textKey: "(No Matches)")
                } else if entries.isEmpty, folderState.currentDirectoryHasImages,
                          let directory = folderState.currentDirectory {
                    // 画像だけが入っているフォルダ。この一覧は画像を行として出さないため
                    // 空に見えるが、行き止まりではなく「1冊の本」。移動した時点でその画像を
                    // 表示しているので(moveAndShowImages参照)、ここは一覧が空である理由を
                    // 伝えるだけでよい ―― 押すべきボタンは無い。
                    //
                    // 再アンカー(履歴やお気に入りから本を開いた場合)でここへ来たときだけは
                    // まだ開いていないことがあるので、そのときは言い方を変える。
                    SidePanelEmptyMessage(
                        textKey: isCurrentBookFolder(directory)
                            ? "This folder's images are open."
                            : "This folder holds images."
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(entries) { entry in
                                    folderRow(entry)
                                }
                            }
                        }
                        // ScrollView(NSScrollViewをラップ)は既定でキーボードフォーカスを受け取れる。
                        // このパネルはクリック操作のみを想定しているため、Tabキーでの移動などで
                        // 意図せずスクロール領域へフォーカスが移らないようにしておく
                        // (フォーカスリング自体の抑制はContentView.body側の
                        // .focusEffectDisabled()で行っている。絞り込み検索欄への入力は
                        // これとは別で、通常どおりフォーカスを受け取れる)。
                        .focusable(false)
                        // 「サイドパネルを隠す」がONで、カーソルを左端に近づけてパネルが
                        // 現れた瞬間にも、今開いている本の行が見えている状態から始める
                        // (ユーザー要望)。下段(本の中身ブラウザ)の同名の.onAppearとまったく
                        // 同じ理由: SidePanelBrowserStateはContentViewが保持し続けていて
                        // 一覧(entries)は変わらないため下の.onChangeは発火せず、作り直された
                        // ScrollViewだけが先頭に戻ってしまっていた。現れた瞬間のスクロールは
                        // アニメーションさせない(パネルのスライドインと同時に中身も動くと
                        // 落ち着かないため)。
                        .onAppear { scrollToHighlightedFolder(proxy: proxy, animated: false) }
                        // ハイライト対象(今開いている本)が変わったとき、または別のフォルダへ
                        // 移動して一覧そのものが変わったときに、その行が表示枠内に見えるよう
                        // スクロールする。highlightedURLの方も見ているのは、同じフォルダ内の
                        // 別の本へ切り替えた場合はentriesが変わらずハイライト位置だけが動くため
                        // (下段の本の中身ブラウザがhighlightedMatchKeysとentriesの両方を
                        // 見ているのと同じ理由)。
                        .onChange(of: folderState.highlightedURL) { _, _ in
                            scrollToHighlightedFolder(proxy: proxy)
                        }
                        .onChange(of: folderState.entries) { _, _ in
                            scrollToHighlightedFolder(proxy: proxy)
                        }
                    }
                }
            }
        }
        // 並べ替え設定が変わったら、その場で一覧を並べ替え直す(ディスクは読み直さない。
        // SidePanelBrowserState.applySortSettings参照)。preferences.folderBrowserSortは
        // 「基準・向き・フォルダのグループ分け」を束ねた値なので、環境設定「一般」タブ側の
        // 並び順を変えた場合もここで拾える。
        //
        // .onAppearでも同じ呼び出しをしておくのは、このセクションが表示されていない間
        // (パネルを隠している、別のモードを表示している、環境設定ウインドウで変更した)の
        // 変更を取りこぼさないため。設定が変わっていなければ何もしないので二重呼び出しは無害。
        .onAppear { folderState.applySortSettings() }
        .onChange(of: preferences.folderBrowserSort) { _, _ in
            folderState.applySortSettings()
        }
    }

    /// 今開いている本(folderState.highlightedURL)の行までスクロールする。
    /// 下段(本の中身ブラウザ)のscrollToHighlighted(proxy:animated:)のフォルダ一覧版。
    private func scrollToHighlightedFolder(proxy: ScrollViewProxy, animated: Bool = true) {
        guard let highlighted = folderState.highlightedURL,
              // 絞り込みで一覧から外れている行へはスクロールできない。
              filteredFolderEntries.contains(where: { $0.url.path == highlighted.path }) else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo(highlighted.path, anchor: .center) }
            } else {
                proxy.scrollTo(highlighted.path, anchor: .center)
            }
        }
    }

    /// 絞り込み検索欄(folderFilterText)を適用した一覧。空欄のときは全件そのまま
    /// (フォルダ・ファイルの区別はせず、表示名に対する大文字小文字を区別しない部分一致で絞る)。
    /// ブックマークが付いているページ番号の集合。ページモードの行のしおりアイコンと、
    /// 右クリックメニューの文言(追加/削除)の両方が使う。
    ///
    /// **2つの区画へ同じ集合を渡すため、ここで一度だけ組む。** `.contextMenu`の中身は行の
    /// 本体評価の一部として組み立てられる(SidePanelContextMenuHighlightの型コメント参照)ので、
    /// 行ごとにbookmarksを走査させないこと。
    private var bookmarkedPageIndices: Set<Int> { Set(bookmarks.map(\.pageIndex)) }

    private var filteredFolderEntries: [DirectoryBrowser.Entry] {
        let trimmed = folderFilterText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return folderState.entries }
        return folderState.entries.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    private func folderRow(_ entry: DirectoryBrowser.Entry) -> some View {
        // entry.urlはFileManagerが返した素のURL、highlightedURLは(最近使ったファイルなど
        // 経由の場合)セキュリティスコープ付きブックマークから解決したURLであることがあり、
        // パスの文字列は同じでも素のURL同士の==比較が一致しないことがある。下のscrollTo側は
        // 既にEntry.id(= url.path)を使っておりこの問題を回避できているため、ここも合わせて
        // パス文字列で比較する。
        let isHighlighted = entry.url.path == folderState.highlightedURL?.path
        let label = rowLabel(
            icon: iconName(fileName: entry.isDirectory ? nil : entry.url.lastPathComponent, isDirectory: entry.isDirectory),
            name: entry.displayName
        )
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        // 選択行のハイライトも、重ね色がアクセントカラーに近いと消える(同上)。
        .panelOutlinedAccent(in: Rectangle(), isEnabled: isHighlighted)

        return Group {
            if entry.isDirectory {
                if preferences.sidePanelUsesDoubleClick {
                    // シングルクリックが使えないため、「移動する」「画像フォルダとして開く」の
                    // 2つの意味をダブルクリック1つに割り当てる必要がある。直下に画像ファイルが
                    // あれば開く、無ければ移動する、で判定する(ユーザー要望)。
                    label.onTapGesture(count: 2) { handleFolderDoubleClick(entry) }
                } else {
                    label
                        .onTapGesture(count: 2) { onOpen(entry.url) }
                        .onTapGesture(count: 1) { handleFolderClick(entry) }
                }
            } else {
                label.onTapGesture(count: preferences.sidePanelUsesDoubleClick ? 2 : 1) { onOpen(entry.url) }
            }
        }
        .sidePanelContextHighlight(rowID: "folder:\(entry.id)")
        // 上段はディスク上に実在するファイル/フォルダだけを並べているので、
        // どの行も素直にFinderで示せる(ユーザー要望)。
        .contextMenu {
            // 「開く」系はこの行が1冊の本を指しているときだけ出す。ファイルの行は
            // 開ける形式だけに絞られている(DirectoryBrowser冒頭のコメント参照)ので常に本。
            // フォルダの行は、直下に画像がある=それ自体が1冊の本になるものだけ ―― 奥の本へ
            // たどり着くための中間フォルダには、開くべき本がそもそも無い。
            //
            // 判定にEntryが持っている確定値を使い、ここではディスクを触らない。
            // `.contextMenu`の中身は右クリックの瞬間ではなく**行の本体評価の一部**として
            // 組み立てられるため、ここでI/Oをすると絞り込みの1文字ごとに表示中の全フォルダぶん
            // 走ることになる(DirectoryBrowser.Entry.containsImageFileのコメント参照)。
            if !entry.isDirectory || entry.containsImageFile {
                BookOpenContextMenuItems(
                    onOpen: { onOpen(entry.url) },
                    onOpenIn: { onOpenInNewWindow(entry.url, $0) }
                )
                Divider()
            }
            Button("Show in Finder") {
                FinderReveal.reveal(entry.url)
            }
        }
    }

    /// `directory`が、今開いている本そのものかどうか。
    ///
    /// 画像フォルダの本ならbookSourceURLはそのフォルダを指す。画像を直接開いた本の場合は
    /// 先頭ページの画像ファイルを指すので一致せず、「このフォルダの画像を開く」は出たままになる
    /// ―― 開き直せば別の(フォルダ全体の)本になるため、そちらは出したままでよい。
    ///
    /// パス文字列で比べるのは、行のハイライト判定と同じ理由(folderRowのコメント参照)。
    /// セキュリティスコープ付きブックマークから解決したURLは、同じ場所でも素のURLと
    /// `==`で一致しないことがある。
    private func isCurrentBookFolder(_ directory: URL) -> Bool {
        guard let bookSourceURL else { return false }
        return bookSourceURL.path == directory.path
    }

    /// フォルダブラウザの中で場所を移し、**移った先に画像があればそれを表示する**。
    /// 行のクリック・戻る・進む・1階層上へ、の4つすべてがここを通る。
    ///
    /// ユーザーの指示による整理。当初は行のクリックだけが本を開き、それ以外で到達したときは
    /// 「このフォルダの画像を開く」という導線を出していたが、**移動した時点で表示しているのに
    /// 「開く」とは何か**という指摘を受けて1本のルールにした ―― 「フォルダブラウザの現在地 =
    /// 表示している本」が常に成り立つので、例外も追加のUIも要らない。
    ///
    /// 引き換えに、フォルダを行き来するたびに本が切り替わり、そのぶん履歴と読書位置に記録が
    /// 増える(承知のうえでの選択)。読書位置は本ごとに残るので、戻れば元の位置から再開できる。
    ///
    /// 開いた後に本の親フォルダへ再アンカーされると、移ったばかりの場所から弾き返されて
    /// しまうため、その1回だけ見送らせる(SidePanelBrowserState.skipsNextAnchor参照)。
    ///
    /// **ここを通らない場所の変わり方もある** ―― 履歴やお気に入りから本を開いたときの
    /// 再アンカー(handlePanelRevealed)がそれで、あちらは「開いた本に合わせて表示を移す」
    /// 逆向きの動きなので、ここで本を開き直してはいけない(無限に開き直すことになる)。
    private func moveAndShowImages(_ move: () -> Void) {
        move()
        guard let directory = folderState.currentDirectory,
              DirectoryBrowser.directlyContainsImageFile(directory),
              !isCurrentBookFolder(directory) else { return }
        folderState.skipNextAnchorOnce()
        onBrowseToFolder(directory)
    }

    /// フォルダ行のシングルクリック(「開く・移動をダブルクリックにする」がOFFのとき)。
    ///
    /// ■ 行き止まりの本(画像しか入っていないフォルダ)は、中へ移動せずその場で開く
    /// 以前はどのフォルダも一律に「中へ移動し、画像があればそれを表示」だった
    /// (moveAndShowImages)。画像だけのフォルダに入ると、一覧は画像を並べない仕様のため
    /// 空になり、「このフォルダの画像を表示しています」というバナーで理由を説明していた。
    /// ユーザーからの提案で、こうしたフォルダは右クリック→「開く」と同じ扱い(親の一覧に
    /// 留まり、その行が選択色になる)に変えた ―― 空の一覧にバナーを出すより、親の一覧で
    /// 行が強調されているほうが「いまどのフォルダを見ているか」「隣は何か」が一目で分かる。
    ///
    /// この見え方は、履歴・お気に入り・Finderから本を開いたときや、画像ファイルを直接
    /// 開いたときにブラウザが取る見え方(親に留まって本の行を強調。SidePanelBrowserState.
    /// browserAnchor参照)と同じで、辿り着き方による食い違いがむしろ減る。
    /// 行の強調は、本が切り替わったときの再アンカー(handlePanelRevealed)がそのまま担う。
    ///
    /// 右クリック→「開く」と同じなので、履歴にも残る(moveAndShowImagesが残さないのは
    /// 「目的の本を探して通り抜けただけのフォルダ」を想定してのことで、行き止まりは
    /// 通り抜けではなく目的地)。パネルを自動で隠す設定のときに閉じる点も「開く」と同じ。
    ///
    /// ■ サブフォルダがあるフォルダは従来どおり
    /// 先に進める場所がある以上、中へ移動する必要がある。画像が同居していれば表示も行い、
    /// 一覧の先頭にバナーが出る(こちらは通り抜けなので履歴には残さない)。
    private func handleFolderClick(_ entry: DirectoryBrowser.Entry) {
        if entry.isLeafBookFolder {
            onOpen(entry.url)
        } else {
            moveAndShowImages { folderState.navigate(into: entry.url) }
        }
    }

    private func handleFolderDoubleClick(_ entry: DirectoryBrowser.Entry) {
        // 一覧の読み込み時に確定させた値を読むだけ(以前はここでその都度ディスクを見ていた)。
        // 右クリックメニューの出し分けと同じ値を使うので、「メニューには『開く』が出るのに
        // ダブルクリックでは移動してしまう」といった食い違いが起きない。
        if entry.containsImageFile {
            onOpen(entry.url)
        } else {
            folderState.navigate(into: entry.url)
        }
    }

    private func rowLabel(icon: String, name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .panelOutlinedContent()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func iconName(fileName: String?, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        return sidePanelFileIconName(fileName: fileName)
    }
}

/// ファイル名(拡張子)から行アイコンを決める。SidePanelView.iconNameと、ブックマークモードの
/// お気に入りツリー(SidePanelFavoriteRow)の両方から使うため、View外の関数として切り出している。
private func sidePanelFileIconName(fileName: String?) -> String {
    guard let fileName else { return "doc" }
    if isArchiveFile(fileName) { return "doc.zipper" }
    if isPDFFile(fileName) { return "doc.richtext" }
    if isEpubFile(fileName) { return "book" }
    return "doc"
}

/// サイドパネル下段(本の中身ブラウザ)。@ObservedObjectはOptionalなObservableObjectを
/// 直接ラップできないため、親(SidePanelView)がbookContentsStateの有無で表示自体を
/// 出し分け、非nilのときだけこの専用のView(stateを非Optionalで受け取る)を使う構成にしている。
private struct BookContentsSectionView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var state: BookContentsBrowserState
    var bookPages: [PageRef]
    var bookSourceURL: URL?
    /// 右クリックメニューの文言(追加/削除)の判定用(SidePanelView.bookmarkedPageIndices参照)。
    var bookmarkedPageIndices: Set<Int>
    /// falseならブックマークの項目をグレーアウトする(SidePanelView.allowsLibraryEditing参照)。
    var allowsBookmarking: Bool
    var onOpen: (URL) -> Void
    var onJumpToPage: (Int) -> Void
    var onExportPage: ((Int) -> Void)?
    var onToggleBookmark: (Int) -> Void

    /// 上段と同じ絞り込み検索欄の入力内容(SidePanelView.folderFilterText参照)。
    /// 本の中の階層を移動したら空に戻す。
    @State private var filterText = ""

    /// 絞り込みを適用した一覧。
    private var filteredEntries: [BookInternalBrowsing.Entry] {
        let trimmed = filterText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return state.entries }
        return state.entries.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SidePanelNavButton(systemName: "chevron.left", isDisabled: !state.canGoBack, help: "Back") {
                    state.goBack()
                }
                SidePanelNavButton(systemName: "chevron.right", isDisabled: !state.canGoForward, help: "Forward") {
                    state.goForward()
                }
                SidePanelNavButton(systemName: "arrow.up", isDisabled: !state.canGoUp, help: "Enclosing Folder") {
                    state.goUp()
                }
                Spacer(minLength: 0)
            }
            .padding(10)

            // ユーザー要望: 本の中の階層を移動しているときは、今どこにいるか分かるよう
            // ボタンの下にフォルダ/書庫のファイル名を表示する。ルート階層(本自身)にいる
            // ときはstate.currentLocationNameがnilになり、この行自体を出さない。
            if let locationName = state.currentLocationName {
                Text(locationName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .panelOutlinedContent()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .help(locationName)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SidePanelSearchField(text: $filterText)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .onChange(of: state.currentLocationName) { _, _ in filterText = "" }

            Divider()

            if let errorMessage = state.navigationErrorMessage {
                VStack {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .panelOutlinedContent()
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let entries = filteredEntries
                if entries.isEmpty && !state.entries.isEmpty {
                    SidePanelEmptyMessage(textKey: "(No Matches)")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(entries) { entry in
                                    row(for: entry)
                                }
                            }
                        }
                        // folderSectionの同名の.focusable(false)と同じ理由。
                        .focusable(false)
                        // 「サイドパネルを隠す」がONで、カーソルを左端に近づけてパネルが
                        // 現れた瞬間にも、現在のページの行が見えている状態から始める
                        // (ユーザー要望)。このときBookContentsBrowserState自体はContentViewが
                        // 保持し続けていてハイライト対象(highlightedMatchKeys)も一覧(entries)も
                        // 変わっていないため、下の.onChangeはどちらも発火せず、作り直された
                        // ScrollViewが先頭のまま表示されてしまっていた。ページモードの一覧が
                        // .onAppearでも現在ページへ合わせているのと同じ対処
                        // (SidePanelPagesSectionView.scrollToCurrent参照)。
                        // 現れた瞬間のスクロールはアニメーションさせない(パネルのスライドインと
                        // 同時に中身も動くと落ち着かないため)。
                        .onAppear { scrollToHighlighted(proxy: proxy, animated: false) }
                        // ページ送りでハイライト対象が変わるたび、またはハイライト対象を含む
                        // 新しい階層へ切り替わって一覧そのものが変わるたびに、その行が常に
                        // 表示枠内に見えるようスクロールする(ユーザー要望)。
                        .onChange(of: state.highlightedMatchKeys) { _, _ in scrollToHighlighted(proxy: proxy) }
                        .onChange(of: state.entries) { _, _ in scrollToHighlighted(proxy: proxy) }
                    }
                }
            }
        }
    }

    private func scrollToHighlighted(proxy: ScrollViewProxy, animated: Bool = true) {
        // 絞り込みで一覧から外れている行へはスクロールできない(folderSectionと同じ理由)。
        guard let target = filteredEntries.first(where: { state.highlightedMatchKeys.contains($0.matchKey) }) else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo(target.id, anchor: .center) }
            } else {
                proxy.scrollTo(target.id, anchor: .center)
            }
        }
    }

    private func row(for entry: BookInternalBrowsing.Entry) -> some View {
        let isHighlighted = state.highlightedMatchKeys.contains(entry.matchKey)
        let label = HStack(spacing: 8) {
            Image(systemName: icon(for: entry))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(entry.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        // アイコンと文字だけのHStackなので、まとめて輪郭を掛けてよい
        // (**背景を敷く前に**掛けること。後ろに回すとハイライトの地まで縁取られる)。
        .panelOutlinedContent()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        // 選択行のハイライトも、重ね色がアクセントカラーに近いと消える(同上)。
        .panelOutlinedAccent(in: Rectangle(), isEnabled: isHighlighted)

        // 下段のコンテナ・画像はどちらも1つの意味しか持たない(上段のフォルダのような
        // 「移動する」「開く」の使い分けが無い)ため、設定に応じてクリック回数を
        // そのまま切り替えるだけでよい。
        let clickCount = preferences.sidePanelUsesDoubleClick ? 2 : 1
        return Group {
            if entry.isContainer {
                label.onTapGesture(count: clickCount) { state.navigate(entry) }
            } else if entry.isImage {
                label.onTapGesture(count: clickCount) { handleImageClick(entry) }
            } else {
                label
            }
        }
        .sidePanelContextHighlight(rowID: "contents:\(entry.id)")
        .contextMenu {
            contextMenuItems(for: entry)
        }
    }

    /// 下段の1行の右クリックメニュー(ユーザー要望)。
    ///
    /// この一覧には「ディスク上に実在するもの(フォルダの本の中身、入れ子の書庫ファイル)」と
    /// 「書庫の中にしか存在しないもの(仮想フォルダ、書庫内の画像)」が混ざる。前者は
    /// そのままFinderで示せるが、後者はFinderからは見えないので、代わりに**本そのもの**を
    /// 示す(ユーザー要望どおりの挙動)。
    ///
    /// 画像の行は、本のページとして特定できたときだけページ用の共通メニュー
    /// (PageContextMenuItems)へ委ねる。こうすると「書庫内の画像には画像をエクスポートも
    /// 出す」という判断がページ一覧・ページモードとひとりでに揃う。
    @ViewBuilder
    private func contextMenuItems(for entry: BookInternalBrowsing.Entry) -> some View {
        if entry.isImage, let index = bookPages.firstIndex(where: { $0.sortKey == entry.matchKey }) {
            PageContextMenuItems(
                page: bookPages[index],
                bookSourceURL: bookSourceURL,
                onExport: onExportPage.map { export in { export(index) } },
                isBookmarked: bookmarkedPageIndices.contains(index),
                allowsBookmarking: allowsBookmarking,
                onToggleBookmark: { onToggleBookmark(index) }
            )
        } else if let url = revealTargetURL(for: entry) {
            Button("Show in Finder") {
                FinderReveal.reveal(url)
            }
        }
    }

    /// ページとして特定できなかった行(仮想フォルダ、入れ子の書庫、レイアウトで除外された
    /// 画像など)を「Finderで開く」ときに指す実体。
    private func revealTargetURL(for entry: BookInternalBrowsing.Entry) -> URL? {
        switch entry.navigateTarget {
        case .realFolder(let url), .archiveFileOnDisk(let url):
            // ディスク上に実在するフォルダ/書庫ファイル。そのまま示せる。
            return url
        case .archiveVirtualFolder, .nestedArchiveEntry:
            // 書庫の中にしか存在しない。本そのものを示す。
            return bookSourceURL
        case nil:
            // 画像(またはその他のファイル)。フォルダの本ではmatchKeyが絶対パスそのもの
            // (BookInternalBrowsing.folderEntries/imageFileEntries参照)なので、それが実在
            // すればその実体を示す。書庫の中の画像ならパスではないので本そのものを示す。
            if entry.matchKey.hasPrefix("/"), FileManager.default.fileExists(atPath: entry.matchKey) {
                return URL(fileURLWithPath: entry.matchKey)
            }
            return bookSourceURL
        }
    }

    private func icon(for entry: BookInternalBrowsing.Entry) -> String {
        if entry.isImage { return "photo" }
        switch entry.navigateTarget {
        case .realFolder, .archiveVirtualFolder:
            return "folder"
        case .archiveFileOnDisk, .nestedArchiveEntry:
            return "doc.zipper"
        case nil:
            return "doc"
        }
    }

    private func handleImageClick(_ entry: BookInternalBrowsing.Entry) {
        switch state.resolveImageClick(on: entry, bookPages: bookPages) {
        case .jumpToPage(let index):
            onJumpToPage(index)
        case .openAsNewBook(let url):
            onOpen(url)
        case .unavailable:
            break
        }
    }
}

// MARK: - モード切替スイッチ

/// パネル最上部の表示モード切替スイッチ(ユーザー要望)。ポップアップメニューやセグメント
/// コントロールではなく、モードの数だけボタンを横に並べて「ワンクリックで直接そのモードへ
/// 切り替わる」形にしている。ボタンはクリックしやすいよう、SidePanelNavButton(28pt高)より
/// さらに一回り大きい30pt高+パネル幅を等分した幅を取る。
///
/// 表示はアイコンのみで、モード名はカーソルを合わせたときのツールチップで示す(ユーザー要望)。
/// 以前はパネル幅に余裕があればアイコン+モード名、狭ければアイコンのみ、と自動で切り替えて
/// いたが、幅やモード数によって見た目が変わるより、常に同じ並び・同じ大きさのアイコンが
/// 並んでいる方が分かりやすいとの判断による。
private struct SidePanelModeSwitcher: View {
    @Binding var mode: SidePanelMode

    private static let spacing: CGFloat = 6
    private static let buttonHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(SidePanelMode.allCases) { candidate in
                let isSelected = candidate == mode
                Button {
                    // 既に選ばれているモードをもう一度押した場合も、同じ値の代入になるだけで
                    // 実害は無い(意味の無い再描画を避けたい場合だけガードする価値があるが、
                    // ここは押下頻度が低くコストも小さいためガードしない)。
                    mode = candidate
                } label: {
                    Image(systemName: candidate.systemImage)
                        // アイコンだけになったぶん、以前(13pt)より一回り大きくして
                        // 何のモードか判別しやすくする。
                        .font(.system(size: 15, weight: .medium))
                        // 未選択のボタンは地が7%しかなく、実質パネルの上に直接アイコンが
                        // 乗っているのと同じなので輪郭を掛ける。選択中は不透明なアクセント色の
                        // 地があるため掛けない(掛けると縁だけ浮いて見える)。
                        .panelOutlinedContent(isEnabled: !isSelected)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.buttonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
                        )
                        // 重ね色をアクセントカラーに近い色にすると、選択中の地がパネルへ溶けて
                        // どれが選ばれているか分からなくなる。縁取って区別を残す
                        // (panelOutlinedAccentのコメント参照)。
                        .panelOutlinedAccent(
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous),
                            isEnabled: isSelected
                        )
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(candidate.titleKey)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

// MARK: - ブックマークモード上段(お気に入りツリー)

/// ブックマークモードの上段。お気に入りをフォルダ階層のままツリー表示し、上部に「今の本を
/// お気に入りに追加」「お気に入りの編集ウインドウを開く」の2ボタンを置く(ユーザー要望)。
///
/// 「お気に入りの整理」ウインドウ(FavoritesOrganizerView)がListのDisclosureGroupで組んで
/// いるのに対し、ここはScrollView+LazyVStackに自前の三角マーク付きの行を並べている。
/// List/DisclosureGroupは自前の背景(マテリアル)を持つこの狭いパネルの中では見た目が
/// 浮いてしまうため、パネル内の他のセクション(フォルダブラウザ・本の中身ブラウザ)と
/// 同じ、素朴な行の並びに揃えている。
private struct SidePanelFavoritesSectionView: View {
    @ObservedObject var favoritesStore: FavoritesStore
    @Binding var expandedFolderIDs: Set<UUID>
    var hasBook: Bool
    /// falseなら追加・編集ボタンを無効にする(SidePanelView.allowsLibraryEditing参照)。
    var allowsEditing: Bool
    var onAdd: () -> Void
    var onEdit: () -> Void
    var onOpen: (FavoriteBook) -> Void
    /// 行の右クリックから、新しいウインドウ/タブで開く(SidePanelView.onOpenFavoriteInNewWindow)。
    var onOpenInNewWindow: (FavoriteBook, BookOpenDestination) -> Void
    /// 行の右クリックからのリネーム・削除(SidePanelView.onRenameFavorite / onDeleteFavorite)。
    var onRename: (FavoriteListEntry) -> Void
    var onDelete: (FavoriteListEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SidePanelNavButton(
                    systemName: "plus",
                    isDisabled: !hasBook || !allowsEditing,
                    help: "Add This Book to Favorites…"
                ) {
                    onAdd()
                }
                SidePanelNavButton(systemName: "pencil", isDisabled: !allowsEditing, help: "Edit Favorites…") {
                    onEdit()
                }
                Spacer(minLength: 0)
            }
            .padding(10)

            // フォルダブラウザの現在地表示(SidePanelView.folderSection)と同じ位置・同じ
            // 書式の見出し。上下2つの段がそれぞれ何の一覧なのかを一目で分かるようにする。
            Text("Favorites")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .panelOutlinedContent()
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            let entries = favoritesStore.entries(in: nil)
            if entries.isEmpty {
                SidePanelEmptyMessage(textKey: "(No Favorites)")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            SidePanelFavoriteRow(
                                entry: entry,
                                depth: 0,
                                favoritesStore: favoritesStore,
                                expandedFolderIDs: $expandedFolderIDs,
                                allowsEditing: allowsEditing,
                                onOpen: onOpen,
                                onOpenInNewWindow: onOpenInNewWindow,
                                onRename: onRename,
                                onDelete: onDelete
                            )
                        }
                    }
                }
                // folderSection/BookContentsSectionViewの同名の.focusable(false)と同じ理由。
                .focusable(false)
            }
        }
    }
}

/// お気に入りツリーの1行。SwiftUIでは`some View`を返す関数は自分自身を再帰呼び出しできない
/// ため、専用のView構造体として実装する(FavoritesOrganizerView.OrganizerFolderRowと同じ理由)。
private struct SidePanelFavoriteRow: View {
    let entry: FavoriteListEntry
    /// ルート直下を0とした階層の深さ。インデント量の計算にだけ使う。
    let depth: Int
    @ObservedObject var favoritesStore: FavoritesStore
    @Binding var expandedFolderIDs: Set<UUID>
    /// falseならリネーム・削除の項目を無効にする(SidePanelView.allowsLibraryEditing参照)。
    /// 開く操作・Finderで開くは読み取りなので、falseでも通常どおり使える。
    let allowsEditing: Bool
    let onOpen: (FavoriteBook) -> Void
    let onOpenInNewWindow: (FavoriteBook, BookOpenDestination) -> Void
    let onRename: (FavoriteListEntry) -> Void
    let onDelete: (FavoriteListEntry) -> Void

    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        switch entry {
        case .folder(let folder):
            let isExpanded = expandedFolderIDs.contains(folder.id)
            folderRow(folder, isExpanded: isExpanded)
            if isExpanded {
                ForEach(favoritesStore.entries(in: folder)) { child in
                    SidePanelFavoriteRow(
                        entry: child,
                        depth: depth + 1,
                        favoritesStore: favoritesStore,
                        expandedFolderIDs: $expandedFolderIDs,
                        allowsEditing: allowsEditing,
                        onOpen: onOpen,
                        onOpenInNewWindow: onOpenInNewWindow,
                        onRename: onRename,
                        onDelete: onDelete
                    )
                }
            }
        case .book(let book):
            bookRow(book)
        }
    }

    private func folderRow(_ folder: FavoriteFolder, isExpanded: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Image(systemName: "folder")
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(folder.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .panelOutlinedContent()
        .padding(.leading, 8 + CGFloat(depth) * 12)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(folder.name)
        // 展開/折りたたみは、環境設定「サイドパネルの操作をダブルクリックにする」の値に
        // 関わらず常にシングルクリック。あの設定は「本を開く」「フォルダへ移動する」という
        // 取り消しの効かない/表示が大きく変わる操作を誤操作から守るためのもので、その場で
        // 見た目が開閉するだけのこの操作は対象外(戻る/進むボタンが常にシングルクリックなのと
        // 同じ考え方)。
        .onTapGesture {
            if isExpanded {
                expandedFolderIDs.remove(folder.id)
            } else {
                expandedFolderIDs.insert(folder.id)
            }
        }
        // フォルダは本ではないので「開く」系は無く、整理の2項目だけになる
        // (下のbookRowのコメント参照)。
        .sidePanelContextHighlight(rowID: "favoriteFolder:\(folder.id.uuidString)")
        .contextMenu {
            Button("Rename") { onRename(.folder(folder)) }
                .disabled(!allowsEditing)
            Button("Delete", role: .destructive) { onDelete(.folder(folder)) }
                .disabled(!allowsEditing)
        }
    }

    private func bookRow(_ book: FavoriteBook) -> some View {
        HStack(spacing: 6) {
            // フォルダ行の三角マークぶんの幅を空けて、同じ階層のフォルダと本の名前の
            // 開始位置を揃える。
            Color.clear.frame(width: 10, height: 1)
            Image(systemName: sidePanelFileIconName(fileName: URL(fileURLWithPath: book.bookID).lastPathComponent))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(book.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .panelOutlinedContent()
        .padding(.leading, 8 + CGFloat(depth) * 12)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(book.title)
        // 本を開く操作は、パネル内の他の「開く」操作と同じく環境設定に従う。
        .onTapGesture(count: preferences.sidePanelUsesDoubleClick ? 2 : 1) { onOpen(book) }
        // ユーザー要望: 無理のない範囲でコンテキストメニューを足す。
        //
        // ■ 編集系(名前の変更・お気に入りからの削除)について
        // 当初は「開く」と「Finderで表示」だけに絞り、編集系は「お気に入りの編集」ウインドウ
        // (FavoritesOrganizerView)の担当としていた ―― 取り消しの効かない操作を幅の狭い
        // パネルの行の右クリックに置くと、掴み損ねたドラッグの直後などに誤って選ぶ危険が
        // 増えるため。**その後ユーザーの指示で方針を変え、ここにも置いてある。**
        // 誤操作への備えは「編集ウインドウでしかできなくする」ことではなく、削除に確認
        // ダイアログを挟むこと(お気に入りの流儀。ContentView側のアラート参照)で担保する。
        //
        // Finderで示す対象は、パス文字列(book.bookID)から組み立てたURLではなく、
        // **保存済みのセキュリティスコープ付きブックマークを解決したURL**にする。
        // 素のパスから作ったURLにはアクセス権が付かず、サンドボックス下では
        // FinderReveal側の存在確認が失敗して何も起きない(そちらのコメント参照)。
        // 解決を通せば、本が移動・リネームされていても現在の場所を示せるという利点もある。
        .sidePanelContextHighlight(rowID: "favorite:\(book.id.uuidString)")
        .contextMenu {
            BookOpenContextMenuItems(
                onOpen: { onOpen(book) },
                onOpenIn: { onOpenInNewWindow(book, $0) }
            )
            Divider()
            Button("Show in Finder") {
                guard let url = favoritesStore.resolvedExistingURL(for: book) else { return }
                FinderReveal.reveal(url)
            }
            Divider()
            // 編集系は最後にまとめ、取り消しの効かない削除をいちばん下に置く(macOSの作法)。
            // シークレットウインドウとその場限りの本では、DBへ書けないので無効になる。
            Button("Rename") { onRename(.book(book)) }
                .disabled(!allowsEditing)
            Button("Remove from Favorites", role: .destructive) { onDelete(.book(book)) }
                .disabled(!allowsEditing)
        }
    }
}

// MARK: - ブックマークモード下段(ブックマーク一覧)

/// ブックマークモードの下段。今開いている本のブックマークを一覧表示し、上部に「今のページを
/// ブックマークに追加」「ブックマークの編集ウインドウを開く」の2ボタンを置く(ユーザー要望)。
/// 一覧はメニューバーの「ブックマーク一覧」と同じ内容(AppState.currentBookmarks)で、
/// 今表示中のページに対応する行をハイライトする。
private struct SidePanelBookmarksSectionView: View {
    @EnvironmentObject private var preferences: AppPreferences
    var bookmarks: [Bookmark]
    var currentPageIndex: Int
    var hasBook: Bool
    /// falseなら追加・編集ボタンを無効にする(SidePanelView.allowsLibraryEditing参照)。
    var allowsEditing: Bool
    var onAdd: () -> Void
    var onEdit: () -> Void
    var onJump: (Bookmark) -> Void
    /// 行の右クリックからのリネーム・削除(SidePanelView.onRenameBookmark / onDeleteBookmark)。
    var onRename: (Bookmark) -> Void
    var onDelete: (Bookmark) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SidePanelNavButton(
                    systemName: "plus",
                    isDisabled: !hasBook || !allowsEditing,
                    help: "Add This Page to Bookmarks"
                ) {
                    onAdd()
                }
                SidePanelNavButton(systemName: "pencil", isDisabled: !allowsEditing, help: "Edit Bookmarks…") {
                    onEdit()
                }
                Spacer(minLength: 0)
            }
            .padding(10)

            Text("Bookmarks")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .panelOutlinedContent()
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            if bookmarks.isEmpty {
                SidePanelEmptyMessage(textKey: "(No Bookmarks)")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(bookmarks, id: \.id) { bookmark in
                            row(for: bookmark)
                        }
                    }
                }
                // folderSection/BookContentsSectionViewの同名の.focusable(false)と同じ理由。
                .focusable(false)
            }
        }
    }

    private func row(for bookmark: Bookmark) -> some View {
        let isCurrent = bookmark.pageIndex == currentPageIndex
        return HStack(spacing: 8) {
            Image(systemName: isCurrent ? "bookmark.fill" : "bookmark")
                .frame(width: 16)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            Text(bookmark.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // ページ番号は1始まりで表示する(メニューバーの「ブックマーク一覧」と同じ)。
            Text("\(bookmark.pageIndex + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .panelOutlinedContent()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
        .help(bookmark.name)
        // ページへのジャンプも「開く」に準じる操作のため、環境設定に従う。
        .onTapGesture(count: preferences.sidePanelUsesDoubleClick ? 2 : 1) { onJump(bookmark) }
        // ユーザー要望: 無理のない範囲でコンテキストメニューを足す。
        // このモードの一覧は「今開いている本」のブックマークなので、行ごとに別の本を
        // Finderで示す、という状況は生じない(それは上段のお気に入り側の役目)。
        //
        // 名前の変更・削除も、お気に入りの行と同じくここから直接行える(ユーザーの指示。
        // 経緯は上のbookRowのコメント参照)。**削除に確認ダイアログは挟まない** ――
        // 「ブックマーク・レイアウトの編集」ウインドウのゴミ箱ボタンが確認なしで消す
        // 作りなので、同じものを別の場所から消したときに見え方が変わらないよう揃えてある
        // (お気に入りは逆に、あちらが確認する流儀なのでこちらも確認する)。
        .sidePanelContextHighlight(rowID: "bookmark:\(bookmark.id)")
        .contextMenu {
            Button("Go to This Page") { onJump(bookmark) }
            Button("Edit Bookmarks…") { onEdit() }
                .disabled(!allowsEditing)
            Divider()
            Button("Rename") { onRename(bookmark) }
                .disabled(!allowsEditing)
            Button("Delete Bookmark", role: .destructive) { onDelete(bookmark) }
                .disabled(!allowsEditing)
        }
    }
}

// MARK: - 履歴モード

/// 履歴モード。最近開いた本(RecentFilesStore)を新しい順に一覧表示する。上下2段には分けず、
/// パネルの全高を1つの一覧に使う(履歴と対になる自然な相方が無いため)。
///
/// 従来この一覧はウェルカム画面(本を開いていないときだけ見える)とファイルメニューの
/// 「Open Recent」からしか辿れなかった。本を読んでいる最中でも一覧として見られるように
/// するのがこのモードの目的(ユーザー要望)。保持件数は環境設定「一般」タブの
/// 「履歴の保存件数」で変更できる(既定30件)。
private struct SidePanelHistorySectionView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var recentFiles: RecentFilesStore
    var currentBookPath: String?
    var onOpen: (URL) -> Void
    /// 行の右クリックから、新しいウインドウ/タブで開く(SidePanelView.onOpenInNewWindow)。
    var onOpenInNewWindow: (URL, BookOpenDestination) -> Void

    @State private var filterText = ""
    /// 「履歴をすべて消去」の確認アラートの表示状態。取り消せない操作なので必ず1枚挟む
    /// (環境設定「リセット」画面と同じ考え方)。
    @State private var isShowingClearConfirmation = false

    private var filteredEntries: [RecentFilesStore.Entry] {
        let trimmed = filterText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return recentFiles.entries }
        return recentFiles.entries.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 履歴をすべて消去するボタン(ユーザー要望)。他のモードの上部ボタン列
            // (ブラウザモードの戻る/進む、ブックマークモードの＋/鉛筆)と同じ位置・同じ
            // 見た目に揃えてある。履歴が無いときはグレーアウトする。
            HStack(spacing: 6) {
                SidePanelNavButton(
                    systemName: "trash",
                    isDisabled: recentFiles.entries.isEmpty,
                    help: "Clear History"
                ) {
                    isShowingClearConfirmation = true
                }
                Spacer(minLength: 0)
            }
            .padding(10)

            // 他のモードのセクションと同じ位置・同じ書式の見出し。件数を添えて、環境設定で
            // 増やした保存件数がどこまで溜まっているか分かるようにする。
            HStack(spacing: 6) {
                Text("History")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(recentFiles.entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .panelOutlinedContent()
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            SidePanelSearchField(text: $filterText)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            Divider()

            let entries = filteredEntries
            if recentFiles.entries.isEmpty {
                SidePanelEmptyMessage(textKey: "(No Recent Files)")
            } else if entries.isEmpty {
                SidePanelEmptyMessage(textKey: "(No Matches)")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            row(for: entry)
                        }
                    }
                }
                // folderSection/BookContentsSectionViewの同名の.focusable(false)と同じ理由。
                .focusable(false)
            }
        }
        .alert("Clear History?", isPresented: $isShowingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                recentFiles.removeAll()
            }
        } message: {
            Text("This removes every entry from the History list and from the File menu's Open Recent. Your files are not touched.")
        }
    }

    private func row(for entry: RecentFilesStore.Entry) -> some View {
        // 今開いている本(MangaBook.id = パス)と同じ行を強調する。ハイライト判定を
        // URL同士の==ではなくパス文字列で行う理由は、SidePanelView.folderRowと同じ
        // (セキュリティスコープ付きブックマーク由来のURLは、パスが同じでも==が一致しない
        // ことがある)。
        // entry.path/isDirectoryはキャッシュ済みの情報で、参照してもファイルアクセスは
        // 発生しない(RecentFilesStoreの型コメント参照)。
        let isCurrent = entry.path == currentBookPath
        return HStack(spacing: 8) {
            Image(
                systemName: entry.isDirectory
                    ? "folder"
                    : sidePanelFileIconName(fileName: entry.displayURL.lastPathComponent)
            )
            .frame(width: 16)
            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            Text(entry.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .panelOutlinedContent()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
        // パスまで見せることで、同名の本が複数ある場合に見分けられるようにする。
        .help(entry.path)
        // 開く直前に初めてブックマークを解決する(解決できなければ履歴から取り除かれる)。
        .onTapGesture(count: preferences.sidePanelUsesDoubleClick ? 2 : 1) {
            guard let url = recentFiles.resolveForOpening(entry) else { return }
            onOpen(url)
        }
        .sidePanelContextHighlight(rowID: "history:\(entry.id)")
        .contextMenu {
            // 「開く」も「新規◯◯で開く」も、選ばれた時点で初めてブックマークを解決する
            // (解決できなければ履歴から取り除かれ、何も開かない)。行を描くたびに解決すると
            // 一覧全体でディスクを触ることになるため、必ずクロージャの中で行うこと。
            BookOpenContextMenuItems(
                onOpen: {
                    guard let url = recentFiles.resolveForOpening(entry) else { return }
                    onOpen(url)
                },
                onOpenIn: { destination in
                    guard let url = recentFiles.resolveForOpening(entry) else { return }
                    onOpenInNewWindow(url, destination)
                }
            )
            Divider()
            // entry.displayURLはセキュリティスコープの付いていない表示専用のURLなので、
            // フォルダかどうかを**キャッシュ済みの値から渡す**。渡さないとFinderReveal側の
            // 存在確認がサンドボックスに阻まれて失敗し、何も起きない
            // (FinderReveal.reveal(_:isDirectory:)のコメント参照)。
            // Finderへ場所を見せるよう頼むこと自体には、このアプリのアクセス権は要らない。
            Button("Show in Finder") {
                FinderReveal.reveal(entry.displayURL, isDirectory: entry.isDirectory)
            }
        }
    }
}

// MARK: - ページモード(ページ一覧)

/// ページモード。今開いている本の全ページを、ページ番号+サムネイル+ファイル名の縦一列で
/// 表示する(ユーザー要望による並び順。左から番号・サムネイル・ファイル名)。
///
/// レイアウト機能で除外(.excluded)したページはここには現れない。ここで表示している
/// `pages`はAppState.currentBookPages、すなわちViewerViewModelが除外・並べ替えを適用した
/// あとのbook.pagesが同期されたものであり、除外の解除/追加にもそのまま追従する
/// (ViewerViewModel.applyLayoutData / ViewerView.swiftの.onChange(of: viewModel.book.pages)参照)。
///
/// 既存の「ページ一覧」(ThumbnailGridView、tキー)は5列のオーバーレイパネルで、ページへ
/// ジャンプすると閉じる作りになっている。こちらは読みながら出しっぱなしにできる常設の
/// 一覧として、細い1列に絞り、現在ページへ自動スクロールする(ユーザー要望)。
///
/// サムネイルの取得はAppState経由の橋渡し(loadThumbnail)で行う。実体はThumbnailGridViewと
/// 同じPageLoaderの軽量サムネイルキャッシュのため、両方を使ってもデコードが二重になることは無い。
private struct SidePanelPagesSectionView: View {
    var pages: [PageRef]
    /// 本そのものの場所(右クリックの「Finderで開く」用。PageContextMenuItems参照)。
    var bookSourceURL: URL?
    var currentPageIndex: Int
    /// ブックマークが付いているページ番号(0始まり)。一覧の行にしおりアイコンで示すほか、
    /// 右クリックメニューの文言(追加/削除)の判定にも使う。
    var bookmarkedPageIndices: Set<Int>
    /// falseならブックマークの項目をグレーアウトする(SidePanelView.allowsLibraryEditing参照)。
    var allowsBookmarking: Bool
    var thumbnailGeneration: Int
    var loadThumbnail: ((Int) async -> CGImage?)?
    /// ホバー時の拡大プレビュー用(フル解像度)。
    var loadPageImage: ((Int) async -> CGImage?)?
    /// 拡大プレビューをパネルのどちら側へ出すか(SidePanelPageCell.previewArrowEdge参照)。
    var previewArrowEdge: Edge
    var onJumpToPage: (Int) -> Void
    /// 右クリックの「画像をエクスポート」(SidePanelView.onExportPage参照)。
    var onExportPage: ((Int) -> Void)?
    /// 右クリックの「このページをブックマークに追加/削除」(SidePanelView.onToggleBookmarkAtPage参照)。
    var onToggleBookmark: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Pages")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !pages.isEmpty {
                    // 「現在ページ / 総ページ数」。プログレスバーを隠しているときでも、
                    // 今どのあたりを読んでいるか分かるようにする。
                    Text("\(currentPageIndex + 1) / \(pages.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .panelOutlinedContent()
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            if pages.isEmpty || loadThumbnail == nil {
                SidePanelEmptyMessage(textKey: "(No Book Open)")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(pages.indices, id: \.self) { index in
                                SidePanelPageCell(
                                    index: index,
                                    displayName: pages[index].displayName,
                                    pageNumberWidth: pageNumberWidth,
                                    isCurrent: index == currentPageIndex,
                                    isBookmarked: bookmarkedPageIndices.contains(index),
                                    thumbnailGeneration: thumbnailGeneration,
                                    loadThumbnail: loadThumbnail,
                                    loadPageImage: loadPageImage,
                                    previewArrowEdge: previewArrowEdge,
                                    onTap: { onJumpToPage(index) }
                                )
                                .id(index)
                                .sidePanelContextHighlight(rowID: "page:\(index)")
                                // 右クリックの内容はページ一覧パネル・本の中身ブラウザと
                                // 完全に同じ(ユーザー要望。PageContextMenuItems参照)。
                                .contextMenu {
                                    PageContextMenuItems(
                                        page: pages[index],
                                        bookSourceURL: bookSourceURL,
                                        onExport: onExportPage.map { export in { export(index) } },
                                        isBookmarked: bookmarkedPageIndices.contains(index),
                                        allowsBookmarking: allowsBookmarking,
                                        onToggleBookmark: { onToggleBookmark(index) }
                                    )
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .focusable(false)
                    // ページ送りに合わせて、現在ページの行が常に見えるようスクロールする
                    // (サイドパネル上段のフォルダブラウザ・下段の本の中身ブラウザと同じ
                    // 考え方・同じ組み合わせ)。
                    // ・.onAppear: 「サイドパネルを隠す」がONのとき、カーソルを左端に近づけて
                    //   パネルが現れた瞬間にも現在ページが見えている状態から始める。作り直された
                    //   ScrollViewは先頭に戻ってしまうため必要(アニメーションはさせない。
                    //   パネルのスライドインと同時に中身も動くと落ち着かないため)。
                    // ・currentPageIndex: ページ送りでハイライト対象そのものが変わったとき。
                    // ・pages: レイアウトの除外/ページ順補正で一覧の中身が変わったとき。同じ
                    //   currentPageIndexでも行の位置が動くため、これも見る必要がある。
                    .onAppear { scrollToCurrent(proxy: proxy, animated: false) }
                    .onChange(of: currentPageIndex) { _, _ in scrollToCurrent(proxy: proxy, animated: true) }
                    .onChange(of: pages) { _, _ in scrollToCurrent(proxy: proxy, animated: true) }
                }
            }
        }
    }

    /// 先頭列のページ番号に割り当てる幅。総ページ数の桁数から見積もり、全行で同じ幅に固定する
    /// (行ごとに桁数が変わると、右隣のサムネイル・ファイル名の左端が揃わずガタつくため)。
    /// 数字は等幅(.monospacedDigit)で描画するので、1桁あたりの見込み幅×桁数で足りる。
    private var pageNumberWidth: CGFloat {
        let digits = max(2, String(pages.count).count)
        return CGFloat(digits) * 8 + 2
    }

    private func scrollToCurrent(proxy: ScrollViewProxy, animated: Bool) {
        guard pages.indices.contains(currentPageIndex) else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo(currentPageIndex, anchor: .center) }
            } else {
                proxy.scrollTo(currentPageIndex, anchor: .center)
            }
        }
    }
}

/// ページモードの1行。左からページ番号・サムネイル・ファイル名の順に並べる(ユーザー要望)。
/// ThumbnailGridView.ThumbnailCellと同じ理由で、読み込んだ画像は各行自身の@Stateに持つ
/// (1行の読み込み完了が一覧全体の再描画を引き起こさないようにするため)。
private struct SidePanelPageCell: View {
    let index: Int
    /// 3列目に出すファイル名(PageRef.displayName)。
    let displayName: String
    /// 1列目のページ番号に割り当てる固定幅(SidePanelPagesSectionView.pageNumberWidth参照)。
    let pageNumberWidth: CGFloat
    let isCurrent: Bool
    let isBookmarked: Bool
    let thumbnailGeneration: Int
    let loadThumbnail: ((Int) async -> CGImage?)?
    let loadPageImage: ((Int) async -> CGImage?)?
    /// 拡大プレビュー(popover)を出す向き。パネルのビューア側 ― 左配置なら右へ、右配置なら
    /// 左へ ― に出すことで、プレビューがパネル自身や画面の外へはみ出さないようにする
    /// (SidePanelPosition.innerEdge)。
    let previewArrowEdge: Edge
    let onTap: () -> Void

    @State private var image: CGImage?

    /// カーソルがサムネイルの上にあるかどうか。拡大プレビュー用のpopoverの表示制御に使う
    /// (ページ一覧グリッド・「ブックマーク・レイアウトの編集」ウインドウと同じ拡大プレビューを
    /// ここでも出してほしい、というユーザー要望)。
    @State private var isHoveringThumbnail = false
    /// 拡大プレビュー用のフル解像度画像。一度読み込めば、同じ行を何度ホバーしても読み込み直さない
    /// よう@Stateにキャッシュしておく(素早くホバーを出し入れしたときのちらつき防止)。
    @State private var previewImage: CGImage?
    /// ホバー開始から実際にpopoverを出すまでの遅延用タスク。
    @State private var hoverPreviewTask: Task<Void, Never>?
    /// ホバー開始から実際にpopoverを出すまでの遅延(ナノ秒)。ThumbnailGridView.ThumbnailCell /
    /// BookmarkListView.PageRowViewのhoverPreviewDelayNanosecondsと同じ値(350ms)を使う。
    /// 遅延は環境設定(AppPreferences.thumbnailHoverPreviewDelay)。ON/OFFの設定はページ一覧
    /// 専用で、ここには効かせない(サイズ調整の無いサムネイルでは、拡大が無いと何のページか
    /// 分からなくなるため。ユーザー指示)。
    @EnvironmentObject private var preferences: AppPreferences
    /// 拡大プレビューの一辺。ページ一覧グリッド・「ブックマーク・レイアウトの編集」ウインドウ・
    /// 書き出しウインドウの拡大プレビューと揃える(ユーザー要望)。以前は4箇所それぞれに440と
    /// 直接書いていたが、環境設定から変えられるようにしたため、そちらを読む
    /// (AppPreferences.thumbnailHoverPreviewSideLength参照)。
    private var previewSize: CGFloat { preferences.thumbnailHoverPreviewSideLength }

    private static let thumbnailHeight: CGFloat = 72

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                .panelOutlinedContent()
                .lineLimit(1)
                .frame(width: pageNumberWidth, alignment: .trailing)

            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.15))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: Self.thumbnailHeight * 0.75, height: Self.thumbnailHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            // サムネイルにカーソルを乗せている間、拡大プレビューとファイル名を表示する
            // (ユーザー要望)。ホバーした瞬間に即座にpopoverを出さず、一定時間
            // (hoverPreviewDelayNanoseconds)ホバーし続けた場合にだけ表示する。一覧を縦に
            // 通り抜けるだけの動きで次々popoverが開くのを避けるため。
            .onHover { hovering in
                hoverPreviewTask?.cancel()
                if hovering, loadPageImage != nil {
                    hoverPreviewTask = Task {
                        try? await Task.sleep(nanoseconds: preferences.thumbnailHoverPreviewDelayNanoseconds)
                        guard !Task.isCancelled else { return }
                        isHoveringThumbnail = true
                    }
                } else {
                    hoverPreviewTask = nil
                    isHoveringThumbnail = false
                }
            }
            .popover(isPresented: $isHoveringThumbnail, arrowEdge: previewArrowEdge) {
                thumbnailPreviewContent
            }

            Text(displayName)
                .font(.caption)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                // この行はサムネイル(画像)と同じHStackに入っているため、まとめて掛けられない。
                // 文字とブックマーク印にだけ個別に掛ける。
                .panelOutlinedContent()
                // パネルは幅が狭く、ファイル名は長くなりがちなため2行まで折り返す。それでも
                // 収まらない場合は中間を省略する(先頭も末尾も手がかりになるファイル名が多いため)。
                .lineLimit(2)
                .truncationMode(.middle)
                .help(displayName)
            if isBookmarked {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .panelOutlinedContent()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
                .padding(.horizontal, 4)
        )
        // ページ送りは他のパネル操作と違って行き来が頻繁なため、「開く」ほど重い操作では
        // ない。とはいえ一覧内の操作としては同じ性質のため、他の行と同じく環境設定
        // (シングル/ダブルクリック)には従う……のではなく、ここでは常にシングルクリックに
        // している。この一覧は読みながら出しっぱなしにして次々ページを送る用途のもので、
        // ダブルクリックを要求すると本来の使い勝手を損なうため(既存のページ一覧グリッドも
        // 常にシングルクリックで、設定の影響を受けない)。
        .onTapGesture { onTap() }
        // 本を切り替えると同じindexでも中身が変わるため、世代番号も識別子に含めて
        // 読み込み直させる(AppState.loadPageThumbnailのコメント参照)。
        .task(id: "\(thumbnailGeneration)#\(index)") {
            image = await loadThumbnail?(index)
        }
    }

    /// サムネイルをホバーしたときのpopoverの中身。フル解像度画像(previewImage)とファイル名を
    /// 縦に並べる。構成・サイズ(一辺は環境設定。previewSize参照)はThumbnailGridView.ThumbnailCell /
    /// BookmarkListView.PageRowViewのthumbnailPreviewContentと揃えてある(ユーザー要望)。
    /// popoverが実際に画面へ表示されるたびに.taskが実行される(SwiftUIのpopoverは表示のたびに
    /// コンテンツビューを作り直すため)ので、まだ読み込んでいなければそこで読み込む。
    /// previewImageは@Stateとして親(SidePanelPageCell)側に持たせているため、閉じて再度
    /// ホバーしても読み込み直さない。
    private var thumbnailPreviewContent: some View {
        VStack(spacing: 8) {
            Group {
                if let previewImage {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(width: previewSize, height: previewSize)

            Text(displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: previewSize)
        }
        .padding(12)
        .task {
            guard previewImage == nil else { return }
            previewImage = await loadPageImage?(index)
        }
    }
}

/// 一覧を名前で絞り込むための検索欄(ユーザー要望: 1つのフォルダに数百冊入っているケースで、
/// 目的の本を素早く見つけられるようにする)。上段(フォルダブラウザ)・下段(本の中身ブラウザ)の
/// どちらでも同じものを使う。
///
/// 【注意】この入力欄を追加したことで、パネルにキーボードフォーカスを持つ要素が初めて存在する
/// ようになった。ViewerViewのNSEventローカルモニタは、同じウインドウ宛ての.keyDownを
/// ページ送り等のショートカットとして横取りするため、入力欄の編集中はそれを行わないよう
/// ViewerView側にガードを入れてある(makeScrollMonitorの.keyDownケース参照)。
///
/// フォーカスの外し方(欄の外のクリック・Return・Esc)は、他のウインドウの検索欄と共通の
/// `releasesFocusOnOutsideClick()`に任せる(FocusReleasingField.swift参照。ユーザー要望)。
private struct SidePanelSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .releasesFocusOnOutsideClick()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 一覧が空のときにセクション本体いっぱいに表示する案内文(お気に入り・ブックマークで共用)。
struct SidePanelEmptyMessage: View {
    let textKey: LocalizedStringKey

    var body: some View {
        Text(textKey)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .panelOutlinedContent()
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 上段・下段で共通の、戻る/進む/1階層上への移動ボタン。ユーザー要望: 既定のボタンサイズは
/// 小さく操作しづらいため、アイコンサイズ・タップ領域とも一回り大きくしている。
/// 具体的な装飾は、同じ見た目を使うツールバー・プログレスバーのボタンと共通化するため
/// PanelIconButtonLabelに切り出してある。
struct SidePanelNavButton: View {
    let systemName: String
    let isDisabled: Bool
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .panelIconButtonLabel()
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .help(help)
    }
}

/// 上段(フォルダブラウザ)の並べ替えメニュー(ユーザー要望)。「Finderで表示」ボタンの隣に
/// 並ぶ、他のボタンとまったく同じ見た目のアイコンボタンで、押すと基準(名前/サイズ/種類/
/// 作成日/変更日)と向き(昇順/降順)をチェックマーク付きで選べる。Finderの「並べ替え」と
/// 同じく、基準と向きは区切り線で分けた別のグループにしている。
///
/// 各グループをPicker(.inline)にしているのは、選択中の項目のチェックマークをSwiftUIに任せる
/// ため。Buttonを並べる形だと、macOSのメニューでのチェックマークの位置・字下げを自前で
/// 再現することになる。
///
/// SidePanelNavButtonと違いButtonではなくMenuのため、`.buttonStyle(.borderless)`ではなく
/// `.menuStyle(.borderlessButton)`と`.menuIndicator(.hidden)`で枠と下向き矢印を消し、
/// ラベル側は同じ`.panelIconButtonLabel()`を使って寸法・角丸を他のボタンと揃えている。
private struct SidePanelSortMenu: View {
    @Binding var key: FolderBrowserSortKey
    @Binding var direction: FolderBrowserSortDirection

    var body: some View {
        Menu {
            Picker(selection: $key) {
                ForEach(FolderBrowserSortKey.allCases) { key in
                    Text(key.titleKey).tag(key)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)

            Divider()

            Picker(selection: $direction) {
                ForEach(FolderBrowserSortDirection.allCases) { direction in
                    Text(direction.titleKey).tag(direction)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .panelIconButtonLabel()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Menuは既定で横に伸びようとするため、ラベル(panelIconButtonLabel)の寸法へ固定する。
        // これがないと、隣の「Finderで表示」ボタンとの間隔が広がって見える。
        .fixedSize()
        // 文字の影(環境設定「外観」)を、**ラベルの中ではなくMenu自体へ**掛ける。
        // panelIconButtonLabelがラベル側で掛ける輪郭は、`.borderlessButton`のMenuでは
        // 効かない ―― AppKitがラベルを描き直す際にSwiftUIの効果が落ちるらしく、白い面の上で
        // このボタンだけ跡形もなく消えることを実測で確認した(他のボタンは輪郭が出ていた)。
        // Menu全体へ掛ければ、描画済みの内容に対して効くため輪郭が出る。
        .panelOutlinedContent()
        .help("Sort By")
    }
}

/// サイドパネルの背景に使う、AppKit本来の「サイドバー」用マテリアル
/// (NSVisualEffectView.Material.sidebar)。SwiftUIの.background(.regularMaterial)は
/// 汎用のマテリアルのため、フル高さでタイトルバー直下から続くサイドバー配置だと、
/// ウインドウがキーのときだけ境界に沿って青いアクセントカラーの線が描画されてしまう
/// 不具合が実機で確認された(SidePanelView.bodyのコメント参照)。実際のFinder等のサイドバーと
/// 同じ.sidebarマテリアルを直接指定することでこれを回避する。
struct SidebarVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        // .behindWindowは、ウインドウの「背後」(デスクトップ/他のウインドウ)を透過して
        // 見せる方式で、ウインドウ全面がマテリアルになる典型的なサイドバー構成を想定した
        // モード。本アプリはウインドウの一部(このパネルの幅)だけがマテリアルで、残り
        // (ViewerView)は不透明なSwiftUIコンテンツという構成のため、ドラッグでパネルを
        // 拡大してViewerView側の描画領域へ一時的にはみ出す瞬間、.behindWindowのサンプリング
        // 対象(ウインドウの背後)と、そこに重なって描画され続けているViewerViewの不透明な
        // 内容とが競合し、拡大方向へドラッグしたときだけ震えて見える不具合が実機で確認
        // された(縮小方向は単に隠れていた領域を再び見せるだけのため問題が起きなかった)。
        // 同じウインドウ内の描画を基準にする.withinWindowに変更することでこれを避ける。
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
