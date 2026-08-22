import Foundation
import AppKit
import Combine
import SwiftUI
import SwiftData

/// アプリ全体で「今どの本を開いているか」を管理する。
/// 本棚は持たず、パネル選択・ドラッグ&ドロップ・Finderからの「開く」だけで本を開く。
@MainActor
final class AppState: ObservableObject {
    /// このウインドウがシークレットウインドウ(File › 新規シークレットウインドウ)かどうか。
    ///
    /// ■ 設計(ユーザー要望。Google Chromeのシークレットウインドウに倣った)
    /// アプリ全体のON/OFFトグルではなく**ウインドウ単位**の属性にしてある。AppStateは
    /// ウインドウごとに1つなので、「このウインドウで開いた本は何も記録しない」という性質が
    /// そのまま載り、通常ウインドウと並行して使える。ウインドウを閉じた時点で終わりなので、
    /// 「ONにした時点で既に開いていた本はどうなるのか」という中途半端な状態も生まれない。
    /// 生成時に確定し、以後変わらない(`let`)。
    ///
    /// ■ trueのとき書かないもの(=「その本を閉じた後に一切残らない」の定義)
    /// - 「最近開いたファイル」(RecentFilesStore)・「最後に開いていた本」(LastActiveBookStore)
    /// - 読書状態(BookReadingState。読書位置・表示モード等)
    /// - ブックマーク・お気に入り・レイアウト・メタデータの登録・編集、および
    ///   EPUB/PDF/ComicInfo.xmlからのそれらの自動取り込み
    /// - ディスク上のサムネイルキャッシュ(ThumbnailDiskCache)・ページ一覧キャッシュ
    ///   (BookPageListCache)
    /// - 本の移動・リネーム追従によるbookIDの書き換え(reconcileBookIDIfMoved)や識別子の補完
    ///   (backfillIdentifiers)。これらも既存行への書き込みなので行わない
    /// 既存データの**読み取り**(登録済みブックマークへのジャンプ、保存済みレイアウトでの表示、
    /// 環境設定)は通常どおり行う。書き込みを伴う操作のUI(メニュー・ツールバー・コンテキスト
    /// メニュー・サイドパネルの＋/鉛筆ボタン)は、このウインドウがフォーカス中はグレーアウトする。
    /// 各書き込み箇所のガードはこのフラグを直接参照している(grep "isPrivateWindow" /
    /// "skipsPersistence")。新しい永続化経路を足すときは、ここに列挙したうえで同じガードを入れること。
    ///
    /// ■ 「その場限りの本」も同じ扱いになる
    /// ユーザーが直接渡した画像ファイルから作った本(MangaBook.isTransient。1枚でも複数枚でも)は、
    /// **通常ウインドウで開いていても上と同じものを一切書かない**。両者をORした値が
    /// ViewerViewModel.skipsPersistence / AppState.open内のローカル変数skipsPersistenceで、
    /// 実際のガードはそちらが担う。何を書かないかの一覧はこのコメントを正典とし、
    /// なぜ書いてはいけないのかはMangaBook.BookOriginのコメントを参照。
    /// ただし**フォルダのアクセス権(FolderAccessStore)だけは例外**で、本の記録ではなく
    /// サンドボックスの権限そのものなので、どちらの場合も従来どおり付与・保存してよい。
    ///
    /// 一方、次の2つは**シークレットウインドウ固有**で、その場限りの本には適用しない
    /// (混同すると、通常ウインドウでその場限りの本を開いた瞬間に履歴が消える):
    /// - 履歴の**表示**を隠すこと(ウェルカム画面・サイドパネル・File › 最近開いたファイル)
    /// - ウインドウタイトルの「(シークレット)」表記、主ウインドウの資格判定
    ///
    /// ■ 履歴の表示
    /// 記録しないだけでなく、シークレットウインドウでは(通常ウインドウで作られた)履歴も
    /// 一切表示しない(ユーザー要望)。ウェルカム画面・サイドパネルの履歴・File › 最近開いた
    /// ファイルの3箇所が、このフラグ(メニューはMenuCheckmarkState.isPrivateWindow)を見て空にする。
    let isPrivateWindow: Bool

    /// このウインドウを「普通のウインドウ」として扱ってよいか。
    ///
    /// シークレットウインドウには、記録を残さないこととは別に、次のような**役割上の除外**が
    /// 付いてまわる。
    ///   ・主ウインドウ(位置・サイズの記憶、外部からの「開く」の受け皿)にならない
    ///   ・「同じ本が既に開かれているか」の判定から外れる(LaunchCoordinator参照)
    ///   ・Finder等の外部から渡された本の行き先候補から外れる
    /// これらはいずれも「シークレットは例外的で、普通のウインドウが別に居る」ことを前提に
    /// している。ところが環境設定「シークレットモードで起動」(ユーザー要望)をONにすると、
    /// **シークレットのほうが普通**になり、前提が逆転する。そのまま除外を適用し続けると、
    /// 外部から本を開くたびに新しいウインドウが増える・ウインドウの位置が記憶されない、
    /// といった形で破綻する。
    ///
    /// そこで、これらの除外判定はすべて`isPrivateWindow`を直接見るのではなく、このプロパティを
    /// 見るようにしてある。**記録を残すかどうかの判定(skipsPersistence、履歴の表示、
    /// ウインドウタイトルの「(シークレット)」)には使わないこと** ―― あちらは既定かどうかに
    /// 関わらず`isPrivateWindow`のままでよい(既定でも記録は残さない)。
    var actsAsRegularWindow: Bool {
        !isPrivateWindow || AppPreferences.isPrivateModeDefault
    }

    init(isPrivateWindow: Bool = false) {
        self.isPrivateWindow = isPrivateWindow
    }

    @Published var currentBook: MangaBook?
    @Published var errorMessage: String?

    /// 本を開いた直後に表示したいページ。「同じフォルダの画像をすべて開く」
    /// (openAllImagesInCurrentFolder)が、直前まで見ていた画像のページへ着地させるために使う。
    ///
    /// ページ番号ではなく`PageRef.id`(=ファイルのパス)で指定する。フォルダを読み直すと
    /// ページ数も並びも変わるため、番号では意味を持たないため。
    ///
    /// **bookIDとの組にしてある。** pageIDだけだと「どの本向けの指定なのか」が失われ、
    /// 読み込みに失敗したときや、待っている間にユーザーが別の本を開いたときに、
    /// 関係のない本へ誤爆する。フォルダの本のidはフォルダのパスなので、開く前に確定できる。
    ///
    /// 消費するのはViewerView(生成時にViewerViewModelへ渡し、onAppearでclearする)。
    /// ポーリングで待つ必要が無いので、既存のBookmarkListView.waitAndJump方式より確実。
    @Published private(set) var pendingInitialPage: PendingInitialPage?

    struct PendingInitialPage: Equatable {
        let bookID: String
        let pageID: String
    }

    /// ViewerViewが`pendingInitialPage`を受け取り終えたあと(onAppear)に呼ぶ。
    /// 一度きりの指定なので、次に同じ本を開き直したときに再適用されないようここで捨てる。
    func clearPendingInitialPage() {
        pendingInitialPage = nil
    }
    /// 現在開いている本と同じフォルダにある、他の本のURL一覧(現在の本自身は除く)。
    /// 「Fileメニュー」→「同じフォルダのファイルを開く」の一覧に使う。
    @Published private(set) var siblingBooks: [URL] = []

    /// 現在表示中のビューワー(ViewerView)へ、メニューバーからの操作を橋渡しするためのクロージャ。
    /// ViewerViewが表示されている間だけ自分自身を登録し、閉じるときにnilへ戻す。
    /// (見開き切替・ブックマーク・スライドショーなど、ツールバーにある操作をメニューバーからも
    /// 呼べるようにするためのもの。フルスクリーン時などメニューバー経由で操作したい場合に使う)
    var performViewerAction: ((ViewerAction) -> Void)?

    /// 現在開いている本のブックマーク一覧。メニューバーの「ブックマーク」メニュー下部に
    /// 一覧表示するために、ViewerViewが自分自身のViewerViewModelの内容をここへ反映する
    /// (performViewerActionと同じ、本を表示している間だけ登録する仕組み)。
    @Published private(set) var currentBookmarks: [Bookmark] = []
    /// 現在表示中のページ番号(0始まり)。currentBookmarksと突き合わせることで「現在のページが
    /// ブックマーク済みかどうか」を判定できる(ContentView.bodyでMenuCheckmarkStateを組み立てる
    /// ときに使う。currentBookmarksと同じ、ViewerViewが表示されている間だけ最新値を書き込む仕組み)。
    @Published private(set) var currentPageIndex = 0
    /// メニューバーの「ブックマーク」メニューの一覧から、特定のブックマークへジャンプするための
    /// 橋渡し。ViewerViewが表示されている間だけ自分自身を登録し、閉じるときにnilへ戻す。
    var jumpToBookmark: ((Bookmark) -> Void)?

