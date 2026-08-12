import Foundation
import Combine

/// アプリ全体(本ごとではない)の環境設定。UserDefaultsに保存する。
/// cooViewerの「環境設定ウィンドウ」の一部に相当する。
@MainActor
final class AppPreferences: ObservableObject {
    private enum Keys {
        static let launchOpensLastBook = "qooViewer.pref.launchOpensLastBook"
        static let launchFullScreen = "qooViewer.pref.launchFullScreen"
        static let loopBehavior = "qooViewer.pref.loopBehavior"
        static let maxUpscalePercent = "qooViewer.pref.maxUpscalePercent"
        static let loupeMagnificationPercent = "qooViewer.pref.loupeMagnificationPercent"
        static let loupeDiameter = "qooViewer.pref.loupeDiameter"
        static let interpolationQuality = "qooViewer.pref.interpolationQuality"
        static let autoHideCursor = "qooViewer.pref.autoHideCursor"
        static let slideshowInterval = "qooViewer.pref.slideshowInterval"
        static let defaultScalingMode = "qooViewer.pref.defaultScalingMode"
        static let treatTrackpadFlickAsWheel = "qooViewer.pref.treatTrackpadFlickAsWheel"
        static let quitWhenLastWindowClosed = "qooViewer.pref.quitWhenLastWindowClosed"
        static let singlePageAspectRatioThreshold = "qooViewer.pref.singlePageAspectRatioThreshold"
        static let backgroundColorOption = "qooViewer.pref.backgroundColorOption"
        static let cursorAutoHideDelay = "qooViewer.pref.cursorAutoHideDelay"
        static let prefetchPageCount = "qooViewer.pref.prefetchPageCount"
        static let displayLanguage = "qooViewer.pref.displayLanguage"
        static let reopenBehavior = "qooViewer.pref.reopenBehavior"
        static let confirmBeforeClosingMultipleTabsWindow =
            "qooViewer.pref.confirmBeforeClosingMultipleTabsWindow"
        static let finderOpenBehavior = "qooViewer.pref.finderOpenBehavior"
        static let favoriteOpenBehavior = "qooViewer.pref.favoriteOpenBehavior"
        static let maxTrackedBooksCount = "qooViewer.pref.maxTrackedBooksCount"
        static let hideToolbar = "qooViewer.pref.hideToolbar"
        static let hideProgressBar = "qooViewer.pref.hideProgressBar"
        static let hideSidePanel = "qooViewer.pref.hideSidePanel"
        static let sidePanelWidth = "qooViewer.pref.sidePanelWidth"
        static let sidePanelFeatureEnabled = "qooViewer.pref.sidePanelFeatureEnabled"
        static let sidePanelUsesDoubleClick = "qooViewer.pref.sidePanelUsesDoubleClick"
        static let sidePanelSortOrder = "qooViewer.pref.sidePanelSortOrder"
        static let sidePanelMode = "qooViewer.pref.sidePanelMode"
        static let showProgressBarThumbnailPreview = "qooViewer.pref.showProgressBarThumbnailPreview"
        static let showRecentFilesOnWelcome = "qooViewer.pref.showRecentFilesOnWelcome"
        static let showRecentFavoritesOnWelcome = "qooViewer.pref.showRecentFavoritesOnWelcome"
        static let defaultReadingDirection = "qooViewer.pref.defaultReadingDirection"
        static let spreadBookmarkTargetBehavior = "qooViewer.pref.spreadBookmarkTargetBehavior"
    }

