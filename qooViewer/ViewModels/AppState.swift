import Foundation
import AppKit
import Combine
import SwiftUI
import SwiftData

/// アプリ全体で「今どの本を開いているか」を管理する。
/// 本棚は持たず、パネル選択・ドラッグ&ドロップ・Finderからの「開く」だけで本を開く。
@MainActor
final class AppState: ObservableObject {
    @Published var currentBook: MangaBook?
    @Published var errorMessage: String?
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
    func updateCurrentBookmarks(_ bookmarks: [Bookmark]) {
        currentBookmarks = bookmarks
    }

    /// ViewerViewから、現在のページ番号を反映するために呼ばれる(updateCurrentBookmarksと同じ仕組み)。
    func updateCurrentPageIndex(_ index: Int) {
        currentPageIndex = index
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
        setIfChanged(&self.isSlideshowActive, isSlideshowActive)
        setIfChanged(&self.isLoupeActive, isLoupeActive)
        setIfChanged(&self.isSpreadMode, displayMode == .spread)
        setIfChanged(&self.isRightToLeft, readingDirection == .rightToLeft)
        setIfChanged(&self.currentScalingMode, scalingMode)
        setIfChanged(&self.isContrastCorrectionEnabled, isContrastCorrectionEnabled)
        setIfChanged(&self.isPageShiftLocked, isPageShiftLocked)
        setIfChanged(&self.hasPartnerPageDisplayed, hasPartnerPageDisplayed)
        setIfChanged(&self.hasCurrentPageLayoutOverride, hasCurrentPageLayoutOverride)
        setIfChanged(&self.hasPartnerPageLayoutOverride, hasPartnerPageLayoutOverride)
    }

    /// 値が変わったときだけ代入する(@Publishedの不要な発火を避ける。
    /// updateMenuCheckmarkState/resetMenuCheckmarkStateのコメント参照)。
    private func setIfChanged<Value: Equatable>(_ storage: inout Value, _ newValue: Value) {
        guard storage != newValue else { return }
        storage = newValue
    }