    /// 「ブックマーク・レイアウトの編集」ウインドウ(4節)の右ペインで、ブックマークが付いて
    /// いないページのサムネイルをダブルクリックした場合に、そのページ番号へ直接ジャンプする
    /// ための橋渡し。jumpToBookmarkと同じ仕組み(ViewerViewが表示されている間だけ自分自身を
    /// 登録し、閉じるときにnilへ戻す)だが、対象がBookmarkではなくページ番号(0始まり、
    /// ViewerViewModel.currentIndexと同じ空間)である点が異なる。
    var jumpToPageIndex: ((Int) -> Void)?

    /// サイドパネル(フォルダブラウザ + 本の中身ブラウザ)が、表示メニューの「サイドパネルを
    /// 隠す」がONのときの一時的なホバー表示中かどうか。hideSidePanelがOFF(既定)のときは
    /// サイドパネルは常時表示されているため、この値は使われない(ContentView.body参照)。
    /// 永続化は不要な一時的な表示状態のためdidSetは付けない。
    @Published var isSidePanelRevealed = false

    /// サイドパネルが、ViewerViewの上に一時的に浮かぶ形(ホバー表示中)で表示されているか
    /// どうか。常時表示中(hideSidePanel == false)はパネルが専用の領域を占めているだけで
    /// 本の上には重ならないため、この値はfalseになる。ViewerViewはtrueの間だけ、背後の本の
    /// ページ送り(スクロール/スワイプ/キーボード/コンテキストクリック)を無視する
    /// (showThumbnailGridと同じ扱い。ViewerView.makeScrollMonitor/makeContextClickMonitor参照)。
    var isSidePanelFloatingOverlay: Bool { hideSidePanel && isSidePanelRevealed }

    /// ホバーで浮かせているサイドパネルの、スクリーン座標系での現在のフレーム
    /// (ContentViewがPanelScreenFrameAccessorから受け取って更新する)。
    ///
    /// ページ一覧パネルを閉じるクリックの判定が、「画像表示エリアの上のクリック」から
    /// **その上に浮いているサイドパネルへのクリック**を除くために使う
    /// (ViewerView.installThumbnailGridDismissMonitorIfNeeded参照)。浮かせている間は
    /// パネルが画像表示エリアに重なるので、座標だけではどちらへのクリックか区別できない。
    ///
    /// `@Published`にしていないのは、この値を読むのがNSEventモニタのクロージャだけで、
    /// 画面の再描画とは無関係なため(レイアウトのたびに更新されるので、@Publishedにすると
    /// 無駄な再描画を誘発する)。**`isSidePanelFloatingOverlay`がtrueのときだけ参照すること**
    /// ―― パネルを隠すと報告が止まり、この値は最後のフレームのまま古くなる。
    var sidePanelScreenFrame: CGRect = .zero

    /// ツールバー・プログレスバーの自動隠し(hideToolbar/hideProgressBar、またはフルスクリーン中)
    /// が、マウスカーソルの位置により今まさに一時的に表示されているかどうか。ViewerViewの
    /// updateAutoHiddenChromeVisibilityが更新する。ContentView側のサイドパネルのホバー検知
    /// (X座標だけを見る)と、ViewerView側のこの自動表示(Y座標だけを見る)は互いに独立した
    /// 判定のため、何も対策しないとウインドウの角(左上・左下)ではどちらも同時に成立してしまい、
    /// 「ツールバーの上を左へ移動していくとサイドパネルが表示されてツールバーが隠れる」
    /// 「サイドパネルを表示した状態で上へ移動するとツールバーまで表示される」といった
    /// 意図しない競合が起きる(ユーザー報告)。どちらか一方が先にカーソルの主導権を握って
    /// いる間は、もう一方が新たに表示されないようにするための橋渡しとして使う
    /// (ContentView.installSidePanelHoverMonitorIfNeeded参照)。
    @Published var isChromeAutoRevealed = false

    /// 自動表示中のツールバー/プログレスバーを、次のマウス移動を待たずに今すぐ隠すための橋渡し。
    /// 表示・非表示の判定(Y座標)と実際の表示状態(@State)はどちらもViewerViewが持っているため、
    /// performViewerAction等と同じく、ViewerViewが表示されている間だけ自分自身を登録する。
    ///
    /// 用途は「カーソルがウインドウの外へ出た」ときの一斉クローズ(ユーザー要望)。ViewerViewの
    /// ローカルモニタはウインドウ内のマウス移動しか見ていないため、カーソルが外へ出たまま
    /// 戻ってこない場合、自動表示されたツールバー/プログレスバーが出しっぱなしになる。
    /// ウインドウ外への移動を検知しているContentView側から、サイドパネルを閉じるのと同じ
    /// タイミングでこれを呼ぶ(ContentView.dismissAutoRevealedChromeIfCursorLeftWindow参照)。
    var hideAutoRevealedChrome: (() -> Void)?

    /// サイドパネルの下段(本の中身ブラウザ)が、ダブルクリックされた画像ファイルのパスから
    /// 「それが本の何ページ目か」を特定するために参照する、現在の本のページ一覧。
    ///
    /// MangaBookはstructであり、ViewerViewModelはinitで値渡しされた独自コピーを持つ。
    /// ページの並び替え・除外(レイアウト機能、ViewerViewModel.reloadLayoutData参照)による
    /// ライブな変更はViewerViewModel側のコピーにしか反映されず、currentBook(本を開いた
    /// 時点のコピー)には自動反映されないため、currentBook.pagesをそのまま使うと並び替え後に
    /// 誤ったページへジャンプしてしまう。そのため、currentBookmarks/currentPageIndexと同じ
    /// 「ViewerViewが自分自身のViewerViewModelの最新状態をここへ反映する」仕組みで、
    /// 別途この値を同期する(ViewerView.swiftの.onChange(of: viewModel.book.pages)参照)。
    @Published private(set) var currentBookPages: [PageRef] = []

    /// ViewerViewから、現在の本の最新のページ一覧を反映するために呼ばれる
    /// (updateCurrentBookmarksと同じ仕組み)。
    func updateCurrentBookPages(_ pages: [PageRef]) {
        currentBookPages = pages
    }

    /// ビューアに今実際に表示されているページのsortKey(単ページ表示なら1件、見開きで
    /// 2ページとも表示中なら2件、読み順)。サイドパネル下段(本の中身ブラウザ)が、
    /// 現在のページを一覧内で常にハイライト+スクロール表示し、ページ送りでフォルダ/
    /// ネストした書庫の境界をまたいだ場合は表示中のフォルダ/書庫ごと切り替えるために使う
    /// (BookContentsBrowserState.revealCurrentPage、ContentView.swiftの
    /// .onChange(of: appState.currentVisiblePageSortKeys)参照)。currentBookPagesと同じ理由で
    /// ViewerViewから同期してもらう。
    @Published private(set) var currentVisiblePageSortKeys: [String] = []

    func updateCurrentVisiblePageSortKeys(_ sortKeys: [String]) {
        currentVisiblePageSortKeys = sortKeys
    }

    /// 「ブックマークの編集」ウインドウ(独立ウインドウ。すべての本を横断するBookmarkStoreが
    /// 削除・リネームを直接SwiftDataへ行うため、そちらは経由しない)の「Add This Page」
    /// ボタンから、今読んでいるページをこの本のブックマークとして追加するための橋渡し。
    /// jumpToBookmarkと同じく、ViewerViewが表示されている間だけ自分自身を登録し、
    /// 閉じるときにnilへ戻す。
    ///
    /// 以前はここに削除・リネーム用の同様のクロージャ(removeBookmarkAction/
    /// renameBookmarkAction)もあったが、ブックマークの編集がすべての本を横断する構成になり、
    /// 「今開いている本かどうかに関わらず削除・リネームできる」必要が生じたため、
    /// BookmarkStore.delete(_:)/rename(_:to:)がSwiftDataを直接操作する形に変更し、
    /// これらは廃止した(削除・リネームされた内容は、Notification.Name.bookmarksDidChange経由で
    /// このAppStateが指すViewerViewModelにも反映される。詳細はBookmark.swift参照)。
    var addBookmarkAction: (() -> Void)?