    /// 入力ファイルなしで起動した場合(Finderでの直接オープンやDockアイコンへの
    /// ドラッグ&ドロップ以外の、通常の起動)に、前回終了時にアクティブだった画面/タブが
    /// 表示していた本を自動的に開く。すべてのウインドウ・タブを復元するわけではなく、
    /// その1冊だけが対象。復元前に、そのファイルが削除されていないか、前回開いたときから
    /// 中身が変わっていないかを確認し、どちらかに該当する場合は復元しない
    /// (詳細はContentView.swiftのresolveLastActiveBookURLIfUnchanged参照)。
    @Published var launchOpensLastBook: Bool {
        didSet { UserDefaults.standard.set(launchOpensLastBook, forKey: Keys.launchOpensLastBook) }
    }
    /// 起動時にフルスクリーンにする
    @Published var launchFullScreen: Bool {
        didSet { UserDefaults.standard.set(launchFullScreen, forKey: Keys.launchFullScreen) }
    }
    /// 最初/最後のページを超えてページ送りしようとしたときの挙動
    @Published var loopBehavior: LoopBehavior {
        didSet { UserDefaults.standard.set(loopBehavior.rawValue, forKey: Keys.loopBehavior) }
    }
    /// 画像が画面より小さいとき、最大何%まで拡大して表示するか(100〜500)
    @Published var maxUpscalePercent: Double {
        didSet { UserDefaults.standard.set(maxUpscalePercent, forKey: Keys.maxUpscalePercent) }
    }
    /// ルーペの拡大率(%)
    @Published var loupeMagnificationPercent: Double {
        didSet { UserDefaults.standard.set(loupeMagnificationPercent, forKey: Keys.loupeMagnificationPercent) }
    }
    /// ルーペの表示直径(pt)
    @Published var loupeDiameter: Double {
        didSet { UserDefaults.standard.set(loupeDiameter, forKey: Keys.loupeDiameter) }
    }
    /// 拡大縮小時の補間品質
    @Published var interpolationQuality: InterpolationQuality {
        didSet { UserDefaults.standard.set(interpolationQuality.rawValue, forKey: Keys.interpolationQuality) }
    }
    /// しばらく操作がないときマウスカーソルを自動的に隠す
    @Published var autoHideCursor: Bool {
        didSet { UserDefaults.standard.set(autoHideCursor, forKey: Keys.autoHideCursor) }
    }
    /// スライドショーでページがめくられる間隔(秒)
    @Published var slideshowInterval: Double {
        didSet { UserDefaults.standard.set(slideshowInterval, forKey: Keys.slideshowInterval) }
    }
    /// 新しく開いた本に最初に適用する表示モード
    @Published var defaultScalingMode: ScalingMode {
        didSet { UserDefaults.standard.set(defaultScalingMode.rawValue, forKey: Keys.defaultScalingMode) }
    }
    /// トラックパッドでのページ送りに、Macの「ページ間をスワイプ」ジェスチャー(フリック)を
    /// 使用する。ONにすると、トラックパッドの2本指の縦スクロールによるページ送りは行われなく
    /// なり(完全に無視される)、代わりに左右へのフリックでページ送りするようになる
    /// (詳細はViewerView.swiftのhandleTrackpadScrollGesture/handleSwipeのコメント参照)。
    /// 物理的なマウスホイールでのページ送りには影響しない。
    @Published var treatTrackpadFlickAsWheel: Bool {
        didSet { UserDefaults.standard.set(treatTrackpadFlickAsWheel, forKey: Keys.treatTrackpadFlickAsWheel) }
    }
    /// すべてのウインドウ(実寸表示・環境設定ウインドウを含む)を閉じたときにqooViewerを終了する。
    /// OFF(既定)のときは、macOSの標準的なアプリと同様にウインドウを閉じてもDockに残ります。
    @Published var quitWhenLastWindowClosed: Bool {
        didSet { UserDefaults.standard.set(quitWhenLastWindowClosed, forKey: Keys.quitWhenLastWindowClosed) }
    }
    /// 見開き表示中でも、この値(横÷縦)以上の横長画像は単ページ表示にする。既定は1.0(正方形以上で単ページ)。
    @Published var singlePageAspectRatioThreshold: Double {
        didSet {
            UserDefaults.standard.set(singlePageAspectRatioThreshold, forKey: Keys.singlePageAspectRatioThreshold)
        }
    }
    /// ビューワーの背景色
    @Published var backgroundColorOption: BackgroundColorOption {
        didSet { UserDefaults.standard.set(backgroundColorOption.rawValue, forKey: Keys.backgroundColorOption) }
    }
    /// しばらく操作がないと判定してマウスカーソルを自動的に隠すまでの時間(秒)
    @Published var cursorAutoHideDelay: Double {
        didSet { UserDefaults.standard.set(cursorAutoHideDelay, forKey: Keys.cursorAutoHideDelay) }
    }
    /// 現在のページの前後何ページ分を先読みするか
    @Published var prefetchPageCount: Double {
        didSet { UserDefaults.standard.set(prefetchPageCount, forKey: Keys.prefetchPageCount) }
    }
    /// アプリの表示言語(既定は「システムに従う」)
    @Published var displayLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(displayLanguage.rawValue, forKey: Keys.displayLanguage) }
    }
    /// 以前開いたことのある本を再度開いたときの挙動(既定は「前回のページから再開する」)
    @Published var reopenBehavior: ReopenBehavior {
        didSet { UserDefaults.standard.set(reopenBehavior.rawValue, forKey: Keys.reopenBehavior) }
    }
    /// 複数のタブを開いているウインドウを、赤い閉じるボタンまたはウインドウメニューの
    /// 「ウインドウを閉じる」で閉じようとしたとき、本当に閉じてよいか確認するダイアログを
    /// 表示するかどうか(既定はON)。OFFのときは確認なしで閉じる。
    /// (Cmd+Wやタブバー自身の×ボタンでは、AppKit上の制約によりこの確認は出せない。
    ///  QooViewerApp.swiftのBookClosingWindowDelegateのコメント参照)。
    @Published var confirmBeforeClosingMultipleTabsWindow: Bool {
        didSet {
            UserDefaults.standard.set(
                confirmBeforeClosingMultipleTabsWindow,
                forKey: Keys.confirmBeforeClosingMultipleTabsWindow
            )
        }
    }
    /// 既に本を表示している状態で、Finderから(ダブルクリックや「このアプリケーションで開く」で)
    /// 別の本を開こうとしたときの挙動(既定は「現在の本を閉じて新しい本を開く」=以前からの挙動)。
    @Published var finderOpenBehavior: FinderOpenBehavior {
        didSet { UserDefaults.standard.set(finderOpenBehavior.rawValue, forKey: Keys.finderOpenBehavior) }
    }
    /// 既に本を表示している状態で、お気に入り一覧(メニューバー・ツールバー・ウェルカム画面)から
    /// 別の本を開こうとしたときの挙動(既定は「現在の本を閉じて新しい本を開く」)。
    /// FinderOpenBehaviorと選択肢(現在の本を閉じて開く/新しいタブ/新しいウインドウ)が同じ
    /// ため、型はそのまま再利用している。以前はお気に入りを開くたびにサブメニューから
    /// 「開く/新しいウインドウで開く/新しいタブで開く」を毎回選ぶ形式だったが、
    /// この環境設定1箇所で挙動を固定できるように変更した。
    @Published var favoriteOpenBehavior: FinderOpenBehavior {
        didSet { UserDefaults.standard.set(favoriteOpenBehavior.rawValue, forKey: Keys.favoriteOpenBehavior) }
    }
    /// 見開き表示中(実際に2ページ組でペア表示されているとき)、クリック位置の情報が無い経路
    /// (ツールバーのボタン・メニューバー「お気に入り」メニュー・キーボードショートカット)から
    /// 「現在のページをブックマークに追加」したときに、左右どちらのページを対象にするか
    /// (既定は「読み方向に応じた既定側を常に対象にする」=この設定を導入する以前からの挙動)。
    /// コンテキストメニュー(右クリック)からの追加はクリックした側のページを一意に対象にできる
    /// ため、この設定に関わらず常にクリックした側が対象になる(ViewerView.contextMenuContent参照。
    /// ユーザー報告: 見開き表示でのブックマーク追加対象を左右で正しく指定できるようにしてほしい)。
    @Published var spreadBookmarkTargetBehavior: SpreadBookmarkTargetBehavior {
        didSet {
            UserDefaults.standard.set(
                spreadBookmarkTargetBehavior.rawValue, forKey: Keys.spreadBookmarkTargetBehavior
            )
        }
    }
    /// 本ごとの読書状態(最後に読んだページなど)とブックマークを保持しておく本の数の上限。
    /// これを超えて新しい本を開くと、最後に読んだ時刻が古い本のデータから自動的に削除される
    /// (LibraryDataPruner参照)。データが際限なく増え続けるのを防ぐための設定(既定500冊)。
    @Published var maxTrackedBooksCount: Double {
        didSet { UserDefaults.standard.set(maxTrackedBooksCount, forKey: Keys.maxTrackedBooksCount) }
    }
    /// 表示メニューの「ツールバーを隠す」。以前はAppState(ウインドウごとに新規作成される)だけが
    /// 持つ一時的な状態だったため、アプリを終了して再度起動するとOFFに戻ってしまっていた。
    /// ここに持たせてUserDefaultsへ保存することで、次回起動時にも再現するようにしている
    /// (新しく開いたウインドウは、AppState側でここの値を初期値として引き継ぐ)。
    @Published var hideToolbar: Bool {
        didSet { UserDefaults.standard.set(hideToolbar, forKey: Keys.hideToolbar) }
    }
    /// 表示メニューの「プログレスバーを隠す」。hideToolbarと同じ理由でここに持たせている。
    @Published var hideProgressBar: Bool {
        didSet { UserDefaults.standard.set(hideProgressBar, forKey: Keys.hideProgressBar) }
    }
    /// 表示メニューの「サイドパネルを隠す」。hideToolbarと同じ理由でここに持たせている。
    /// hideToolbar/hideProgressBarと異なり、サイドパネルは既定でOFF(=常時表示)。ONにすると
    /// ツールバー/プログレスバーの自動隠しと同様、マウスをウインドウ左端に近づけたときだけ
    /// 一時的に表示される(ContentView.installSidePanelHoverMonitorIfNeeded参照)。
    @Published var hideSidePanel: Bool {
        didSet { UserDefaults.standard.set(hideSidePanel, forKey: Keys.hideSidePanel) }
    }
    /// サイドパネルの幅(pt)。ユーザーが右端のドラッグハンドルで調整した値を次回起動時にも
    /// 再現する(SidePanelView.widthDragHitArea参照)。CGFloatではなくDoubleで持つのは
    /// maxTrackedBooksCountと同じ理由(UserDefaultsとの親和性)で、ContentView側で
    /// CGFloatへ変換して使う。
    @Published var sidePanelWidth: Double {
        didSet { UserDefaults.standard.set(sidePanelWidth, forKey: Keys.sidePanelWidth) }
    }
    /// 環境設定「一般」タブの、サイドパネル機能自体のON/OFF(既定ON)。hideSidePanelが
    /// 「常時表示か、ホバーで一時表示か」を切り替えるだけなのに対し、こちらはOFFにすると
    /// サイドパネル自体を一切表示しなくする(ContentView.body参照)。OFFの間は、表示メニューの
    /// 「サイドパネルを隠す」項目もメニューごと非表示になる(意味の無い設定を見せないため。
    /// QooViewerApp.swiftのCommandGroup参照)。
    @Published var sidePanelFeatureEnabled: Bool {
        didSet { UserDefaults.standard.set(sidePanelFeatureEnabled, forKey: Keys.sidePanelFeatureEnabled) }
    }
    /// 環境設定「一般」タブの、サイドパネルの「開く」「移動する」操作をダブルクリックにする
    /// かどうか(既定OFF=シングルクリック)。OFF(既定)では、上段のファイル行・フォルダの
    /// 「移動」、下段の画像・コンテナ行はすべてシングルクリック、フォルダを画像フォルダとして
    /// 本を開く操作だけダブルクリック(この2つは同じ行に対する別の操作のため区別が必要)。
    /// ONにすると「開く」「移動する」のすべてがダブルクリックになる。この場合、上段の
    /// フォルダだけは「移動する」と「画像フォルダとして開く」の2つの意味をダブルクリック1つで
    /// 表せないため、直下に画像ファイルがあれば開く、無ければ移動する、という判定に切り替わる
    /// (DirectoryBrowser.directlyContainsImageFile参照。ユーザー要望)。戻る/進む/1階層上への
    /// ボタン操作はこの設定に関わらず常にシングルクリックのまま。
    @Published var sidePanelUsesDoubleClick: Bool {
        didSet { UserDefaults.standard.set(sidePanelUsesDoubleClick, forKey: Keys.sidePanelUsesDoubleClick) }
    }
    /// 環境設定「一般」タブの、サイドパネル(上段・下段どちらも)のフォルダ・ファイルの
    /// 並び順(既定はフォルダをまとめて上に表示、Finderと同じ考え方)。DirectoryBrowser/
    /// BookInternalBrowsingはどちらもnonisolated enum(MainActor隔離のAppPreferencesを
    /// 直接読めない)のため、SidePanelBrowserState/BookContentsBrowserStateがreload()の
    /// たびにこの値を引数として渡す。
    @Published var sidePanelSortOrder: SidePanelSortOrder {
        didSet { UserDefaults.standard.set(sidePanelSortOrder.rawValue, forKey: Keys.sidePanelSortOrder) }
    }
    /// サイドパネルの表示モード(ブラウザ/ブックマーク。SidePanelMode参照)。パネル最上部の
    /// スイッチで切り替える。ウインドウごとではなくアプリ全体で1つの値として持つ
    /// (sidePanelWidthと同じ考え方: 新しいウインドウ/タブや次回起動時も同じ見た目で始まる)。
    /// sidePanelWidthと違ってドラッグ中に高頻度で変化する値ではないため、ContentView側で
    /// @Stateへ写し取らず、この@Publishedを直接Bindingとして使う。
    @Published var sidePanelMode: SidePanelMode {
        didSet { UserDefaults.standard.set(sidePanelMode.rawValue, forKey: Keys.sidePanelMode) }
    }
    /// プログレスバーにカーソルを合わせたときに、フィルムストリップ(サムネイル・ファイル名・
    /// ページ番号を含むプレビュー)を表示するかどうか(既定ON)。OFFにすると、サムネイルの
    /// 読み込みは一切行わず、カーソル位置に対応するページ番号だけを表示するシンプルな表示になる
    /// (ProgressBarView.swift参照)。
    @Published var showProgressBarThumbnailPreview: Bool {
        didSet {
            UserDefaults.standard.set(
                showProgressBarThumbnailPreview,
                forKey: Keys.showProgressBarThumbnailPreview
            )
        }
    }
    /// 「最近開いたファイル」の履歴として保持する件数(既定30件)。
    ///
    /// 以前はRecentFilesStore側に10件固定で埋め込まれていたが、サイドパネルの「履歴」モードで
    /// 一覧として使うようになり10件では足りないため、設定できるようにした(ユーザー要望)。
    /// maxTrackedBooksCountと同じ理由でDoubleとして持つ(SettingsSliderがDoubleを扱うため)。
    ///
    /// 【重要】この値の実際の読み取りは、AppPreferencesを参照できないRecentFilesStoreが
    /// UserDefaultsから直接行う(recentFilesLimitDefaultsKey参照)。RecentFilesStoreは
    /// QooViewerApp側でAppPreferencesとは独立に生成される@StateObjectであり、相互参照を
    /// 増やさずに済ませるための割り切り。キー文字列を二重管理しないよう、下の
    /// recentFilesLimitDefaultsKeyを両者で共有する。
    @Published var recentFilesLimit: Double {
        didSet {
            UserDefaults.standard.set(recentFilesLimit, forKey: Self.recentFilesLimitDefaultsKey)
            // 件数を減らした場合に、その場で履歴側も切り詰めさせる(次に本を開くまで
            // 古い履歴が残り続けないようにするため)。
            NotificationCenter.default.post(name: .recentFilesLimitDidChange, object: nil)
        }
    }
    /// recentFilesLimitのUserDefaultsキー。RecentFilesStoreと共有する(上のコメント参照)。
    static let recentFilesLimitDefaultsKey = "qooViewer.pref.recentFilesLimit"
    /// recentFilesLimitの既定値・下限・上限。RecentFilesStore側の読み取りでも同じ値を使う。
    static let defaultRecentFilesLimit: Double = 30
    static let recentFilesLimitRange: ClosedRange<Double> = 10...200

    /// ウェルカム画面に「最近開いたファイル」一覧(最大10件)を表示するかどうか(既定ON)。
    /// 履歴として保持する件数(recentFilesLimit)を増やしても、ウェルカム画面の一覧は
    /// 画面が縦に伸びすぎないよう10件までに留める(WelcomeView参照)。
    @Published var showRecentFilesOnWelcome: Bool {
        didSet { UserDefaults.standard.set(showRecentFilesOnWelcome, forKey: Keys.showRecentFilesOnWelcome) }
    }
    /// ウェルカム画面に「最近お気に入りに追加したファイル」一覧(最大10件)を表示するかどうか(既定ON)。
    @Published var showRecentFavoritesOnWelcome: Bool {
        didSet {
            UserDefaults.standard.set(showRecentFavoritesOnWelcome, forKey: Keys.showRecentFavoritesOnWelcome)
        }
    }
    /// 新しい本を初めて開いたときの、読み方向の既定値(設計コンセプト11.1節)。
    ///
    /// 以前は`BookReadingState.init`のデフォルト引数として無条件に右開き(RTL)固定になっていたが、
    /// アプリを初めて起動した時点(一度だけ)でシステムの言語設定を確認し、日本語であれば右開き、
    /// それ以外の言語であれば一律左開き(LTR)を既定値として決定・保存する(言語ごとの個別判定は
    /// 行わない)。以降は、システム言語が後から変わっても、この一度決定した値を使い続ける
    /// (init()参照。本ごとに毎回ロケール判定をやり直すわけではない)。
    @Published var defaultReadingDirection: ReadingDirection {
        didSet {
            UserDefaults.standard.set(defaultReadingDirection.rawValue, forKey: Keys.defaultReadingDirection)
        }
    }
    // ブックマークの並べ替え基準は、以前はここ(AppPreferences.bookmarkSortOption)に
    // 持たせていたが、「ブックマークの編集」ウインドウがすべての本を横断する2ペイン構成に
    // なったことに伴い、お気に入りのFavoritesStoreと同じく専用のストア(BookmarkStore)が
    // 自分自身で持つように変更した(BookmarkStore.sortOption参照)。

    /// displayLanguage を実際の Locale に変換したもの。
    /// SwiftUIのView階層外(AppState・ViewerViewModelなど)で動的な文字列を組み立てるときに使う。
    /// View階層内では `.environment(\.locale:)` 経由で自動的に反映されるため、通常はこちらを使う必要はない。
    var effectiveLocale: Locale {
        displayLanguage.localeOverride ?? .autoupdatingCurrent
    }

    init() {
        let defaults = UserDefaults.standard
        self.launchOpensLastBook = defaults.object(forKey: Keys.launchOpensLastBook) as? Bool ?? false
        self.launchFullScreen = defaults.object(forKey: Keys.launchFullScreen) as? Bool ?? false
        self.loopBehavior = LoopBehavior(rawValue: defaults.string(forKey: Keys.loopBehavior) ?? "") ?? .none
        self.maxUpscalePercent = defaults.object(forKey: Keys.maxUpscalePercent) as? Double ?? 200
        self.loupeMagnificationPercent =
            defaults.object(forKey: Keys.loupeMagnificationPercent) as? Double ?? 250
        self.loupeDiameter = defaults.object(forKey: Keys.loupeDiameter) as? Double ?? 400
        self.interpolationQuality = InterpolationQuality(rawValue: defaults.string(forKey: Keys.interpolationQuality) ?? "") ?? .high
        self.autoHideCursor = defaults.object(forKey: Keys.autoHideCursor) as? Bool ?? true
        self.slideshowInterval = defaults.object(forKey: Keys.slideshowInterval) as? Double ?? 5
        self.defaultScalingMode = ScalingMode(rawValue: defaults.string(forKey: Keys.defaultScalingMode) ?? "") ?? .fitToScreen
        self.treatTrackpadFlickAsWheel = defaults.object(forKey: Keys.treatTrackpadFlickAsWheel) as? Bool ?? true
        self.quitWhenLastWindowClosed = defaults.object(forKey: Keys.quitWhenLastWindowClosed) as? Bool ?? false
        self.singlePageAspectRatioThreshold =
            defaults.object(forKey: Keys.singlePageAspectRatioThreshold) as? Double ?? 1.0
        self.backgroundColorOption =
            BackgroundColorOption(rawValue: defaults.string(forKey: Keys.backgroundColorOption) ?? "") ?? .black
        self.cursorAutoHideDelay = defaults.object(forKey: Keys.cursorAutoHideDelay) as? Double ?? 2.0
        self.prefetchPageCount = defaults.object(forKey: Keys.prefetchPageCount) as? Double ?? 3
        self.displayLanguage = AppLanguage(rawValue: defaults.string(forKey: Keys.displayLanguage) ?? "") ?? .system
        self.reopenBehavior = ReopenBehavior(rawValue: defaults.string(forKey: Keys.reopenBehavior) ?? "") ?? .resume
        self.confirmBeforeClosingMultipleTabsWindow =
            defaults.object(forKey: Keys.confirmBeforeClosingMultipleTabsWindow) as? Bool ?? true
        self.finderOpenBehavior =
            FinderOpenBehavior(rawValue: defaults.string(forKey: Keys.finderOpenBehavior) ?? "")
                ?? .replaceCurrentBook
        self.favoriteOpenBehavior =
            FinderOpenBehavior(rawValue: defaults.string(forKey: Keys.favoriteOpenBehavior) ?? "")
                ?? .replaceCurrentBook
        self.spreadBookmarkTargetBehavior =
            SpreadBookmarkTargetBehavior(rawValue: defaults.string(forKey: Keys.spreadBookmarkTargetBehavior) ?? "")
                ?? .defaultSide
        self.maxTrackedBooksCount = defaults.object(forKey: Keys.maxTrackedBooksCount) as? Double ?? 500
        self.hideToolbar = defaults.object(forKey: Keys.hideToolbar) as? Bool ?? false
        self.hideProgressBar = defaults.object(forKey: Keys.hideProgressBar) as? Bool ?? false
        self.hideSidePanel = defaults.object(forKey: Keys.hideSidePanel) as? Bool ?? false
        // 既定値280は、SidePanelView.defaultWidthと同じ値(ViewModelからView側の定数を
        // 参照する層の逆転を避けるため、ここでは値を直接持たせている)。
        self.sidePanelWidth = defaults.object(forKey: Keys.sidePanelWidth) as? Double ?? 280
        self.sidePanelFeatureEnabled = defaults.object(forKey: Keys.sidePanelFeatureEnabled) as? Bool ?? true
        self.sidePanelUsesDoubleClick = defaults.object(forKey: Keys.sidePanelUsesDoubleClick) as? Bool ?? false
        self.sidePanelSortOrder =
            SidePanelSortOrder(rawValue: defaults.string(forKey: Keys.sidePanelSortOrder) ?? "") ?? .foldersFirst
        self.sidePanelMode =
            SidePanelMode(rawValue: defaults.string(forKey: Keys.sidePanelMode) ?? "") ?? .browser
        self.showProgressBarThumbnailPreview =
            defaults.object(forKey: Keys.showProgressBarThumbnailPreview) as? Bool ?? true
        self.recentFilesLimit =
            defaults.object(forKey: Self.recentFilesLimitDefaultsKey) as? Double
            ?? Self.defaultRecentFilesLimit
        self.showRecentFilesOnWelcome =
            defaults.object(forKey: Keys.showRecentFilesOnWelcome) as? Bool ?? true
        self.showRecentFavoritesOnWelcome =
            defaults.object(forKey: Keys.showRecentFavoritesOnWelcome) as? Bool ?? true

        if let storedRaw = defaults.string(forKey: Keys.defaultReadingDirection),
           let stored = ReadingDirection(rawValue: storedRaw) {
            self.defaultReadingDirection = stored
        } else {
            // まだ一度も決定されていない(初回起動)。システムの言語設定を確認して一度だけ決定し、
            // 以降のために保存しておく(次回起動時は上のstored分岐に入り、再判定はしない)。
            let systemIsJapanese = Locale.preferredLanguages.first?.hasPrefix("ja") ?? false
            let determined: ReadingDirection = systemIsJapanese ? .rightToLeft : .leftToRight
            self.defaultReadingDirection = determined
            defaults.set(determined.rawValue, forKey: Keys.defaultReadingDirection)
        }
    }
}
