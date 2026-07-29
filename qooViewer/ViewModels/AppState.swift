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

    /// 「ブックマークの編集」ウインドウ(独立ウインドウ。すべての本を横断するBookmarkStoreが
    /// 削除・リネームを直接SwiftDataへ行うため、そちらは経由しない)の「Add Current Page」
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

    /// メニューバーの「スライドショー」の左にチェックマークを表示するための、
    /// 現在スライドショーが実行中かどうか。ViewerViewが自分自身のViewerViewModelの状態を
    /// ここへ反映する(currentBookmarksと同じ仕組み)。
    @Published private(set) var isSlideshowActive = false
    /// メニューバーの「見開き」の左にチェックマークを表示するための、現在見開き表示かどうか。
    @Published private(set) var isSpreadMode = false
    /// メニューバーの「右から左へ」の左にチェックマークを表示するための、
    /// 現在右から左(マンガの標準的な読み方向)かどうか。「移動」メニューの各項目
    /// (次へ移動/前へ移動など)が、左右どちらの操作に対応するかもこの値を見て決める。
    @Published private(set) var isRightToLeft = false
    /// メニューバーの「表示モード切替」サブメニューで、現在のモードにチェックマークを
    /// 表示するための値。
    @Published private(set) var currentScalingMode: ScalingMode = .fitToScreen
    /// EPUBが読み方向/見開きを明示している間、メニューバーの該当項目をグレーアウトするための値。
    /// 詳細はViewerViewModel.isReadingDirectionLocked/isDisplayModeLocked/isPageShiftLocked参照。
    @Published private(set) var isReadingDirectionLocked = false
    @Published private(set) var isDisplayModeLocked = false
    @Published private(set) var isPageShiftLocked = false

    /// メニューバーの「表示モード切替」サブメニューから、特定のモードへ直接切り替えるための
    /// 橋渡し。ViewerViewが表示されている間だけ自分自身を登録し、閉じるときにnilへ戻す。
    var setScalingMode: ((ScalingMode) -> Void)?

    /// ViewerViewから、スライドショー/表示モード/読み方向/拡大縮小モードの現在値、および
    /// EPUBによる各種ロック状態を反映するために呼ばれる。メニューバーのチェックマーク表示・
    /// グレーアウトに使う(currentBookmarksと同じ仕組み)。
    func updateMenuCheckmarkState(
        isSlideshowActive: Bool,
        displayMode: DisplayMode,
        readingDirection: ReadingDirection,
        scalingMode: ScalingMode,
        isReadingDirectionLocked: Bool,
        isDisplayModeLocked: Bool,
        isPageShiftLocked: Bool
    ) {
        self.isSlideshowActive = isSlideshowActive
        self.isSpreadMode = displayMode == .spread
        self.isRightToLeft = readingDirection == .rightToLeft
        self.currentScalingMode = scalingMode
        self.isReadingDirectionLocked = isReadingDirectionLocked
        self.isDisplayModeLocked = isDisplayModeLocked
        self.isPageShiftLocked = isPageShiftLocked
    }

    /// ViewerViewが閉じるとき(本を閉じたとき)に、メニューバーのチェックマーク状態をクリアする。
    func resetMenuCheckmarkState() {
        isSlideshowActive = false
        isSpreadMode = false
        isRightToLeft = false
        currentScalingMode = .fitToScreen
        isReadingDirectionLocked = false
        isDisplayModeLocked = false
        isPageShiftLocked = false
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
        _ = url.startAccessingSecurityScopedResource()
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent

        openTask = Task { [weak self] in
            do {
                let book = try await BookLoader.load(from: url)
                guard !Task.isCancelled, let self else { return }
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
    var isSlideshowActive = false
    var isSpreadMode = false
    var isRightToLeft = false
    var scalingMode: ScalingMode = .fitToScreen
    /// EPUBが読み方向/見開きを明示している間trueになり、メニューバーの該当項目を
    /// グレーアウトする(詳細はViewerViewModelの同名プロパティ参照)。
    var isReadingDirectionLocked = false
    var isDisplayModeLocked = false
    var isPageShiftLocked = false
    /// メニューバーの「お気に入り」メニュー(お気に入りに追加/削除トグルボタン)、および
    /// ツールバー・コンテキストメニューの同ボタンの見た目・文言切り替えに使う、現在の本が
    /// お気に入りに登録済みかどうか。ContentView.bodyがfavoritesStore(EnvironmentObject)と
    /// appState.currentBookから都度計算して詰める(favoritesStoreの変更自体はAppStateの
    /// @Publishedプロパティではないため、ContentView側で計算する必要がある)。
    var isCurrentBookFavorited = false
    /// 同じく、現在のページがブックマーク済みかどうか(ブックマーク追加/削除トグルボタン用)。
    var isCurrentPageBookmarked = false
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