    /// サイドパネル(ブックマークモード)の「お気に入りに追加」ボタンから、今開いている本を
    /// お気に入りへ登録するための橋渡し。登録先フォルダの選択シート
    /// (FavoriteFolderPickerView)はViewerViewが持っているため、addBookmarkActionと同じく
    /// ViewerViewが表示されている間だけ自分自身を登録し、閉じるときにnilへ戻す
    /// (=本を開いていない間はnil。呼び出し側はnilならボタンを無効化する)。
    ///
    /// ツールバー/メニューバーの「お気に入りに追加/削除」がトグル(.toggleFavorite)なのに対し、
    /// こちらは常に「追加」だけを行う(ユーザー要望: サイドパネルのボタンは追加専用)。
    /// 既に登録済みの本を追加しようとした場合の重複確認はFavoriteFolderPickerView側が行う。
    var addFavoriteAction: (() -> Void)?

    /// サイドパネル(ブックマークモード)のお気に入りツリーから本を開くための橋渡し。
    /// 環境設定「お気に入りを開くとき」(favoriteOpenBehavior: そのまま開く/新しいタブ/
    /// 新しいウインドウ)の判定はViewerView.openFavoriteAccordingToPreferenceが持っているため、
    /// addFavoriteActionと同じくViewerViewが表示されている間だけ登録される。nil(本を開いて
    /// いない)の場合、呼び出し側は代わりにopenFavorite(_:)を直接呼ぶ(開いている本が無ければ
    /// 「今の本を置き換える」以外の選択肢に意味が無いため)。
    var openFavoriteAction: ((FavoriteBook) -> Void)?

    /// サイドパネル(ページモード)が、ページのサムネイルを取得するための橋渡し。
    /// サムネイルの実体はViewerViewModelが持つPageLoader(本ごとのactor。NSCacheつき)から
    /// 得るが、サイドパネルはViewerViewの外側(ContentView)にあってViewerViewModelを直接
    /// 参照できないため、jumpToPageIndex等と同じくViewerViewが表示されている間だけ自分自身を
    /// 登録する。nil(本を開いていない)の場合、ページモードは「本を開いていません」の表示になる。
    ///
    /// 【重要】この値が変わるたびにサイドパネル側のサムネイル読み込みをやり直す必要があるため、
    /// クロージャ自体は@Publishedにできない(関数はEquatableでなく、@Publishedにしても
    /// 差し替えの検知には使えない)。代わりに、本を開くたびに増えるページモード用の世代番号
    /// (pageThumbnailGeneration)を別途@Publishedで公開し、サイドパネルはそちらを
    /// .task(id:)の識別子に混ぜることで確実に読み込み直す。
    var loadPageThumbnail: ((Int) async -> CGImage?)?

    /// サイドパネル(ページモード)の行のサムネイルにカーソルをホバーしたときの、拡大
    /// プレビュー用のフル解像度画像を取得するための橋渡し(ユーザー要望。ページ一覧グリッド・
    /// 「ブックマーク・レイアウトの編集」ウインドウと同じ拡大プレビューをここでも出すため)。
    /// loadPageThumbnailは進捗バー用の低解像度サムネイルで、そのまま拡大すると粗くなるため、
    /// プレビューにはこちら(ViewerViewModel.pageImage(at:))を使う。
    /// 登録・解除はloadPageThumbnailと同時に行われるため、世代番号も共用する。
    var loadPageImage: ((Int) async -> CGImage?)?

    /// loadPageThumbnailの登録・解除のたびに増える世代番号(上のコメント参照)。
    @Published private(set) var pageThumbnailGeneration = 0

    func updateLoadPageThumbnail(
        _ loader: ((Int) async -> CGImage?)?,
        pageImageLoader: ((Int) async -> CGImage?)? = nil
    ) {
        loadPageThumbnail = loader
        loadPageImage = pageImageLoader
        pageThumbnailGeneration &+= 1
    }

    /// ViewerViewから、現在のブックマーク一覧を反映するために呼ばれる。
    ///
    /// siblingBooksと同じ理由で、メニューバーのメニューが開いている間は保留する
    /// (この一覧はそのまま「ブックマーク一覧」メニューの項目数になり、本を開いた直後の
    /// 反映など非同期に変わりうる。詳細はMenuBarMenuGateの型コメント参照)。
    func updateCurrentBookmarks(_ bookmarks: [Bookmark]) {
        liveCurrentBookmarks = bookmarks
        MenuBarMenuGate.shared.run(menuGateKey("currentBookmarks")) { [weak self] in
            self?.currentBookmarks = bookmarks
        }
        refreshIsCurrentPageBookmarked()
    }

    /// ViewerViewから、現在のページ番号を反映するために呼ばれる(updateCurrentBookmarksと同じ仕組み)。
    ///
    /// この値だけは**保留しない**。メニューの内容には直接使わず(メニューが使うのは下の
    /// isCurrentPageBookmarked)、サイドパネルの現在ページのハイライト・自動スクロールが
    /// これを見ているため、保留するとメニューを開いている間サイドパネルが追従しなくなる。
    func updateCurrentPageIndex(_ index: Int) {
        currentPageIndex = index
        refreshIsCurrentPageBookmarked()
    }

    /// 保留を通さない、常に最新のブックマーク一覧。isCurrentPageBookmarkedの再計算にだけ使う
    /// (メニューが読むcurrentBookmarksは保留されるため、そちらを基準にすると保留中の再計算が
    /// 古い一覧を見てしまう)。
    private var liveCurrentBookmarks: [Bookmark] = []

    /// 現在のページがブックマーク済みかどうか。メニューバーの「このページをブックマークに
    /// 追加/から削除」の文言と、ツールバー・コンテキストメニューの同ボタンに使う。
    ///
    /// 以前はContentView.bodyがcurrentBookmarksとcurrentPageIndexから都度計算していたが、
    /// currentPageIndexを保留しない(上のコメント参照)以上、そのままではスライドショーの
    /// ページ送りでメニューを開いている最中に文言が変わりうる。項目数こそ変わらないものの、
    /// メニューの再構築(NSMenu setItemArray:)が走ること自体がmacOS 26でのクラッシュの条件の
    /// ため、メニューが読む値はここで保留付きの@Publishedとして持つ
    /// (詳細はMenuBarMenuGateの型コメント参照)。
    @Published private(set) var isCurrentPageBookmarked = false

    private func refreshIsCurrentPageBookmarked() {
        let flag = liveCurrentBookmarks.contains { $0.pageIndex == currentPageIndex }
        MenuBarMenuGate.shared.run(menuGateKey("isCurrentPageBookmarked")) { [weak self] in
            guard let self, self.isCurrentPageBookmarked != flag else { return }
            self.isCurrentPageBookmarked = flag
        }
    }

    /// 表示メニューの「ツールバーを隠す」。ウインドウ表示のときのみ効果があり、
    /// フルスクリーン表示中はこの設定に関わらず、フルスクリーン用の自動隠し/自動表示
    /// (マウスを画面端に近づけたときだけ表示)が優先される(ViewerView.body参照)。
    /// AppState自体はウインドウ(タブ)ごとに新しく作られる一時的なものだが、値が変わるたびに
    /// preferences(アプリ全体で共有・UserDefaultsに保存)へも書き戻すことで、次にウインドウを
    /// 開いたときや次回アプリを起動したときにも同じ設定が再現されるようにしている
    /// (初期値の引き継ぎはContentView.onAppear参照)。
    @Published var hideToolbar = false {
        didSet {
            guard oldValue != hideToolbar else { return }
            preferences?.hideToolbar = hideToolbar
        }
    }
    /// 表示メニューの「プログレスバーを隠す」。hideToolbarと同様、ウインドウ表示のときのみ
    /// 効果があり、フルスクリーン中は常にフルスクリーン用の自動隠し/自動表示が優先される。
    @Published var hideProgressBar = false {
        didSet {
            guard oldValue != hideProgressBar else { return }
            preferences?.hideProgressBar = hideProgressBar
        }
    }
    /// 表示メニューの「サイドパネルを隠す」。hideToolbar/hideProgressBarと違い、フルスクリーン
    /// 中かどうかに関わらず常に効果がある(サイドパネルはツールバー/プログレスバーと違って
    /// フルスクリーン専用の別の自動隠し挙動を持たない)。既定はOFF(=常時表示)。ONのときだけ、
    /// マウスをウインドウの端(環境設定のsidePanelPositionで選んだ左右どちらか)に近づけたときの
    /// 一時表示(isSidePanelRevealed)が意味を持つ
    /// (ContentView.installSidePanelHoverMonitorIfNeeded参照)。
    @Published var hideSidePanel = false {
        didSet {
            guard oldValue != hideSidePanel else { return }
            preferences?.hideSidePanel = hideSidePanel
        }
    }