    /// ViewerViewが閉じるとき(本を閉じたとき)に、メニューバーのチェックマーク状態をクリアする。
    func resetMenuCheckmarkState() {
        // updateMenuCheckmarkStateと同じ理由で、変わったものだけ代入する。
        setIfChanged(&isSlideshowActive, false)
        setIfChanged(&isLoupeActive, false)
        setIfChanged(&isSpreadMode, false)
        setIfChanged(&isRightToLeft, false)
        setIfChanged(&currentScalingMode, .fitToScreen)
        setIfChanged(&isContrastCorrectionEnabled, false)
        setIfChanged(&isPageShiftLocked, false)
        setIfChanged(&hasPartnerPageDisplayed, false)
        setIfChanged(&hasCurrentPageLayoutOverride, false)
        setIfChanged(&hasPartnerPageLayoutOverride, false)
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
    private var securityScopedBookURL: URL?

    deinit {
        securityScopedBookURL?.stopAccessingSecurityScopedResource()
    }

    /// NSOpenPanelでフォルダ、またはzip/rar/7z/pdfファイルを選ばせる
    func openWithPanel() {
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open", locale: locale)
        panel.message = String(
            localized: "Choose a manga folder, or a zip/cbz, rar/cbr, 7z/cb7, PDF, or EPUB file.",
            locale: locale
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    /// ドラッグ&ドロップやFinderからの「開く」、次の本/前の本への移動、Fileメニューからの選択など、
    /// URLが分かっている状態からの読み込みはすべてここを通る。
    ///
    /// フォルダの再帰スキャンやアーカイブの展開は時間がかかることがあるため、
    /// BookLoader.load自体がメインスレッド外で実行される(BookLoader.swiftのコメント参照)。
    /// このメソッド自体は同期のままにして呼び出し側(メニューのボタンアクションなど)を
    /// 変更せずに済むようにしつつ、内部でTaskを使って非同期の読み込みを待つ。
    func open(url: URL) {
        openTask?.cancel()
        // 先に新しい本のぶんを開いてから、直前の本のぶんを閉じる(securityScopedBookURLの
        // コメント参照)。この順序なのは、同じ本をもう一度開いた場合に、閉じる→開くの順だと
        // アクセスが一瞬途切れてしまうため(startAccessingSecurityScopedResourceは参照
        // カウント式なので、先に開いておけばカウントが0になる瞬間が生じない)。
        let didAccess = url.startAccessingSecurityScopedResource()
        securityScopedBookURL?.stopAccessingSecurityScopedResource()
        securityScopedBookURL = didAccess ? url : nil
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent

        openTask = Task { [weak self] in
            do {
                let book = try await BookLoader.load(from: url)
                guard !Task.isCancelled, let self else { return }
                // ユーザー要望: お気に入り・レイアウト・ブックマークが、同一ボリューム内での
                // ファイルの移動・リネームを引き継げるようにしたい。この本を開くたびに、現在の
                // bookID(パス)でまだ見つからない登録済みデータがあれば、ファイルノード識別子
                // (iノード番号)を手がかりに自動的に追従(bookIDを書き換え)させておく。本を
                // 表示する前(currentBookを設定する前)に行うことで、ViewerViewModelの初期化時点
                // では既に正しいbookIDでレイアウト/ブックマークが見つかる状態にしておく。
                self.favoritesStore?.reconcileBookIDIfMoved(book: book)
                self.layoutStore?.reconcileBookIDIfMoved(book: book)
                self.bookmarkStore?.reconcileBookIDIfMoved(book: book)
                self.metadataStore?.reconcileBookIDIfMoved(book: book)
                // メタデータを登録した時点ではこの本を開いていない(「メタデータの編集」
                // ウインドウはファイルを開かない)ことが多く、その場合はセキュリティスコープ付き
                // ブックマークもファイルノード識別子も持てていない。実際に本を開けた今なら
                // どちらも取得できるため、ここで補完しておく(EPUB/PDF出力が、今開いていない
                // 本の実ファイルへ到達するために必要)。
                self.metadataStore?.backfillIdentifiers(forBookID: book.id, sourceURL: book.sourceURL)
                self.currentBook = book
                self.errorMessage = nil
                self.recentFiles?.record(url: url)
                await self.refreshSiblingBooks()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.currentBook = nil
                self.siblingBooks = []
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
        siblingBooks = []
        // 開いていた本のセキュリティスコープ付きアクセスを閉じる(securityScopedBookURLの
        // コメント参照)。
        securityScopedBookURL?.stopAccessingSecurityScopedResource()
        securityScopedBookURL = nil
    }

    /// 現在の本と同じフォルダにある他の本のURL一覧を取得し直す(「同じフォルダのファイルを開く」用)。
    private func refreshSiblingBooks() async {
        guard let currentURL = currentBook?.sourceURL else {
            siblingBooks = []
            return
        }
        let all = await SiblingFinder.siblingBookURLsAsync(of: currentURL)
        siblingBooks = all.filter { $0.path != currentURL.path }
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

        // 既にこのフォルダ(またはその祖先)がアクセス許可済みなら、パネルを出す必要はない
        // (macOSのサンドボックスでは、フォルダへの許可はその配下すべてに及ぶため)。
        // 通常はこの状態なら「同じフォルダのファイルを開く」に一覧が表示されており、
        // このメソッド自体が呼ばれることはないはずだが、念のための保険として用意している。
        if let folderAccess, folderAccess.isPathCovered(parent) {
            Task { [weak self] in
                await self?.refreshSiblingBooks()
            }
            return
        }

        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parent
        panel.prompt = String(localized: "Grant Access", locale: locale)
        panel.message = String(
            localized: "To show files in the same folder, please select and grant access to this folder.",
            locale: locale
        )
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        _ = folderURL.startAccessingSecurityScopedResource()
        // 環境設定の「アクセス権」タブと同じ仕組み(FolderAccessStore)に許可を追加する。
        // こうしておくと、ここで許可したフォルダも「アクセス権」タブの一覧に表示され、
        // 一箇所で管理・取り消しができるようになる。
        folderAccess?.add(url: folderURL)

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