    /// メニューバーの「スライドショー」の左にチェックマークを表示するための、
    /// 現在スライドショーが実行中かどうか。ViewerViewが自分自身のViewerViewModelの状態を
    /// ここへ反映する(currentBookmarksと同じ仕組み)。
    @Published private(set) var isSlideshowActive = false
    /// メニューバーの「Loupe」の左にチェックマークを表示するための、
    /// 現在ルーペを表示中かどうか。isSlideshowActiveと同じ仕組み。
    @Published private(set) var isLoupeActive = false
    /// メニューバーの「見開き」の左にチェックマークを表示するための、現在見開き表示かどうか。
    @Published private(set) var isSpreadMode = false
    /// メニューバーの「右から左へ」の左にチェックマークを表示するための、
    /// 現在右から左(マンガの標準的な読み方向)かどうか。「移動」メニューの各項目
    /// (次へ移動/前へ移動など)が、左右どちらの操作に対応するかもこの値を見て決める。
    @Published private(set) var isRightToLeft = false
    /// メニューバーの「表示モード切替」サブメニューで、現在のモードにチェックマークを
    /// 表示するための値。
    @Published private(set) var currentScalingMode: ScalingMode = .fitToScreen
    /// メニューバーの「コントラスト補正(この本)」の左にチェックマークを表示するための、
    /// 現在の本でこの機能がONかどうか(本単位で記憶。ViewerViewModel.isContrastCorrectionEnabled
    /// 参照)。isSlideshowActive/isLoupeActiveと同じ仕組み。
    @Published private(set) var isContrastCorrectionEnabled = false
    /// 明示的なページ単位のレイアウト指定を持つ見開きを表示中、メニューバーの
    /// 「1ページだけ送る/戻す」をグレーアウトするための値。
    /// 詳細はViewerViewModel.isPageShiftLocked参照。
    ///
    /// 以前はここに読み方向・見開き強制・レイアウト編集全体のロック
    /// (isReadingDirectionLocked / isDisplayModeLocked / hasAuthoritativeSourceLayout)も
    /// 並んでいたが、ユーザー要望により「EPUB/PDFのファイル側の指定でユーザー操作を
    /// ロックする」という扱い自体を廃止したため、いずれも削除した
    /// (LayoutStore.importSourceLayoutIfNeeded参照)。
    @Published private(set) var isPageShiftLocked = false
    /// 見開き表示中に、実際に2ページとも表示されているかどうか(横長画像の自動単ページ化等で
    /// 実際には1枚しか表示されていない場合はfalse)。Layoutメニューの中央グループの項目構成
    /// (現在のページのみか、左右2ページ分か)の切り替えに使う。
    @Published private(set) var hasPartnerPageDisplayed = false
    /// 現在のページに、既にレイアウト上書き(PageLayoutOverride)が設定されているかどうか。
    /// 「レイアウト情報を削除する」項目の表示/非表示に使う。
    @Published private(set) var hasCurrentPageLayoutOverride = false
    /// パートナーページ(見開き表示中の相方ページ)に、既にレイアウト上書きが設定されているかどうか。
    @Published private(set) var hasPartnerPageLayoutOverride = false

    /// メニューバーの「表示モード切替」サブメニューから、特定のモードへ直接切り替えるための
    /// 橋渡し。ViewerViewが表示されている間だけ自分自身を登録し、閉じるときにnilへ戻す。
    var setScalingMode: ((ScalingMode) -> Void)?

    /// メニューバーの「Layout」メニュー(設計コンセプト8.2節)、および将来同じ経路を使う
    /// コンテキストメニューから、現在表示中のビューワーへレイアウト操作を橋渡しするための
    /// クロージャ群。performViewerActionと同じ、ViewerViewが表示されている間だけ自分自身を
    /// 登録し、閉じるときにnilへ戻す仕組み。
    ///
    /// レイアウトの状態変更(単一/見開き右/見開き左/除外に設定する)は、値を書き込むだけでなく
    /// 3.3節の伝播範囲選択ダイアログを表示する必要があり、そのダイアログの@Stateはビュー階層
    /// (ViewerView)側にしか置けない。そのため、performViewerActionのように直接ViewModelの
    /// メソッドを呼ぶのではなく、いったんViewerView自身が登録したこのクロージャを経由して
    /// 「対象ページ・新しい状態」を伝え、ViewerView側でダイアログ表示までを行う。
    var performLayoutStateChange: ((LayoutMenuTarget, PageLayoutState) -> Void)?
    /// レイアウト情報を削除する(3.2節「レイアウト情報を削除する」)。伝播範囲ダイアログは
    /// 挟まないため、直接ViewModelへ反映してよい。
    var performLayoutClear: ((LayoutMenuTarget) -> Void)?
    /// 現在の表示を基準に自動でレイアウトする(3.1節)。
    var performAutoLayout: (() -> Void)?

    /// 画像のエクスポート機能(要望)。メニューバーの「画像のエクスポート」サブメニューから、
    /// 実際の画像取得・保存先パネル表示・書き込みを行うViewerView側の処理を橋渡しするための
    /// クロージャ。performViewerActionと同じ、ViewerViewが表示されている間だけ自分自身を登録し、
    /// 閉じるときにnilへ戻す仕組み(ImageExportKindのコメント参照)。
    var performImageExport: ((ImageExportKind) -> Void)?

    /// ページ番号を直接指定して1ページ分を書き出す橋渡し(ユーザー要望: サイドパネルや
    /// ページ一覧の右クリックからも「画像をエクスポート」を使えるようにしたい)。
    ///
    /// `performImageExport`との違いは、対象の決め方だけである。あちらはメニューバーから
    /// 呼ばれるためクリック位置の情報が無く、「今のページ/見開きの左/右」という
    /// 相対的な指定(ImageExportKind)しかできない。こちらは右クリックされた行そのものが
    /// 対象なので、ページ番号で一意に指定できる。実際の処理(保存先パネル・書き込み)は
    /// どちらも同じViewerView.exportImageへ行き着く。
    ///
    /// サイドパネルはViewerViewの外(ContentView)にあってViewerViewModelを直接参照
    /// できないため、loadPageThumbnail等と同じくこの橋渡しが必要になる。
    var exportPageImage: ((Int) -> Void)?

    /// ViewerViewから、スライドショー/表示モード/読み方向/拡大縮小モードの現在値、および
    /// EPUBによる各種ロック状態を反映するために呼ばれる。メニューバーのチェックマーク表示・
    /// グレーアウトに使う(currentBookmarksと同じ仕組み)。
    func updateMenuCheckmarkState(
        isSlideshowActive: Bool,
        isLoupeActive: Bool,
        displayMode: DisplayMode,
        readingDirection: ReadingDirection,
        scalingMode: ScalingMode,
        isContrastCorrectionEnabled: Bool,
        isPageShiftLocked: Bool,
        hasPartnerPageDisplayed: Bool,
        hasCurrentPageLayoutOverride: Bool,
        hasPartnerPageLayoutOverride: Bool
    ) {
        // 値が実際に変わったときだけ代入する。@Publishedは代入のたびに(同じ値であっても)
        // objectWillChangeを発火するため、無条件に代入すると1回の呼び出しで13回の変更通知が
        // 出る。しかもこのメソッドの呼び出し元(ViewerView.syncMenuCheckmarkState)は10箇所ほどの
        // .onChangeから呼ばれており、そのうちcurrentIndexとcurrentImages.countはページを1枚
        // めくるたびに両方発火する。つまり、メニュー関連の値が1つも変わっていない通常のページ
        // 送りでも、このAppStateを購読しているContentViewの再評価を何度も促していた
        // (BookmarkStore.bookSortOptionのdidSetで、表示に影響しない再計算をやめたのと同じ考え方)。
        //
        // さらに、**メニューバーのメニューが開いている間はこの反映自体を保留する**。
        // ここの値の多くはユーザーの操作と無関係に非同期で変わり(見開きのデコード完了で
        // hasPartnerPageDisplayedが、スライドショーのページ送りでhasCurrentPageLayoutOverrideが)、
        // しかもメニューの**項目数**を左右する:
        //   ・hasPartnerPageDisplayed → 「画像のエクスポート」が1項目↔3項目、Layoutメニューが
        //     左右2サブメニュー↔平坦
        //   ・has(Current|Partner)PageLayoutOverride → 「レイアウト情報を削除する」の有無で4項目↔6項目
        // 開いている最中に変わるとmacOS 26ではメニューの再構築でアプリが落ちる
        // (詳細はMenuBarMenuGateの型コメント参照)。チェックマークやグレーアウトだけを
        // 左右する値も含めてまとめて保留し、メニューを開いている間は一貫した1つの
        // スナップショットを見せる(開いたままメニューの見た目が変わる必要は無い)。
        MenuBarMenuGate.shared.run(menuGateKey("menuCheckmarkState")) { [weak self] in
            guard let self else { return }
            self.setIfChanged(&self.isSlideshowActive, isSlideshowActive)
            self.setIfChanged(&self.isLoupeActive, isLoupeActive)
            self.setIfChanged(&self.isSpreadMode, displayMode == .spread)
            self.setIfChanged(&self.isRightToLeft, readingDirection == .rightToLeft)
            self.setIfChanged(&self.currentScalingMode, scalingMode)
            self.setIfChanged(&self.isContrastCorrectionEnabled, isContrastCorrectionEnabled)
            self.setIfChanged(&self.isPageShiftLocked, isPageShiftLocked)
            self.setIfChanged(&self.hasPartnerPageDisplayed, hasPartnerPageDisplayed)
            self.setIfChanged(&self.hasCurrentPageLayoutOverride, hasCurrentPageLayoutOverride)
            self.setIfChanged(&self.hasPartnerPageLayoutOverride, hasPartnerPageLayoutOverride)
        }
    }

    /// 値が変わったときだけ代入する(@Publishedの不要な発火を避ける。
    /// updateMenuCheckmarkState/resetMenuCheckmarkStateのコメント参照)。
    private func setIfChanged<Value: Equatable>(_ storage: inout Value, _ newValue: Value) {
        guard storage != newValue else { return }
        storage = newValue
    }

    /// このAppStateを他と区別するための識別子(menuGateKey(_:)専用)。ObjectIdentifierの
    /// hashValueではなくUUIDにしてあるのは、ハッシュ値は衝突しうるうえ、解放されたインスタンスの
    /// アドレスが再利用されると別のウインドウと同じ値になりうるため。
    private let menuGateInstanceID = UUID().uuidString

    /// 保留の単位を表すキー(MenuBarMenuGate.run(_:_:)へ渡す)。AppStateはウインドウごとに
    /// 別インスタンスがあるため、インスタンスの識別子を混ぜて別ウインドウの予約と混ざらない
    /// ようにする。
    private func menuGateKey(_ name: String) -> String {
        "AppState.\(name)#\(menuGateInstanceID)"
    }

    /// siblingBooksへの唯一の書き込み口。メニューバーのメニューが開いている間は保留する。
    ///
    /// この値は「同じフォルダのファイルを開く」メニューの項目数そのもの(1項目の権限付与
    /// ボタン ↔ N項目の一覧)を決めるうえ、本を開いたあとのフォルダ走査が終わった瞬間に
    /// **ユーザーの操作と無関係に**変わる。開いている最中に変わるとmacOS 26では
    /// メニューの再構築でアプリが落ちる(詳細はMenuBarMenuGateの型コメント参照)。
    private func setSiblingBooks(_ newValue: [URL]) {
        MenuBarMenuGate.shared.run(menuGateKey("siblingBooks")) { [weak self] in
            guard let self, self.siblingBooks != newValue else { return }
            self.siblingBooks = newValue
        }
    }

    /// ViewerViewが閉じるとき(本を閉じたとき)に、メニューバーのチェックマーク状態をクリアする。
    func resetMenuCheckmarkState() {
        // updateMenuCheckmarkStateと同じ理由で、変わったものだけ代入し、メニューバーの
        // メニューが開いている間は保留する(同じキーを使うことで、保留中に更新とリセットが
        // 重なっても最後の1つだけが適用される)。
        MenuBarMenuGate.shared.run(menuGateKey("menuCheckmarkState")) { [weak self] in
            guard let self else { return }
            self.setIfChanged(&self.isSlideshowActive, false)
            self.setIfChanged(&self.isLoupeActive, false)
            self.setIfChanged(&self.isSpreadMode, false)
            self.setIfChanged(&self.isRightToLeft, false)
            self.setIfChanged(&self.currentScalingMode, .fitToScreen)
            self.setIfChanged(&self.isContrastCorrectionEnabled, false)
            self.setIfChanged(&self.isPageShiftLocked, false)
            self.setIfChanged(&self.hasPartnerPageDisplayed, false)
            self.setIfChanged(&self.hasCurrentPageLayoutOverride, false)
            self.setIfChanged(&self.hasPartnerPageLayoutOverride, false)
        }
    }

    /// performViewerAction/jumpToBookmark/addBookmarkAction/setScalingMode、および
    /// currentBookmarks・各種メニューチェックマーク状態(updateMenuCheckmarkState/
    /// resetMenuCheckmarkState)は、「今表示しているViewerViewが自分自身をappStateへ
    /// 登録する/閉じるときに取り除く」という仕組みで管理している。
    ///
    /// このAppState自体はウインドウ(タブ)ごとに1つだけ作られ、同じウインドウ内で本を
    /// 切り替える(ContentView.bodyの`ViewerView(...).id(book.id)`により、切り替えるたびに
    /// 古いViewerViewのonDisappearと新しいViewerViewのonAppearの両方が発生する)場合、
    /// この2つが同じappStateインスタンスへ書き込むため、SwiftUIが実際にどちらを先に
    /// 実行するかという保証が無い(新→旧の順で実行されると、新しい本の正しい登録が
    /// 古い本のonDisappearによる後始末で上書き消去されてしまい、メニューバーの
    /// 「お気に入りに追加」「ブックマークを追加」「ブックマークの編集」などが軒並み
    /// 反応しなくなる不具合になる。実際に本を連続して切り替えた際に発生が確認された)。
    ///
    /// この順序不定を解決するため、ViewerViewは自分自身を表す使い捨てのトークン(UUID)を
    /// onAppearのたびにここへ書き込み(activeViewerToken)、onDisappear側は「このトークンが
    /// 今も自分自身のものであるとき」だけ後始末(nilに戻す等)を行う。新しいViewerViewの
    /// onAppearが先に走っていれば、古いViewerViewのonDisappearの時点でこの値は既に
    /// 新しいトークンに書き換わっているため、後始末は行われず、新しい本の登録が
    /// 誤って消されることはない(逆に、本のウインドウ自体が閉じられて次のonAppearが
    /// 二度と来ない場合は、このトークンは古いままなので後始末は正しく実行される)。
    var activeViewerToken: UUID?

    /// NSOpenPanelの文言など、SwiftUIのView階層外で組み立てる文字列を
    /// 環境設定の「表示言語」に合わせて解決するために参照する。
    /// (QooViewerAppのonAppearで設定される。未設定の間はシステムのロケールを使う)
    weak var preferences: AppPreferences?

    /// このAppStateを表示しているNSWindow(ContentViewのWindowAccessor経由で設定される)。
    /// Finderから別の本を開こうとしたとき(環境設定「Finderから開いたとき」が「新しいタブで
    /// 開く」の場合)、新しいタブをどのウインドウに追加すればよいかを確実に特定するために使う。
    /// 以前は「その時点でのNSApp.keyWindow」を頼りにタブの追加先を決めていたが、Finderからの
    /// 「開く」イベントが届く時点ではまだ本来のウインドウがキーウインドウになっていないことが
    /// あり、無関係な(あるいはこの操作の副作用として新しく作られた)ウインドウにタブが
    /// 追加されてしまう不具合があった。本を開いているAppStateそのものが持つウインドウ参照を
    /// 直接使うことで、常に正しいウインドウへタブを追加できるようにしている。
    weak var hostWindow: NSWindow?

    /// 「最近開いたファイルを開く」メニュー用の履歴。開くのに成功するたびに記録する。
    /// (QooViewerAppのonAppearで設定される)
    weak var recentFiles: RecentFilesStore?

    /// 環境設定「アクセス権」タブで許可されたフォルダの管理。grantAccessToCurrentFolder()から
    /// 許可を追加するのに使う。(QooViewerAppのonAppearで設定される。起動時のアクセス復元自体は
    /// FolderAccessStore自身のinitで行われるため、ここではURLを追加するためだけに参照する)
    weak var folderAccess: FolderAccessStore?

    /// お気に入り(階層フォルダ + 登録した本)の管理。ツールバー・メニューバー・
    /// コンテキストメニューからの「お気に入りに追加」「お気に入りを開く」で使う。
    /// (QooViewerAppのonAppearで設定される)
    weak var favoritesStore: FavoritesStore?

    /// ブックマーク(すべての本を横断)の管理。ツールバー・メニューバー・コンテキストメニュー・
    /// キーボードショートカットの「現在のページをブックマークから削除」から、
    /// BookmarkStore.delete(_:)を直接呼ぶために使う(削除・リネームはBookmarkStoreが
    /// SwiftDataを直接操作する設計のため。ViewerViewModel.swift:467あたりのコメント参照)。
    /// favoritesStoreと同じくweakにしか保持しない。(QooViewerAppのonAppearで設定される)
    weak var bookmarkStore: BookmarkStore?

    /// ページレイアウト設定(本全体設定 + ページ単位設定)の管理。ユーザー要望: お気に入り・
    /// レイアウト・ブックマークが同一ボリューム内での移動・リネームを引き継げるようにしたい。
    /// open(url:)で本を開くたびに、favoritesStore/bookmarkStoreと合わせてreconcileBookIDIfMoved
    /// (ファイルノード識別子(iノード番号)による自動追従)を呼ぶために参照する。
    /// favoritesStore/bookmarkStoreと同じくweakにしか保持しない。(QooViewerAppのonAppearで設定される)
    weak var layoutStore: LayoutStore?

    /// 書誌メタデータの管理。layoutStore等と同じく、open(url:)で本を開くたびに
    /// reconcileBookIDIfMoved(ファイルノード識別子による自動追従)と、識別子・
    /// セキュリティスコープ付きブックマークの補完(backfillIdentifiers)を行うために参照する。
    /// 他のストアと同じくweakにしか保持しない。(QooViewerAppのonAppearで設定される)
    weak var metadataStore: BookMetadataStore?

    /// お気に入りを開こうとしたが、対応するファイル/フォルダが実際には存在しなかったときにセットする。
    /// nilでなければ、ContentViewが「見つかりません。お気に入りから削除しますか?」というアラート
    /// (OK/お気に入りから削除の2択)を表示する。削除が選ばれた場合は、ContentView側から
    /// favoritesStore.delete(_:)を呼んでもらう(AppState自身はfavoritesStoreへweakにしか
    /// アクセスできないが、delete操作自体はfavoritesStoreの責務のため、ここでは状態の保持だけ行う)。
    @Published var missingFavorite: FavoriteBook?

    /// お気に入りを開く。既存のopen(url:)をそのまま呼ぶのではなく、開く前にセキュリティスコープ
    /// 付きブックマークを解決し、実際にファイル/フォルダがまだ存在するかを確認する
    /// (要望5: 見つからない場合はmissingFavoriteをセットしてアラートを出す。実際に開く処理は
    /// open(url:)にそのまま委譲する)。
    func openFavorite(_ favorite: FavoriteBook) {
        guard let favoritesStore, let url = favoritesStore.resolvedExistingURL(for: favorite) else {
            missingFavorite = favorite
            return
        }
        open(url: url)
    }

    /// 現在進行中の読み込みタスク。開いている途中でさらに別の本を開こうとした場合、
    /// 古い方の結果でcurrentBookが上書きされてしまわないようキャンセルする。
    private var openTask: Task<Void, Never>?

    /// open(url:)でstartAccessingSecurityScopedResource()に成功したURL(していなければnil)。
    ///
    /// バグ修正(予防): 以前は`_ = url.startAccessingSecurityScopedResource()`と、開いたきり
    /// 一度も閉じていなかった。Appleのドキュメントは、対になるstopAccessingSecurityScoped
    /// Resource()を呼ばないことについて「カーネルリソースを漏らす。使い果たすと、アプリは
    /// ファイルシステム上の場所を自身のサンドボックスへ追加する能力そのものを失う」と明記して
    /// いる。同一ボリューム内の次/前の本への移動は素のfile URLなのでstartAccessing…がfalseを
    /// 返し何も消費しないが、お気に入り・履歴から開いた場合はブックマークから解決した
    /// セキュリティスコープ付きURLなので、開くたびに1つずつ確実に積み上がっていた。
    ///
    /// このウインドウが表示している本は常に1冊なので、次の本を開くとき・本を閉じるとき・
    /// このAppState自体が解放されるときに、直前の本のぶんを1回だけ閉じる。
    /// (BookLayoutEditorViewModel.deinitと同じく、閉じてもPageLoaderが既に開いている
    /// ファイルハンドルは無効にならないため、前の本の読み込みが残っていても影響しない。)
    ///
    /// 1冊がファイル1つとは限らない(Finderで複数選択された画像から組み立てた本)ため配列で持つ。
    /// **成功したものだけ**を入れること。falseが返ったURLは何も消費していないので、閉じる対象にも
    /// ならない(素のfile URLでは常にfalseになるため、通常この配列は空のままになる)。
    private var securityScopedBookURLs: [URL] = []

    deinit {
        securityScopedBookURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    /// NSOpenPanelでフォルダ、またはzip/rar/7z/pdfファイルを選ばせる
    func openWithPanel() {
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        // 画像は複数選択して1冊としてまとめて開ける(ユーザー要望)。画像以外を複数選んだ場合は
        // 従来どおり先頭の1つだけを開く(判定はBookOpenRequestに集約)。
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Open", locale: locale)
        panel.message = String(
            // 画像ファイルも開けるようになったため文面を更新。画像は複数選択して1冊にまとめられる
            // (BookOpenRequest.init(openingCandidates:)参照)。
            localized: "Choose a manga folder, or a zip/cbz, rar/cbr, 7z/cb7, PDF, EPUB, or image file. Select multiple images to open them together as one book.",
            locale: locale
        )
        guard panel.runModal() == .OK else { return }
        open(urls: panel.urls)
    }

    /// URLが1つ分かっている状態からの読み込み(次の本/前の本への移動、お気に入り・履歴からの
    /// 復元、Fileメニューからの選択など)。実体はopen(request:)。
    func open(url: URL) {
        open(request: BookOpenRequest(url))
    }

    /// Finder / Dock / ドラッグ&ドロップ / NSOpenPanel から複数のURLが渡された場合の入口。
    /// 分類(全部画像なら1冊にまとめる / それ以外は先頭だけ)はBookOpenRequestが1箇所で行う。
    func open(urls: [URL]) {
        guard let request = BookOpenRequest(openingCandidates: urls) else { return }
        open(request: request)
    }

    /// ドラッグ&ドロップやFinderからの「開く」、次の本/前の本への移動、Fileメニューからの選択など、
    /// 開く対象が分かっている状態からの読み込みはすべてここを通る。
    ///
    /// フォルダの再帰スキャンやアーカイブの展開は時間がかかることがあるため、
    /// BookLoader.load自体がメインスレッド外で実行される(BookLoader.swiftのコメント参照)。
    /// このメソッド自体は同期のままにして呼び出し側(メニューのボタンアクションなど)を
    /// 変更せずに済むようにしつつ、内部でTaskを使って非同期の読み込みを待つ。
    func open(request: BookOpenRequest) {
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        // セキュリティスコープを実際に開き始める**前**に上限で頭を押さえる
        // (BookOpenRequest.exceedsImageSelectionLimitのコメント参照)。
        guard !request.exceedsImageSelectionLimit else {
            errorMessage = String(
                localized: "Too many images were selected. You can open up to \(BookOpenRequest.maxImageSelectionCount) images at once.",
                locale: locale
            )
            return
        }
        openTask?.cancel()
        // 先に新しい本のぶんを開いてから、直前の本のぶんを閉じる(securityScopedBookURLsの
        // コメント参照)。この順序なのは、同じ本をもう一度開いた場合に、閉じる→開くの順だと
        // アクセスが一瞬途切れてしまうため(startAccessingSecurityScopedResourceは参照
        // カウント式なので、先に開いておけばカウントが0になる瞬間が生じない)。
        let newlyAccessedURLs = request.urls.filter { $0.startAccessingSecurityScopedResource() }
        securityScopedBookURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        securityScopedBookURLs = newlyAccessedURLs
        // シークレットウインドウではページ一覧のディスクキャッシュも書かない
        // (isPrivateWindowのコメント参照)。画像ファイルを直接開く場合も同じで、こちらは
        // 本が出来上がる前からその場限りの本になると分かっている(BookOpenRequest.opensImageFiles)。
        //
        // この値はTaskの**外で**取り出しておくこと。中で`!isPrivateWindow`と書くと、
        // `[weak self]`があっても暗黙のselfとして**強参照でも**捕捉され、下の
        // `guard let self`まで弱参照にした意味が無くなる(BookLoader.loadは書庫の全走査を
        // 伴い、未接続の外付け/ネットワークボリューム上の本では長く待つ。その間ずっと
        // このAppStateが解放できなくなる)。Swift 6言語モードではエラーにもなる。
        let cachesPageList = !isPrivateWindow && !request.opensImageFiles

        openTask = Task { [weak self] in
            do {
                let book: MangaBook
                if request.bundlesMultipleImages {
                    // その場限りの本。ページ一覧のキャッシュは意味を持たないためそもそも引数が無い
                    // (BookLoader.load(imageFiles:)のコメント参照)。
                    book = try await BookLoader.load(imageFiles: request.urls)
                } else if let url = request.primaryURL {
                    book = try await BookLoader.load(from: url, cachesPageList: cachesPageList)
                } else {
                    throw BookLoaderError.notFound
                }
                guard !Task.isCancelled, let self else { return }
                // この本についてDBへ一切書かないかどうか。シークレットウインドウに加えて、
                // **その場限りの本**(直接渡された画像から作った本)も同じ扱いにする。
                // 複数枚をまとめた本のbookIDは実在パスではないため、下のreconcileBookIDIfMovedを
                // 通すと、iノードが一致した既存のお気に入り/レイアウト/ブックマークのbookIDが
                // その場限りのIDへ恒久的に書き換わり、復旧不能になる
                // (詳細はMangaBook.BookOriginのコメント参照)。
                let skipsPersistence = self.isPrivateWindow || book.isTransient
                // ユーザー要望: お気に入り・レイアウト・ブックマークが、同一ボリューム内での
                // ファイルの移動・リネームを引き継げるようにしたい。この本を開くたびに、現在の
                // bookID(パス)でまだ見つからない登録済みデータがあれば、ファイルノード識別子
                // (iノード番号)を手がかりに自動的に追従(bookIDを書き換え)させておく。本を
                // 表示する前(currentBookを設定する前)に行うことで、ViewerViewModelの初期化時点
                // では既に正しいbookIDでレイアウト/ブックマークが見つかる状態にしておく。
                // シークレットウインドウでは、追従(bookIDの書き換え)も識別子の補完も既存行への
                // 書き込みなので行わない(isPrivateWindowのコメント参照)。
                if !skipsPersistence {
                    self.favoritesStore?.reconcileBookIDIfMoved(book: book)
                    self.layoutStore?.reconcileBookIDIfMoved(book: book)
                    self.bookmarkStore?.reconcileBookIDIfMoved(book: book)
                    self.metadataStore?.reconcileBookIDIfMoved(book: book)
                }
                // メタデータを登録した時点ではこの本を開いていない(「メタデータの編集」
                // ウインドウはファイルを開かない)ことが多く、その場合はセキュリティスコープ付き
                // ブックマークもファイルノード識別子も持てていない。実際に本を開けた今なら
                // どちらも取得できるため、ここで補完しておく(EPUB/PDF出力が、今開いていない
                // 本の実ファイルへ到達するために必要)。
                if !skipsPersistence {
                    self.metadataStore?.backfillIdentifiers(forBookID: book.id, sourceURL: book.sourceURL)
                }
                self.currentBook = book
                self.errorMessage = nil
                // 別の本向けだった指定(読み込み中にユーザーが他の本を開いた等)は捨てる。
                if self.pendingInitialPage?.bookID != book.id {
                    self.pendingInitialPage = nil
                }
                // シークレットウインドウで開いた本は「最近開いたファイル」に残さない(ユーザー要望)。
                // その場限りの本も、そもそも1つのURLでは開き直せないため記録しない。
                if !skipsPersistence, let url = request.primaryURL {
                    self.recentFiles?.record(url: url)
                }
                await self.refreshSiblingBooks()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.currentBook = nil
                self.setSiblingBooks([])
                self.pendingInitialPage = nil
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "The book could not be opened.", locale: locale)
            }
        }
    }

    /// 同じフォルダ内の次の本へシームレスに移動する
    func openSibling(after currentURL: URL) {
        Task { [weak self] in
            guard let next = await SiblingFinder.url(after: currentURL) else { return }
            self?.open(url: next)
        }
    }

    /// 同じフォルダ内の前の本へシームレスに移動する
    func openSibling(before currentURL: URL) {
        Task { [weak self] in
            guard let previous = await SiblingFinder.url(before: currentURL) else { return }
            self?.open(url: previous)
        }
    }

    func closeBook() {
        openTask?.cancel()
        currentBook = nil
        setSiblingBooks([])
        // 開いていた本のセキュリティスコープ付きアクセスを閉じる(securityScopedBookURLsの
        // コメント参照)。
        securityScopedBookURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        securityScopedBookURLs = []
    }

    /// 現在の本と同じフォルダにある他の本のURL一覧を取得し直す(「同じフォルダのファイルを開く」用)。
    private func refreshSiblingBooks() async {
        guard let currentURL = currentBook?.sourceURL else {
            setSiblingBooks([])
            return
        }
        let all = await SiblingFinder.siblingBookURLsAsync(of: currentURL)
        setSiblingBooks(all.filter { $0.path != currentURL.path })
    }

    /// 今表示している画像と同じフォルダにある画像を、すべてまとめて1冊のフォルダの本として
    /// 開き直す(ユーザー要望)。
    ///
    /// ■ なぜこの操作があるのか
    /// 画像を直接開いた本は「その場限りの本」で、読書位置もレイアウトも記録されない
    /// (MangaBook.BookOrigin.imageFiles参照)。この操作は、そこから**普通のフォルダの本**
    /// (idが実在パスで、読書位置もお気に入りもブックマークも使える)へ移るための唯一の導線。
    /// 逆に言えば、画像のドロップ側を単純なまま(=同じフォルダへ勝手に展開しない)に保てるのは、
    /// この明示的な逃げ道があるからでもある。
    ///
    /// ■ 起点は「本のsourceURL」ではなく「今表示しているページ」
    /// 複数枚の画像は複数のフォルダにまたがっていることがあり、本のsourceURLはその先頭1枚でしか
    /// ない。今見ているページのフォルダを開くほうが、ユーザーの意図に一致する。
    ///
    /// ■ アクセス権
    /// サンドボックスでは、画像を直接渡されてもその1枚ぶんの権限しか無く、親フォルダの列挙は
    /// できない。権限が無いまま開くとBookLoader.loadFolderが1枚も見つけられずnoPages
    /// (=「対応する画像が見つかりません」)になり、原因が分からないエラーになってしまうため、
    /// **開く前に**許可を確認し、無ければパネルを出す。キャンセルされたら何もしない。
    func openAllImagesInCurrentFolder() {
        guard let pageURL = currentPageFileURL else { return }
        let folderURL = pageURL.deletingLastPathComponent()
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        let accessMessage = String(
            localized: "To open all images in this folder, please select and grant access to this folder.",
            locale: locale
        )
        guard ensureAccess(toFolder: folderURL, message: accessMessage) else { return }
        // フォルダの本のidはフォルダのパスそのもの(BookLoader.loadFolder)なので、
        // 開く前にpendingInitialPageの宛先を確定できる。
        pendingInitialPage = PendingInitialPage(bookID: folderURL.path, pageID: pageURL.path)
        open(url: folderURL)
    }

    /// 今表示しているページの実ファイルURL(そのページがフォルダ内の独立した画像の場合のみ)。
    private var currentPageFileURL: URL? {
        guard currentBookPages.indices.contains(currentPageIndex) else { return nil }
        guard case .file(let url) = currentBookPages[currentPageIndex].source else { return nil }
        return url
    }

    /// 指定フォルダを列挙できる状態を確保する。既に許可済み(またはその祖先が許可済み)なら
    /// パネルを出さずにtrueを返す。
    ///
    /// 許可は環境設定の「アクセス権」タブと同じ仕組み(FolderAccessStore)へ追加するので、
    /// ここで許可したフォルダも一箇所で確認・取り消しができる。セキュリティスコープ付き
    /// ブックマークとして保存されるため次回起動以降も有効。
    /// アクセスの開閉はFolderAccessStoreが一手に管理するため、**自前でstartAccessing…しないこと**
    /// (以前それをやって対になるstopが漏れていた。FolderAccessStore.accessedURLsByPathのコメント参照)。
    ///
    /// - Parameter message: パネルに出す説明文。呼び出し元によって目的が違うため受け取る。
    /// - Returns: 許可が得られたらtrue。ユーザーがパネルをキャンセルしたらfalse。
    private func ensureAccess(toFolder folderURL: URL, message: String) -> Bool {
        if let folderAccess, folderAccess.isPathCovered(folderURL) { return true }

        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        panel.prompt = String(localized: "Grant Access", locale: locale)
        panel.message = message
        guard panel.runModal() == .OK, let grantedURL = panel.url else { return false }
        _ = folderAccess?.add(url: grantedURL)
        // ユーザーが親フォルダなど別の場所を選んだ場合でも、目的のフォルダが配下に入っていれば
        // 列挙できる。入っていなければこの後の読み込みが素直にエラーになる。
        return folderAccess?.isPathCovered(folderURL) ?? false
    }

    /// 「同じフォルダのファイルを開く」が常に空になってしまう場合の対処。
    ///
    /// サンドボックス環境では、パネルでファイル単体(zip/cbz等)を直接選んで開いた場合、
    /// そのファイル自体にしかアクセス許可がなく、同じ階層にある他のファイルを一覧しようとしても
    /// 権限がないため常に0件になってしまう(フォルダを開いた場合は配下ごと許可されるため
    /// 問題にならない)。この操作は、現在の本の親フォルダを選ぶフォルダ選択パネルを表示し、
    /// ユーザーに明示的にフォルダへのアクセスを許可してもらうことで、以後
    /// 「同じフォルダのファイルを開く」が正しく機能するようにする。
    /// (許可はセキュリティスコープ付きブックマークとして保存されるため、次回以降も有効)
    func grantAccessToCurrentFolder() {
        guard let currentURL = currentBook?.sourceURL else { return }
        let parent = currentURL.deletingLastPathComponent()

        // 既に許可済みならensureAccessがパネルを出さずにtrueを返す。通常その状態なら
        // 「同じフォルダのファイルを開く」に一覧が出ておりこのメソッド自体が呼ばれないはずだが、
        // 念のため一覧を取り直しておく(保険)。
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        let accessMessage = String(
            localized: "To show files in the same folder, please select and grant access to this folder.",
            locale: locale
        )
        guard ensureAccess(toFolder: parent, message: accessMessage) else { return }

        Task { [weak self] in
            await self?.refreshSiblingBooks()
        }
    }

    /// 現在の本(ファイルまたはフォルダ)をFinderで開く(ユーザー要望)。ファイルメニュー・
    /// コンテキストメニューの両方から呼ばれる共通の実装。
    ///
    /// フォルダの本は、中身(画像ファイル一覧)を確認できるようフォルダ自体をFinderで開く。
    /// 一方アーカイブ・PDF・EPUBなどファイルの本は、Finderで「開く」と既定のアプリ
    /// (このアプリ自身やアーカイブユーティリティ等)が起動されてしまい、Finderでその場所を
    /// 確認したいという目的には合わない。そのため、ファイルの場合は親フォルダをFinderで開いた
    /// うえでそのファイル自体を選択状態にする(NSWorkspace.activateFileViewerSelectingの
    /// 標準的な「Finderで表示」の挙動。Xcode・Preview等、他の多くのMacアプリの「Finderで表示」
    /// メニュー項目と同じ動作)。
    func revealCurrentBookInFinder() {
        guard let url = currentBook?.sourceURL else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// qooViewerは「新しいウインドウで開く」「新しいタブで開く」により複数ウインドウ/タブを開けるため、
/// ウインドウごとに独立したAppStateを持つ(ContentViewが自身の@StateObjectとして生成する)。
/// 一方でメニューバーはアプリ全体で1つしかないため、「Open…」や「Viewer」メニューの各操作は、
/// 常に「今アクティブな(キーウインドウの)AppState」を参照する必要がある。
/// ContentViewが`.focusedSceneValue(\.qooViewerAppState, appState)`で自分自身のAppStateを
/// 公開し、QooViewerAppの`.commands`側は`@FocusedValue(\.qooViewerAppState)`でそれを読み取る。
private struct AppStateFocusedValueKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var qooViewerAppState: AppState? {
        get { self[AppStateFocusedValueKey.self] }
        set { self[AppStateFocusedValueKey.self] = newValue }
    }
}

/// メニューバーのチェックマーク表示(「ツールバーを隠す」「見開き」「右から左へ」など)専用に、
/// 現在値だけをまとめた値型(Equatableな構造体)。
///
/// 当初はAppState(クラス、つまり参照型)をqooViewerAppStateとして公開し、そこから
/// `focusedAppState?.hideToolbar`のように読み取ってToggleのisOnに使っていたが、実機で
/// 確認したところチェックマークが一切更新されない不具合が起きた。考えられる原因は、
/// SwiftUIの@FocusedValueは「値そのもの」が変わったかどうかで再描画の要否を判断しており、
/// クラス参照は中のプロパティ(hideToolbarなど)が変化しても参照自体(オブジェクトの
/// アイデンティティ)は変わらないため、変化が検知されずメニュー項目の見た目(チェックマーク)が
/// 更新されないというもの。
/// (一方でhasBookによる項目の有効/無効切り替えは、ファイルを開くパネルを閉じる操作自体が
/// ウインドウのフォーカス移動を伴うため、たまたまそのタイミングで再同期がかかり、問題が
/// 表面化していなかったと考えられる。メニューのトグル操作自体はウインドウのフォーカスを
/// 一切動かさないため、この問題がそのまま表に出ていた)
///
/// この構造体のように値型(Equatable)として公開すれば、値そのものが変わるたびに
/// SwiftUIが正しく変化を検知できるはずなので、チェックマークに関わる値はすべてここに
/// まとめて値型として公開する。書き込み(実際にトグルする操作)は、これまでどおり
/// qooViewerAppState(AppState)側のクロージャ/プロパティ経由で行う。
struct MenuCheckmarkState: Equatable {
    /// フォーカス中のウインドウがシークレットウインドウかどうか(AppState.isPrivateWindow)。
    /// メニューバー側で、書き込みを伴う項目(お気に入り/ブックマーク/レイアウト/メタデータの
    /// 編集)のグレーアウトと、「最近開いたファイル」を空にする判定に使う。ウェルカム画面の
    /// ウインドウでも値が必要なので、ViewerViewではなくContentViewが常に詰める。
    var isPrivateWindow = false
    /// フォーカス中のウインドウが「その場限りの本」(MangaBook.isTransient)を表示しているかどうか。
    /// 書き込みを伴う項目のグレーアウトにはisPrivateWindowとORして使う。
    /// **「最近開いたファイル」を空にする判定には使わない** — その場限りの本を開いていても
    /// 履歴そのものは通常どおり見せる(AppState.isPrivateWindowのコメント参照)。
    ///
    /// 書き込み系のグレーアウトに加えて、Fileメニューの「このフォルダの画像をすべて開く」の
    /// 有効/無効にも使う(その本が画像を直接開いた本のときだけ意味のある操作のため。
    /// AppState.openAllImagesInCurrentFolder参照)。
    var isTransientBook = false
    var hideToolbar = false
    var hideProgressBar = false
    var hideSidePanel = false
    var isSlideshowActive = false
    var isLoupeActive = false
    var isSpreadMode = false
    var isRightToLeft = false
    var scalingMode: ScalingMode = .fitToScreen
    /// 現在の本で、古いスキャン本を白黒補正して表示する機能(ユーザー要望、本単位で記憶)が
    /// ONかどうか。
    var isContrastCorrectionEnabled = false
    /// 明示的なレイアウト指定を持つ見開きを表示中trueになり、メニューバーの
    /// 「1ページだけ送る/戻す」をグレーアウトする(詳細はViewerViewModelの同名プロパティ参照)。
    var isPageShiftLocked = false
    /// メニューバーの「お気に入り」メニュー(お気に入りに追加/削除トグルボタン)、および
    /// ツールバー・コンテキストメニューの同ボタンの見た目・文言切り替えに使う、現在の本が
    /// お気に入りに登録済みかどうか。ContentView.bodyがfavoritesStore(EnvironmentObject)と
    /// appState.currentBookから都度計算して詰める(favoritesStoreの変更自体はAppStateの
    /// @Publishedプロパティではないため、ContentView側で計算する必要がある)。
    var isCurrentBookFavorited = false
    /// 同じく、現在のページがブックマーク済みかどうか(ブックマーク追加/削除トグルボタン用)。
    var isCurrentPageBookmarked = false
    /// 見開き表示中に、実際に2ページとも表示されているかどうか。Layoutメニューの項目構成
    /// (現在のページのみか、左右2ページ分か)の切り替えに使う。
    var hasPartnerPageDisplayed = false
    /// 現在のページに既にレイアウト上書きが設定されているかどうか
    /// (「レイアウト情報を削除する」項目の表示/非表示に使う)。
    var hasCurrentPageLayoutOverride = false
    /// パートナーページに既にレイアウト上書きが設定されているかどうか。
    var hasPartnerPageLayoutOverride = false
}

/// メニューバーのLayoutメニュー(8.2節)で、見開き表示中に左右どちらのページを対象にする
/// 操作かを表す。単一ページ表示中は常に.currentのみを使う。
enum LayoutMenuTarget {
    case current
    case partner
}

private struct MenuCheckmarkStateFocusedValueKey: FocusedValueKey {
    typealias Value = MenuCheckmarkState
}

extension FocusedValues {
    var qooViewerMenuCheckmarkState: MenuCheckmarkState? {
        get { self[MenuCheckmarkStateFocusedValueKey.self] }
        set { self[MenuCheckmarkStateFocusedValueKey.self] = newValue }
    }
}
