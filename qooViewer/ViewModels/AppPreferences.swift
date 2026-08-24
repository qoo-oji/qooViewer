import Foundation
import Combine
// effectiveBackgroundColorがSwiftUIのColorを返すため(RGBColorValueも同様)。
import SwiftUI
// thumbnailHoverPreviewPixelSizeが接続中の画面の倍率(NSScreen)を見るため。
import AppKit

/// アプリ全体(本ごとではない)の環境設定。UserDefaultsに保存する。
/// cooViewerの「環境設定ウィンドウ」の一部に相当する。
@MainActor
final class AppPreferences: ObservableObject {
    private enum Keys {
        static let launchOpensLastBook = "qooViewer.pref.launchOpensLastBook"
        static let launchFullScreen = "qooViewer.pref.launchFullScreen"
        static let loopBehavior = "qooViewer.pref.loopBehavior"
        static let maxUpscalePercent = "qooViewer.pref.maxUpscalePercent"
        static let maxPinchZoomPercent = "qooViewer.pref.maxPinchZoomPercent"
        static let loupeMagnificationPercent = "qooViewer.pref.loupeMagnificationPercent"
        static let loupeDiameter = "qooViewer.pref.loupeDiameter"
        static let interpolationQuality = "qooViewer.pref.interpolationQuality"
        static let autoHideCursor = "qooViewer.pref.autoHideCursor"
        static let slideshowInterval = "qooViewer.pref.slideshowInterval"
        static let defaultScalingMode = "qooViewer.pref.defaultScalingMode"
        static let treatTrackpadFlickAsWheel = "qooViewer.pref.treatTrackpadFlickAsWheel"
        static let invertTwoFingerScrolling = "qooViewer.pref.invertTwoFingerScrolling"
        static let quitWhenLastWindowClosed = "qooViewer.pref.quitWhenLastWindowClosed"
        static let singlePageAspectRatioThreshold = "qooViewer.pref.singlePageAspectRatioThreshold"
        static let backgroundColorOption = "qooViewer.pref.backgroundColorOption"
        static let customBackgroundColor = "qooViewer.pref.customBackgroundColor"
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
        static let folderBrowserSortKey = "qooViewer.pref.folderBrowserSortKey"
        static let folderBrowserSortDirection = "qooViewer.pref.folderBrowserSortDirection"
        static let siblingNavigationFollowsBrowserSort = "qooViewer.pref.siblingNavigationFollowsBrowserSort"
        static let sidePanelPosition = "qooViewer.pref.sidePanelPosition"
        static let sidePanelMode = "qooViewer.pref.sidePanelMode"
        static let showProgressBarThumbnailPreview = "qooViewer.pref.showProgressBarThumbnailPreview"
        static let showRecentFilesOnWelcome = "qooViewer.pref.showRecentFilesOnWelcome"
        static let showRecentFavoritesOnWelcome = "qooViewer.pref.showRecentFavoritesOnWelcome"
        static let thumbnailGridCellSize = "qooViewer.pref.thumbnailGridCellSize"
        static let thumbnailGridHorizontalSpacing = "qooViewer.pref.thumbnailGridHorizontalSpacing"
        static let thumbnailGridVerticalSpacing = "qooViewer.pref.thumbnailGridVerticalSpacing"
        static let thumbnailGridHorizontalMarginPercent = "qooViewer.pref.thumbnailGridHorizontalMarginPercent"
        static let thumbnailGridVerticalMarginPercent = "qooViewer.pref.thumbnailGridVerticalMarginPercent"
        static let showThumbnailHoverPreview = "qooViewer.pref.showThumbnailHoverPreview"
        static let thumbnailHoverPreviewDelay = "qooViewer.pref.thumbnailHoverPreviewDelay"
        static let thumbnailHoverPreviewSize = "qooViewer.pref.thumbnailHoverPreviewSize"
        static let preloadThumbnailGridPreviews = "qooViewer.pref.preloadThumbnailGridPreviews"
        static let defaultReadingDirection = "qooViewer.pref.defaultReadingDirection"
        static let spreadBookmarkTargetBehavior = "qooViewer.pref.spreadBookmarkTargetBehavior"
        static let thumbnailGridCaptionStyle = "qooViewer.pref.thumbnailGridCaptionStyle"
        static let thumbnailGridCaptionFontSize = "qooViewer.pref.thumbnailGridCaptionFontSize"
        static let thumbnailGridBorderColorOption = "qooViewer.pref.thumbnailGridBorderColorOption"
        static let thumbnailGridBorderCustomColor = "qooViewer.pref.thumbnailGridBorderCustomColor"
        static let thumbnailGridWheelScrollRows = "qooViewer.pref.thumbnailGridWheelScrollRows"
        static let launchInPrivateMode = "qooViewer.pref.launchInPrivateMode"
        static let thumbnailDiskCacheEnabled = "qooViewer.pref.thumbnailDiskCacheEnabled"
        static let thumbnailDiskCacheLimitMB = "qooViewer.pref.thumbnailDiskCacheLimitMB"
        static let pageImageCacheLimitMB = "qooViewer.pref.pageImageCacheLimitMB"

        /// すりガラスの面ごとの設定(PanelSurface参照)。面の識別子ごとに3つのキーへ分かれる。
        /// 面を1つ増やしてもここは触らなくてよい(PanelSurface.allCasesから導出される)。
        static func panelSurfaceMaterialOpacity(_ surface: PanelSurface) -> String {
            "qooViewer.pref.surface.\(surface.rawValue).materialOpacity"
        }
        static func panelSurfaceTintColor(_ surface: PanelSurface) -> String {
            "qooViewer.pref.surface.\(surface.rawValue).tintColor"
        }
        static func panelSurfaceTintOpacity(_ surface: PanelSurface) -> String {
            "qooViewer.pref.surface.\(surface.rawValue).tintOpacity"
        }
        static func panelSurfaceContentShadowLevel(_ surface: PanelSurface) -> String {
            "qooViewer.pref.surface.\(surface.rawValue).contentShadowLevel"
        }
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
    /// 画像が画面より小さいとき、最大何%まで拡大して表示するか(100〜800)
    @Published var maxUpscalePercent: Double {
        didSet { UserDefaults.standard.set(maxUpscalePercent, forKey: Keys.maxUpscalePercent) }
    }
    /// トラックパッドのピンチイン・ピンチアウトで、初期表示(=そのモードでの通常の表示倍率)を
    /// 100%としたとき、最大何%まで拡大できるか(100〜800)。
    ///
    /// maxUpscalePercentとは目的が別で、互いに影響しない。あちらは「小さい画像を勝手に
    /// 引き伸ばしすぎない」ための自動拡大の上限で、こちらはユーザーが明示的に行った拡大操作の
    /// 上限である(自動でそこまで拡大されることはない)。100%にするとピンチ拡大が実質無効になる。
    ///
    /// 表示用画像は長辺4096px上限でデコードされる(ImageDecoder.pageMaxPixelSize)が、ピンチ拡大中は
    /// より高解像度のソース(highResolutionMaxPixelSize、8000px)へ差し替えて描画するため、
    /// 既定の400%程度までは実用的な画質を保てる(ViewerView.pageArea参照)。
    @Published var maxPinchZoomPercent: Double {
        didSet { UserDefaults.standard.set(maxPinchZoomPercent, forKey: Keys.maxPinchZoomPercent) }
    }
    /// ルーペの拡大率(%、100〜800)
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
    /// トラックパッド(およびMagic Mouseなど、phaseを伴う「なめらかな」スクロールを送ってくる
    /// 機器)でのスクロールについて、画像が動く向きを上下左右とも逆にする(ユーザー要望)。
    ///
    /// macOSの「ナチュラルなスクロール」はシステム全体の設定で、マウスホイールにも同時に
    /// 効いてしまう。この設定はqooViewerの中のトラックパッド操作だけを対象にするため、
    /// 「トラックパッドは逆向きが好みだが、マウスホイールは今のままにしたい」という使い分けが
    /// できる(そのため物理マウスホイールは意図的に対象外にしてある)。
    ///
    /// 反転するのは**画像が動く向きだけ**である。ホイールの上/下や横フリックに割り当てられた
    /// 操作(既定ではページ送り)の向きは変えない ― そちらは「キー・マウス」設定で上下を
    /// 入れ替えられるため、ここでも反転させると二重になり、どちらを直せばよいのか分から
    /// なくなるため(ユーザーの判断)。ただし「スクロールできるモードで端まで来たらページを
    /// 送る」動作だけは、スクロールそのものの延長なので反転後の進行方向に従う。
    @Published var invertTwoFingerScrolling: Bool {
        didSet { UserDefaults.standard.set(invertTwoFingerScrolling, forKey: Keys.invertTwoFingerScrolling) }
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
    /// ビューワーの背景色(プリセット、または「カスタム」)
    @Published var backgroundColorOption: BackgroundColorOption {
        didSet { UserDefaults.standard.set(backgroundColorOption.rawValue, forKey: Keys.backgroundColorOption) }
    }
    /// `backgroundColorOption`が`.custom`のときに使う、ユーザーが自分で指定した背景色。
    /// 環境設定「描画」タブの「カスタム色」から開くダイアログ(BackgroundColorPickerSheet)で編集する。
    ///
    /// プリセット側(`backgroundColorOption`)とは独立に保存しているので、いったんプリセットの
    /// 黒に戻してから再び「カスタム」を選び直しても、作った色はそのまま残る。
    @Published var customBackgroundColor: RGBColorValue {
        didSet {
            UserDefaults.standard.set(customBackgroundColor.hexString, forKey: Keys.customBackgroundColor)
        }
    }
    /// カスタム背景色をまだ一度も指定していないときの初期値(暗めのグレー)。
    /// 既定のプリセットである黒と近すぎず、かつ長時間の閲覧で目に痛くない明るさを選んである。
    static let defaultCustomBackgroundColor = RGBColorValue(red: 64, green: 64, blue: 64)

    /// 実際にビューワーの背景を塗るのに使う色。プリセットとカスタムの解決をここ1箇所に集約し、
    /// 表示側(ViewerView・実寸表示ウインドウ)が`.custom`の扱いを個別に持たなくて済むようにしている。
    var effectiveBackgroundColor: Color {
        backgroundColorOption.presetColor ?? customBackgroundColor.color
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
    /// サイドパネル上段(フォルダブラウザ)の並べ替えの基準と向き(ユーザー要望)。環境設定
    /// ウインドウではなく、パネル上部の並べ替えメニュー(SidePanelView.folderSection)から
    /// 直接切り替える。上のsidePanelSortOrder(フォルダをまとめて上に置くかどうか)とは
    /// 独立した設定で、そちらが上段・下段の共通設定なのに対し、こちらは上段専用
    /// (FolderBrowserSortKeyのコメント参照)。
    @Published var folderBrowserSortKey: FolderBrowserSortKey {
        didSet { UserDefaults.standard.set(folderBrowserSortKey.rawValue, forKey: Keys.folderBrowserSortKey) }
    }
    @Published var folderBrowserSortDirection: FolderBrowserSortDirection {
        didSet {
            UserDefaults.standard.set(folderBrowserSortDirection.rawValue, forKey: Keys.folderBrowserSortDirection)
        }
    }
    /// 環境設定「一般」タブのサイドパネル欄の、「次の本へ」「前の本へ」およびファイルメニューの
    /// 「同じフォルダのファイルを開く」を、すぐ上のフォルダブラウザの並べ替えに合わせるかどうか
    /// (既定OFF = 名前順。ユーザー要望)。
    ///
    /// **サイドパネル機能自体がOFFのときは効かない。** 並べ替えの基準・向きを変える手段が
    /// パネル上部のメニューしか無いため、パネルを出せない状態で「見えない設定」に従わせても
    /// 混乱するだけになる(環境設定の画面でもグレーアウトする)。この打ち消しは下の
    /// `siblingBookOrder`が一手に引き受けているので、**読む側は必ずそちらを使うこと** ――
    /// このプロパティを直接見てよいのは、環境設定画面のトグルだけ。
    @Published var siblingNavigationFollowsBrowserSort: Bool {
        didSet {
            UserDefaults.standard.set(
                siblingNavigationFollowsBrowserSort, forKey: Keys.siblingNavigationFollowsBrowserSort
            )
        }
    }

    /// 上段フォルダブラウザの並べ替えに必要な設定をまとめた値。DirectoryBrowser
    /// (nonisolated enumなのでAppPreferencesを直接読めない)へ渡す引数であると同時に、
    /// SwiftUI側が`.onChange(of: preferences.folderBrowserSort)`ひとつで3つの設定の変更を
    /// まとめて拾うためのものでもある(SidePanelView.folderSection参照)。
    var folderBrowserSort: FolderBrowserSort {
        FolderBrowserSort(
            grouping: sidePanelSortOrder,
            key: folderBrowserSortKey,
            direction: folderBrowserSortDirection
        )
    }

    /// 「次の本へ」「前の本へ」と「同じフォルダのファイルを開く」が使う並び順
    /// (SiblingBookOrder参照)。SiblingFinder(nonisolated enumなのでAppPreferencesを直接
    /// 読めない)へ渡す引数であると同時に、SwiftUI側が`.onChange(of:)`ひとつで**関係する
    /// 4つの設定**(サイドパネル機能のON/OFF・このオプション・並べ替えの基準と向き・フォルダの
    /// グループ分け)の変更をまとめて拾うためのものでもある(ContentView参照)。
    /// すぐ上のfolderBrowserSortとまったく同じ考え方。
    var siblingBookOrder: SiblingBookOrder {
        guard sidePanelFeatureEnabled, siblingNavigationFollowsBrowserSort else { return .byName }
        return .followingFolderBrowser(folderBrowserSort)
    }
    /// 環境設定「一般」タブの、サイドパネルをウインドウのどちら側に表示するか(既定は左。
    /// SidePanelPosition参照)。常時表示・ホバーでの一時表示のどちらにも同じ値が効き、
    /// ホバー時にパネルが出現する反応領域(ウインドウ端の狭い帯)もこの設定に合わせて
    /// 左右が入れ替わる(ContentView.updateSidePanelReveal参照)。
    /// sidePanelWidth/sidePanelModeと同じくアプリ全体で1つの値として持つ。
    @Published var sidePanelPosition: SidePanelPosition {
        didSet { UserDefaults.standard.set(sidePanelPosition.rawValue, forKey: Keys.sidePanelPosition) }
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

    /// ページサムネイルをディスクにも保存しておくか(ThumbnailDiskCache、既定はOFF)。
    ///
    /// ユーザー報告: 数日使っただけでキャッシュフォルダが数百MBに膨れていて驚いた。
    /// 以前はこのキャッシュを黙って作り続けており、ユーザーには存在も、止める手段も
    /// 見えていなかった。ディスクを確実に消費する機能である以上、使うかどうかは
    /// ユーザーが決めるべきなので、既定をOFFにしたうえで明示的な設定にした。
    ///
    /// OFFのあいだは読み書きしないだけでなく、既に溜まっているぶんも速やかに削除される
    /// (ThumbnailDiskCache.configure(isEnabled:maxTotalBytes:)参照)。既定がOFFなので、
    /// この版を初めて起動した時点で、これまで黙って作られていたキャッシュが自動的に片付く。
    @Published var thumbnailDiskCacheEnabled: Bool {
        didSet {
            UserDefaults.standard.set(thumbnailDiskCacheEnabled, forKey: Keys.thumbnailDiskCacheEnabled)
            applyThumbnailDiskCacheSettings()
        }
    }
    /// サムネイルのディスクキャッシュの合計上限(MB、既定200)。超えそうになると、最終アクセスが
    /// 古いサムネイルから削除される(ThumbnailDiskCache.trimIfNeeded参照)。
    /// maxTrackedBooksCountと同じ理由でDoubleとして持つ(SettingsSliderがDoubleを扱うため)。
    ///
    /// この値を下げてもユーザーのデータは失われない(消えるのは再生成できるサムネイルだけ)。
    /// 保管件数の2つ(maxTrackedBooksCount/recentFilesLimit)を「初期設定に戻す」の対象外に
    /// してあるのとは事情が違うので、こちらは対象に含めてある(keys(for:)参照)。
    @Published var thumbnailDiskCacheLimitMB: Double {
        didSet {
            UserDefaults.standard.set(thumbnailDiskCacheLimitMB, forKey: Keys.thumbnailDiskCacheLimitMB)
            applyThumbnailDiskCacheSettings()
        }
    }
    /// thumbnailDiskCacheLimitMBの既定値・下限・上限。
    static let defaultThumbnailDiskCacheLimitMB: Double = 200
    static let thumbnailDiskCacheLimitRangeMB: ClosedRange<Double> = 50...2000

    /// 開いている本1冊あたりの、デコード済みページ画像のメモリキャッシュの上限(MB、既定300)。
    /// PageLoader.imageCache(NSCache)のtotalCostLimitそのもの。
    ///
    /// 以前は300MB固定だった。ただしキャッシュがCGImageを抱えていた当時は、表示したページに
    /// CoreAnimation側のコピーが2つ付いて回るため、実際には上限の3倍近くまで膨らんでいた
    /// (PagePixelBufferの型コメント参照)。ピクセルのバイト列を持つ形に改めて数字どおりの
    /// 上限になったのを機に、ユーザーが決められるようにした(ユーザーの判断)。
    ///
    /// 大きくするほど前後のページへ戻ったときの再デコードが減り、小さくするほどメモリを
    /// 抑えられる。先読み(prefetchPageCount)ぶんが収まらないほど小さくすると、先読みした
    /// そばから追い出されて意味が無くなるので、下限は高解像度の見開きがいくつか収まる100MB。
    @Published var pageImageCacheLimitMB: Double {
        didSet { UserDefaults.standard.set(pageImageCacheLimitMB, forKey: Keys.pageImageCacheLimitMB) }
    }
    /// nonisolated: PageLoader(actor)のinitの既定引数から参照されるため(MainActor隔離のままだと
    /// Swift 6モードでエラーになる)。
    nonisolated static let defaultPageImageCacheLimitMB: Double = 300
    static let pageImageCacheLimitRangeMB: ClosedRange<Double> = 100...2000
    /// PageLoaderへ渡す形(バイト数)。
    var pageImageCacheLimitBytes: Int {
        let range = Self.pageImageCacheLimitRangeMB
        let clamped = min(max(pageImageCacheLimitMB, range.lowerBound), range.upperBound)
        return Int(clamped) * 1024 * 1024
    }

    /// いまの設定を、実際にディスクへ読み書きしているactorへ届ける。
    ///
    /// didSetからだけでなくinit()の最後からも呼ぶ(didSetは初期化中には走らないため)。
    /// 起動時の「OFFなら溜まっているぶんを消す」も、この起動時の1回が入口になっている。
    ///
    /// 呼び出しごとに世代番号を進めて渡す。独立した`Task`同士は到着順が保証されないので、
    /// 受け手(ThumbnailDiskCache.configure)が古い世代を捨てられるようにするため。
    private func applyThumbnailDiskCacheSettings() {
        let isEnabled = thumbnailDiskCacheEnabled
        let maxTotalBytes = Int(thumbnailDiskCacheLimitMB) * 1024 * 1024
        thumbnailDiskCacheConfigurationGeneration &+= 1
        let generation = thumbnailDiskCacheConfigurationGeneration
        Task {
            await ThumbnailDiskCache.shared.configure(
                isEnabled: isEnabled, maxTotalBytes: maxTotalBytes, generation: generation
            )
        }
    }
    /// applyThumbnailDiskCacheSettingsが進める世代番号(MainActor上でのみ触る)。
    private var thumbnailDiskCacheConfigurationGeneration: UInt64 = 0

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

    // MARK: - ページ一覧(サムネイルグリッド)。ユーザー要望: サイズ・間隔・余白を調整したい

    /// ページ一覧のサムネイル1枚の大きさ(pt、正方形の一辺)。パネル上部のスライダーと
    /// 環境設定「閲覧中の動作」の両方から同じ値を変える。以前は120pt固定だった。
    @Published var thumbnailGridCellSize: Double {
        didSet { UserDefaults.standard.set(thumbnailGridCellSize, forKey: Keys.thumbnailGridCellSize) }
    }
    static let thumbnailGridCellSizeRange: ClosedRange<Double> = 80...320
    /// サムネイル同士の横の間隔(pt)。
    @Published var thumbnailGridHorizontalSpacing: Double {
        didSet { UserDefaults.standard.set(thumbnailGridHorizontalSpacing, forKey: Keys.thumbnailGridHorizontalSpacing) }
    }
    /// サムネイル同士の縦の間隔(pt)。
    @Published var thumbnailGridVerticalSpacing: Double {
        didSet { UserDefaults.standard.set(thumbnailGridVerticalSpacing, forKey: Keys.thumbnailGridVerticalSpacing) }
    }
    static let thumbnailGridSpacingRange: ClosedRange<Double> = 0...40
    /// パネルの左右に残す余白(画像表示領域の幅に対する片側の%)。列数は残りの幅から自動で決まる。
    @Published var thumbnailGridHorizontalMarginPercent: Double {
        didSet { UserDefaults.standard.set(thumbnailGridHorizontalMarginPercent, forKey: Keys.thumbnailGridHorizontalMarginPercent) }
    }
    /// パネルの上下に残す余白(画像表示領域の高さに対する片側の%)。
    @Published var thumbnailGridVerticalMarginPercent: Double {
        didSet { UserDefaults.standard.set(thumbnailGridVerticalMarginPercent, forKey: Keys.thumbnailGridVerticalMarginPercent) }
    }
    static let thumbnailGridMarginPercentRange: ClosedRange<Double> = 0...40

    /// サムネイルの下に何を書くか(ThumbnailCaptionStyle参照)。既定はこれまでどおりページ番号。
    @Published var thumbnailGridCaptionStyle: ThumbnailCaptionStyle {
        didSet {
            UserDefaults.standard.set(thumbnailGridCaptionStyle.rawValue, forKey: Keys.thumbnailGridCaptionStyle)
        }
    }
    /// サムネイルの下の文字の大きさ(pt)。既定の11ptは、従来使っていた`.caption2`の実寸に
    /// 合わせたもの(値を変えていない人の見た目が変わらないようにするため)。
    @Published var thumbnailGridCaptionFontSize: Double {
        didSet {
            UserDefaults.standard.set(thumbnailGridCaptionFontSize, forKey: Keys.thumbnailGridCaptionFontSize)
        }
    }
    /// 下限8ptは、Retinaでもぎりぎり字形が潰れない大きさ。上限20ptは、サムネイルの最小サイズ
    /// (80pt)に対して文字が主役になってしまわない範囲。
    static let thumbnailGridCaptionFontSizeRange: ClosedRange<Double> = 8...20

    /// 表示中のページを示す枠の色(プリセット、または「カスタム」)。ユーザー要望。
    @Published var thumbnailGridBorderColorOption: PageBorderColorOption {
        didSet {
            UserDefaults.standard.set(thumbnailGridBorderColorOption.rawValue, forKey: Keys.thumbnailGridBorderColorOption)
        }
    }
    /// 上が`.custom`のときに使うRGB値。`customBackgroundColor`とまったく同じ考え方で、
    /// プリセットへ戻してからカスタムを選び直しても、作った色はそのまま残る。
    @Published var thumbnailGridBorderCustomColor: RGBColorValue {
        didSet {
            UserDefaults.standard.set(thumbnailGridBorderCustomColor.hexString, forKey: Keys.thumbnailGridBorderCustomColor)
        }
    }
    /// カスタムの枠色をまだ一度も指定していないときの初期値。既定の`.accent`(多くの環境では青)
    /// から遠く、暗いサムネイルの上でも埋もれない橙にしてある。
    static let defaultThumbnailGridBorderCustomColor = RGBColorValue(red: 255, green: 149, blue: 0)

    /// 実際に枠を描くのに使う色。プリセット・カスタム・アクセントカラーの解決をここ1箇所に
    /// 集約し、表示側が場合分けを持たなくて済むようにしている(effectiveBackgroundColorと同じ考え方)。
    var effectiveCurrentPageBorderColor: Color {
        if let preset = thumbnailGridBorderColorOption.presetColor { return preset }
        // `.accent`は固定値を持たない(システム設定に追従する)ため、ここで初めてColorに解決する。
        if thumbnailGridBorderColorOption == .accent { return .accentColor }
        return thumbnailGridBorderCustomColor.color
    }

    /// ページ一覧の上でマウスホイールを1ノッチ回したときに、何行ぶんスクロールするか
    /// (ユーザー要望)。
    ///
    /// 対象は**物理マウスのホイールだけ**で、トラックパッドやMagic Mouseの滑らかな
    /// スクロールには効かせない。理由は`invertTwoFingerScrolling`が逆にトラックパッド
    /// だけを対象にしているのと同じで、両者は操作の質が違い、片方に合う値がもう片方では
    /// 極端になるため(そちらのコメント参照)。
    @Published var thumbnailGridWheelScrollRows: Double {
        didSet {
            UserDefaults.standard.set(thumbnailGridWheelScrollRows, forKey: Keys.thumbnailGridWheelScrollRows)
        }
    }
    /// 下限0.5行は「1ノッチで半行ぶんだけ動かして、行の途中を覗く」用途。上限5行は、
    /// それ以上にすると1ノッチで画面が丸ごと入れ替わり、どこを見ていたか分からなくなるため。
    ///
    /// 刻みは0.1行(ユーザー要望)。スライダーの1ステップが1pt未満になるため、
    /// 環境設定側ではスライダーにステッパーを添えてある(SettingsSlider.showsStepper参照)。
    static let thumbnailGridWheelScrollRowsRange: ClosedRange<Double> = 0.5...5

    // MARK: - すりガラスの面ごとの見た目(ユーザー要望)

    /// ページ一覧パネルの背景。
    @Published var pageListSurfaceStyle: PanelSurfaceStyle {
        didSet { Self.save(pageListSurfaceStyle, for: .pageList) }
    }
    /// ツールバーの背景(自動的に隠す設定のときに重ねて表示される帯)。
    @Published var toolbarSurfaceStyle: PanelSurfaceStyle {
        didSet { Self.save(toolbarSurfaceStyle, for: .toolbar) }
    }
    /// プログレスバーの背景(同上)。
    @Published var progressBarSurfaceStyle: PanelSurfaceStyle {
        didSet { Self.save(progressBarSurfaceStyle, for: .progressBar) }
    }
    /// サイドパネルの背景。
    @Published var sidePanelSurfaceStyle: PanelSurfaceStyle {
        didSet { Self.save(sidePanelSurfaceStyle, for: .sidePanel) }
    }
    /// 上記以外の浮かぶ表示(「情報を見る」パネル・トースト・拡大率表示)の背景。
    @Published var overlaySurfaceStyle: PanelSurfaceStyle {
        didSet { Self.save(overlaySurfaceStyle, for: .overlays) }
    }

    /// 面を指定して現在の設定を読む。環境設定「外観」画面が`PanelSurface.allCases`を
    /// そのまま並べられるようにするための窓口(4面ぶんの`if`を画面側に書かせないため)。
    func surfaceStyle(for surface: PanelSurface) -> PanelSurfaceStyle {
        switch surface {
        case .pageList: return pageListSurfaceStyle
        case .toolbar: return toolbarSurfaceStyle
        case .progressBar: return progressBarSurfaceStyle
        case .sidePanel: return sidePanelSurfaceStyle
        case .overlays: return overlaySurfaceStyle
        }
    }

    /// 面を指定して設定を書く(上の対)。
    func setSurfaceStyle(_ style: PanelSurfaceStyle, for surface: PanelSurface) {
        switch surface {
        case .pageList: pageListSurfaceStyle = style
        case .toolbar: toolbarSurfaceStyle = style
        case .progressBar: progressBarSurfaceStyle = style
        case .sidePanel: sidePanelSurfaceStyle = style
        case .overlays: overlaySurfaceStyle = style
        }
    }

    /// 面を指定したBinding。`ForEach(PanelSurface.allCases)`の中からスライダー等へ直接渡せる。
    func surfaceStyleBinding(for surface: PanelSurface) -> Binding<PanelSurfaceStyle> {
        Binding(
            get: { self.surfaceStyle(for: surface) },
            set: { self.setSurfaceStyle($0, for: surface) }
        )
    }

    private static func save(_ style: PanelSurfaceStyle, for surface: PanelSurface) {
        let defaults = UserDefaults.standard
        defaults.set(style.materialOpacity, forKey: Keys.panelSurfaceMaterialOpacity(surface))
        defaults.set(style.tintColor.hexString, forKey: Keys.panelSurfaceTintColor(surface))
        defaults.set(style.tintOpacity, forKey: Keys.panelSurfaceTintOpacity(surface))
        defaults.set(style.contentShadowLevel, forKey: Keys.panelSurfaceContentShadowLevel(surface))
    }

    /// 保存済みの設定を読む。1つでも欠けていればその項目だけ既定値で補う
    /// (面を後から増やしたときに、既存ユーザーの環境で既定値が使われるようにするため)。
    private static func loadSurfaceStyle(for surface: PanelSurface) -> PanelSurfaceStyle {
        let defaults = UserDefaults.standard
        let fallback = surface.defaultStyle
        let materialOpacity =
            defaults.object(forKey: Keys.panelSurfaceMaterialOpacity(surface)) as? Double
            ?? fallback.materialOpacity
        let tintColor =
            (defaults.string(forKey: Keys.panelSurfaceTintColor(surface)).flatMap(RGBColorValue.init(hexString:)))
            ?? fallback.tintColor
        let tintOpacity =
            defaults.object(forKey: Keys.panelSurfaceTintOpacity(surface)) as? Double
            ?? fallback.tintOpacity
        let contentShadowLevel =
            defaults.object(forKey: Keys.panelSurfaceContentShadowLevel(surface)) as? Int
            ?? fallback.contentShadowLevel
        return PanelSurfaceStyle(
            materialOpacity: materialOpacity, tintColor: tintColor, tintOpacity: tintOpacity,
            contentShadowLevel: contentShadowLevel
        )
    }

    // MARK: - シークレットウインドウを既定にする(ユーザー要望)

    /// 本を開くすべての経路 ― アプリの通常起動、Finderからのダブルクリック、Dockアイコンへの
    /// ドラッグ&ドロップ、ウェルカム画面へのドロップ、「開く…」パネル ― で、既定で
    /// シークレットウインドウとして開くかどうか。
    ///
    /// ONにしても「シークレットウインドウとは何か」は変わらない(AppState.isPrivateWindowの
    /// コメントが引き続き正典)。変わるのは**どちらが既定か**だけで、記録の残る通常の
    /// ウインドウは File › 「新規ノーマルウインドウ」から明示的に開く。
    ///
    /// この値はLaunchCoordinator/ContentViewなど、AppPreferencesを@EnvironmentObjectとして
    /// 受け取れない箇所からも読む必要があるため、UserDefaultsのキーを`static`で公開し、
    /// `isEnabledInUserDefaults`から直接読めるようにしてある
    /// (RecentFilesStore.maxCountが同じ理由で直接UserDefaultsを読んでいるのと同じ)。
    @Published var launchInPrivateMode: Bool {
        didSet { UserDefaults.standard.set(launchInPrivateMode, forKey: Keys.launchInPrivateMode) }
    }

    /// 上の値を、AppPreferencesのインスタンスを持たない箇所(ContentViewのinit、
    /// LaunchCoordinator、AppDelegate)から読むための窓口。
    static var isPrivateModeDefault: Bool {
        UserDefaults.standard.bool(forKey: Keys.launchInPrivateMode)
    }

    // MARK: - サムネイルのホバー拡大プレビュー(ページ一覧・サイドパネル・ブックマーク編集・書き出し共通)

    /// ページ一覧のサムネイルにカーソルを合わせたとき拡大プレビュー(ポップオーバー)を出すか。
    /// OFFにしたい、というユーザー要望。**ページ一覧だけ**に効く。サイドパネルのページモード・
    /// ブックマーク編集・書き出しウインドウの同種のプレビューには効かせない(それらのサムネイルは
    /// サイズ調整が無く、拡大が無いと何のページか分からなくなるため。ユーザー指示)。
    @Published var showThumbnailHoverPreview: Bool {
        didSet { UserDefaults.standard.set(showThumbnailHoverPreview, forKey: Keys.showThumbnailHoverPreview) }
    }
    /// ホバー開始からプレビューを出すまでの時間(秒)。こちらはページ一覧・サイドパネル・
    /// ブックマーク編集・書き出しウインドウのすべてで共通。以前は各所で350msの定数をコピー
    /// していた(通り抜けるだけの動きで次々開くのを避けるための遅延。0でも可)。
    @Published var thumbnailHoverPreviewDelay: Double {
        didSet { UserDefaults.standard.set(thumbnailHoverPreviewDelay, forKey: Keys.thumbnailHoverPreviewDelay) }
    }
    static let thumbnailHoverPreviewDelayRange: ClosedRange<Double> = 0...1
    /// 上の遅延をTask.sleep用のナノ秒で返す。
    var thumbnailHoverPreviewDelayNanoseconds: UInt64 {
        UInt64(max(thumbnailHoverPreviewDelay, 0) * 1_000_000_000)
    }
    /// 拡大プレビュー(ポップオーバー)の一辺の長さ(pt)。画像はこの正方形へ縦横比を保って
    /// 収められ、下のファイル名もこの幅で折り返す。遅延と同じく**4箇所すべてで共通**
    /// (ページ一覧・サイドパネルのページモード・ブックマーク/レイアウトの編集・書き出し
    /// ウインドウ)。以前は4箇所それぞれに440という数値を直接書いていた(ユーザー要望で
    /// 設定にした。既定値はそのときの値をそのまま引き継いでいる)。
    ///
    /// 表示の大きさを決める値。プレビュー用の画像はこの大きさ(×画面の倍率)でデコードする
    /// (thumbnailHoverPreviewPixelSize参照)ので、大きくするとデコードの負荷とメモリは
    /// そのぶん増える(原寸を読んでいた頃よりはどちらも大幅に小さい)。
    @Published var thumbnailHoverPreviewSize: Double {
        didSet { UserDefaults.standard.set(thumbnailHoverPreviewSize, forKey: Keys.thumbnailHoverPreviewSize) }
    }
    /// 下限を既定値(440pt)と同じにしてあるのは、**サムネイルより小さいプレビューを
    /// 作らせないため**(ユーザーの指示)。ページ一覧のサムネイルは最大320ptまで大きくでき、
    /// 下限をそれより下に許すと「拡大プレビューのほうが小さい」という逆転が起きる
    /// (AppPreferences.thumbnailGridCellSizeRangeの上限参照)。
    static let thumbnailHoverPreviewSizeRange: ClosedRange<Double> = 440...800
    /// 上をレイアウトでそのまま使えるCGFloatとして返す。**表示側はこちらを使うこと** ――
    /// 保存値が範囲外でも(古い値・手動で書き換えられた場合)画面が壊れないよう、ここで
    /// 範囲に収める。
    var thumbnailHoverPreviewSideLength: CGFloat {
        let range = Self.thumbnailHoverPreviewSizeRange
        return CGFloat(min(max(thumbnailHoverPreviewSize, range.lowerBound), range.upperBound))
    }
    /// 拡大プレビューの画像をデコードする解像度(長辺のピクセル数)。
    ///
    /// 以前はプレビューにもページ本体と同じ原寸(4096px上限)の画像を使っていた。440〜800ptの
    /// 枠に原寸は過剰で、1枚あたり最大47MB(4233×6050の本)をプレビューのためだけに抱え、
    /// 「表示中のサムネイルの拡大画像を先読み」をONにすると画面内のセルの数だけそれが
    /// 並び、読書用のページキャッシュまで押し出していた。枠の大きさ×画面の倍率で
    /// デコードすれば、Retinaでも等倍以上の画素があり見た目は変わらない(最大1600px、7MB)。
    /// 接続中の画面のうち最も倍率の高いものに合わせる(どの画面へ動かしてもぼやけないように)。
    var thumbnailHoverPreviewPixelSize: CGFloat {
        let maxScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return (thumbnailHoverPreviewSideLength * max(maxScale, 1)).rounded(.up)
    }
    /// ページ一覧で、画面に見えているサムネイルの原寸画像を裏で先にデコードしておくか
    /// (プレビューを即座に出すため。メモリとCPUを多く使うので既定OFF)。
    @Published var preloadThumbnailGridPreviews: Bool {
        didSet { UserDefaults.standard.set(preloadThumbnailGridPreviews, forKey: Keys.preloadThumbnailGridPreviews) }
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
        self.maxPinchZoomPercent = defaults.object(forKey: Keys.maxPinchZoomPercent) as? Double ?? 400
        self.loupeMagnificationPercent =
            defaults.object(forKey: Keys.loupeMagnificationPercent) as? Double ?? 250
        self.loupeDiameter = defaults.object(forKey: Keys.loupeDiameter) as? Double ?? 400
        self.interpolationQuality = InterpolationQuality(rawValue: defaults.string(forKey: Keys.interpolationQuality) ?? "") ?? .high
        self.autoHideCursor = defaults.object(forKey: Keys.autoHideCursor) as? Bool ?? true
        self.slideshowInterval = defaults.object(forKey: Keys.slideshowInterval) as? Double ?? 5
        self.defaultScalingMode = ScalingMode(rawValue: defaults.string(forKey: Keys.defaultScalingMode) ?? "") ?? .fitToScreen
        self.treatTrackpadFlickAsWheel = defaults.object(forKey: Keys.treatTrackpadFlickAsWheel) as? Bool ?? true
        self.invertTwoFingerScrolling = defaults.object(forKey: Keys.invertTwoFingerScrolling) as? Bool ?? false
        self.quitWhenLastWindowClosed = defaults.object(forKey: Keys.quitWhenLastWindowClosed) as? Bool ?? false
        self.singlePageAspectRatioThreshold =
            defaults.object(forKey: Keys.singlePageAspectRatioThreshold) as? Double ?? 1.0
        self.backgroundColorOption =
            BackgroundColorOption(rawValue: defaults.string(forKey: Keys.backgroundColorOption) ?? "") ?? .black
        self.customBackgroundColor =
            RGBColorValue(hexString: defaults.string(forKey: Keys.customBackgroundColor) ?? "")
            ?? Self.defaultCustomBackgroundColor
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
        self.folderBrowserSortKey =
            FolderBrowserSortKey(rawValue: defaults.string(forKey: Keys.folderBrowserSortKey) ?? "")
                ?? FolderBrowserSort.default.key
        self.folderBrowserSortDirection =
            FolderBrowserSortDirection(rawValue: defaults.string(forKey: Keys.folderBrowserSortDirection) ?? "")
                ?? FolderBrowserSort.default.direction
        self.siblingNavigationFollowsBrowserSort =
            defaults.object(forKey: Keys.siblingNavigationFollowsBrowserSort) as? Bool ?? false
        self.sidePanelPosition =
            SidePanelPosition(rawValue: defaults.string(forKey: Keys.sidePanelPosition) ?? "") ?? .left
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
        self.thumbnailGridCellSize = defaults.object(forKey: Keys.thumbnailGridCellSize) as? Double ?? 120
        self.thumbnailGridHorizontalSpacing =
            defaults.object(forKey: Keys.thumbnailGridHorizontalSpacing) as? Double ?? 10
        self.thumbnailGridVerticalSpacing =
            defaults.object(forKey: Keys.thumbnailGridVerticalSpacing) as? Double ?? 10
        self.thumbnailGridHorizontalMarginPercent =
            defaults.object(forKey: Keys.thumbnailGridHorizontalMarginPercent) as? Double ?? 10
        self.thumbnailGridVerticalMarginPercent =
            defaults.object(forKey: Keys.thumbnailGridVerticalMarginPercent) as? Double ?? 5
        self.showThumbnailHoverPreview = defaults.object(forKey: Keys.showThumbnailHoverPreview) as? Bool ?? true
        self.thumbnailHoverPreviewDelay = defaults.object(forKey: Keys.thumbnailHoverPreviewDelay) as? Double ?? 0.35
        // 既定値440は、設定にする前に各所へ直接書かれていた値そのもの(見た目を変えないため)。
        self.thumbnailHoverPreviewSize = defaults.object(forKey: Keys.thumbnailHoverPreviewSize) as? Double ?? 440
        self.preloadThumbnailGridPreviews =
            defaults.object(forKey: Keys.preloadThumbnailGridPreviews) as? Bool ?? false
        self.thumbnailGridCaptionStyle =
            ThumbnailCaptionStyle(rawValue: defaults.string(forKey: Keys.thumbnailGridCaptionStyle) ?? "")
            ?? .pageNumber
        self.thumbnailGridCaptionFontSize =
            defaults.object(forKey: Keys.thumbnailGridCaptionFontSize) as? Double ?? 11
        self.thumbnailGridBorderColorOption =
            PageBorderColorOption(rawValue: defaults.string(forKey: Keys.thumbnailGridBorderColorOption) ?? "")
            ?? .accent
        self.thumbnailGridBorderCustomColor =
            defaults.string(forKey: Keys.thumbnailGridBorderCustomColor).flatMap(RGBColorValue.init(hexString:))
            ?? Self.defaultThumbnailGridBorderCustomColor
        self.thumbnailGridWheelScrollRows =
            defaults.object(forKey: Keys.thumbnailGridWheelScrollRows) as? Double ?? 1
        self.pageListSurfaceStyle = Self.loadSurfaceStyle(for: .pageList)
        self.toolbarSurfaceStyle = Self.loadSurfaceStyle(for: .toolbar)
        self.progressBarSurfaceStyle = Self.loadSurfaceStyle(for: .progressBar)
        self.sidePanelSurfaceStyle = Self.loadSurfaceStyle(for: .sidePanel)
        self.overlaySurfaceStyle = Self.loadSurfaceStyle(for: .overlays)
        self.launchInPrivateMode = defaults.object(forKey: Keys.launchInPrivateMode) as? Bool ?? false
        self.thumbnailDiskCacheEnabled =
            defaults.object(forKey: Keys.thumbnailDiskCacheEnabled) as? Bool ?? false
        self.thumbnailDiskCacheLimitMB =
            defaults.object(forKey: Keys.thumbnailDiskCacheLimitMB) as? Double
            ?? Self.defaultThumbnailDiskCacheLimitMB
        self.pageImageCacheLimitMB =
            defaults.object(forKey: Keys.pageImageCacheLimitMB) as? Double
            ?? Self.defaultPageImageCacheLimitMB

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

        // すべてのプロパティが揃ってから、サムネイルのディスクキャッシュへ設定を届ける
        // (didSetは初期化中には走らないので、ここで一度だけ明示的に呼ぶ必要がある)。
        // OFF(既定)ならこの呼び出しが、溜まっているキャッシュの削除の合図にもなる。
        applyThumbnailDiskCacheSettings()
    }
}


// MARK: - 画面ごとの「初期設定に戻す」(ユーザー要望)

extension AppPreferences {
    /// 環境設定の1画面ぶんの設定を、出荷時の既定値へ戻す。
    ///
    /// ■ 既定値をここに書かないための作り
    /// 「その画面が使っているUserDefaultsのキーをすべて消す」→「もう1つAppPreferencesを作る」
    /// →「その画面ぶんのプロパティだけコピーする」という順で行う。キーを消した状態で作った
    /// インスタンスは、`init()`の`?? 既定値`の側を通るため、**出荷時の既定値そのもの**を持つ。
    ///
    /// こうしているのは、既定値の literal が`init()`とここの2箇所に散らばるのを避けるため。
    /// 2箇所に書くと、既定値を変えたときに片方だけ直して「初期設定に戻したのに初期設定に
    /// ならない」という、気づきにくいずれが生まれる。既定値の定義は`init()`が唯一の正典で、
    /// ここは「どのキーがどの画面のものか」だけを知っている。
    ///
    /// 【メンテナンス上の注意】設定を1つ増やしたら、`keys(for:)`と`apply(_:for:)`の**両方**へ
    /// 足すこと。足し忘れても値が壊れることはないが、その項目だけ初期設定に戻らなくなる。
    /// ただし**保存済みのデータを捨てる副作用を持つ設定は、意図的に対象外にする**
    /// (`keys(for:)`の「対象外にしている設定」参照)。
    ///
    /// キー・マウスの割り当て(`keyboard`/`mouse`/`modeInput`)はAppPreferencesではなく
    /// KeyBindingStoreが持つため、ここでは何もしない(各画面が自分でstore側を呼ぶ)。
    /// 「フォルダのアクセス権」「リセット」には戻すべき設定が無い(ユーザー要望により
    /// この2画面にはボタン自体を置かない)。
    func resetToDefaults(_ pane: SettingsPane) {
        let keys = Self.keys(for: pane)
        guard !keys.isEmpty else { return }
        let defaults = UserDefaults.standard
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        apply(AppPreferences(), for: pane)
    }

    /// その画面が読み書きするUserDefaultsのキー。
    ///
    /// **その画面に実際に並んでいる項目だけ**を対象にする。表示・非表示の状態
    /// (hideToolbar/hideSidePanelなど)やサイドパネルの幅・モード、フォルダブラウザの並べ替えは、
    /// 「表示」メニューやパネル自身のボタンで変える値で、環境設定の画面には無いため含めない。
    /// 「この画面を初期設定に戻す」が、画面に見えていない設定まで巻き込むのは予想を裏切る。
    ///
    /// ■ 対象外にしている設定(画面には並んでいるが、あえて戻さないもの)
    /// 「一般」の**保管件数の2つ** ―― `maxTrackedBooksCount`(本ごとのデータを残す冊数)と
    /// `recentFilesLimit`(履歴の保持件数)は、値を下げると**保存済みのデータがその場で消える**。
    ///   ・maxTrackedBooksCount … 次に新しい本を開いた時点でLibraryDataPrunerが、上限を超えた
    ///     ぶんのBookReadingState(最後に読んだページと本ごとの表示設定)を古い順に削除する
    ///   ・recentFilesLimit … didSetの通知でRecentFilesStoreがその場で履歴を切り詰めて保存する
    /// どちらも取り消せない。この2つを戻すと、確認ダイアログも無いボタン1つで
    /// 「例えば2000冊 → 500冊」の削除が起きることになり、ボタンの説明文の
    /// 「お気に入り・ブックマーク・読書履歴には影響しません」とも食い違う。
    /// **「設定を戻す」操作でユーザーのデータを捨ててはいけない**ので、この2つは戻さない
    /// (どちらもスライダーなので、戻したければその場で既定値へ動かせる)。
    private static func keys(for pane: SettingsPane) -> [String] {
        switch pane {
        case .general:
            return [
                Keys.displayLanguage,
                Keys.launchOpensLastBook,
                Keys.launchFullScreen,
                Keys.launchInPrivateMode,
                Keys.quitWhenLastWindowClosed,
                Keys.confirmBeforeClosingMultipleTabsWindow,
                // maxTrackedBooksCount / recentFilesLimit は意図的に含めない(上のコメント参照)。
                Keys.showRecentFilesOnWelcome,
                Keys.showRecentFavoritesOnWelcome,
                Keys.sidePanelFeatureEnabled,
                Keys.sidePanelPosition,
                Keys.sidePanelUsesDoubleClick,
                Keys.sidePanelSortOrder,
                Keys.siblingNavigationFollowsBrowserSort,
            ]
        case .appearance:
            return [
                Keys.backgroundColorOption,
                Keys.customBackgroundColor,
                Keys.thumbnailGridCellSize,
                Keys.thumbnailGridHorizontalSpacing,
                Keys.thumbnailGridVerticalSpacing,
                Keys.thumbnailGridHorizontalMarginPercent,
                Keys.thumbnailGridVerticalMarginPercent,
                Keys.thumbnailGridCaptionStyle,
                Keys.thumbnailGridCaptionFontSize,
                Keys.thumbnailGridBorderColorOption,
                Keys.thumbnailGridBorderCustomColor,
                // 拡大プレビューのON/OFFは、画面上も「外観」→「ページ一覧」にある
                // (ページ一覧にしか効かないため)。**画面の置き場所とここは必ず揃えること** ――
                // 食い違うと、その画面の「初期設定に戻す」で戻らない項目や、別の画面のボタンで
                // 勝手に戻る項目が生まれる。先読み(preloadThumbnailGridPreviews)は
                // 「キャッシュ」画面へ移した(下のcase .cache参照)。
                Keys.showThumbnailHoverPreview,
                // ホイールのスクロール行数もページ一覧パネル専用なので、画面ごと
                // こちらへ移してある(ユーザーの指示)。
                Keys.thumbnailGridWheelScrollRows,
            ] + PanelSurface.allCases.flatMap {
                // 面ごとの設定を1つ増やしたら**ここにも足すこと**。`apply`が渡す
                // `AppPreferences()`はUserDefaultsから読み直すので、キーを消し忘れると
                // 古い値がそのまま戻ってきて「初期設定に戻す」が効かない
                // (ユーザー報告: 「文字の影」だけリセットされない)。
                [
                    Keys.panelSurfaceMaterialOpacity($0),
                    Keys.panelSurfaceTintColor($0),
                    Keys.panelSurfaceTintOpacity($0),
                    Keys.panelSurfaceContentShadowLevel($0),
                ]
            }
        case .opening:
            return [
                Keys.reopenBehavior,
                Keys.finderOpenBehavior,
                Keys.favoriteOpenBehavior,
                Keys.spreadBookmarkTargetBehavior,
            ]
        case .rendering:
            return [
                Keys.defaultScalingMode,
                Keys.maxUpscalePercent,
                Keys.maxPinchZoomPercent,
                Keys.interpolationQuality,
                Keys.loupeMagnificationPercent,
                Keys.loupeDiameter,
                Keys.singlePageAspectRatioThreshold,
                // prefetchPageCountは「キャッシュ」画面へ移した(下のcase .cache参照)。
            ]
        case .reading:
            return [
                Keys.loopBehavior,
                Keys.treatTrackpadFlickAsWheel,
                Keys.invertTwoFingerScrolling,
                Keys.showProgressBarThumbnailPreview,
                // プレビューの遅延と大きさは4箇所すべてに共通なので、こちらの画面に残る
                // (ページ一覧パネル専用のものは「外観」側。すぐ上のコメント参照)。
                Keys.thumbnailHoverPreviewDelay,
                Keys.thumbnailHoverPreviewSize,
                Keys.slideshowInterval,
                Keys.autoHideCursor,
                Keys.cursorAutoHideDelay,
            ]
        case .cache:
            return [
                Keys.pageImageCacheLimitMB,
                Keys.prefetchPageCount,
                Keys.preloadThumbnailGridPreviews,
                Keys.thumbnailDiskCacheEnabled,
                // 上限を下げても消えるのは再生成できるサムネイルだけなので、保管件数の2つ
                // (maxTrackedBooksCount/recentFilesLimit)と違って対象に含めてよい。
                Keys.thumbnailDiskCacheLimitMB,
            ]
        case .keyboard, .mouse, .modeInput, .access, .reset:
            return []
        }
    }

    /// 既定値だけを持つインスタンス(`source`)から、その画面ぶんのプロパティを取り込む。
    /// 代入によって各プロパティの`didSet`が走り、既定値がUserDefaultsへ書き戻される。
    private func apply(_ source: AppPreferences, for pane: SettingsPane) {
        switch pane {
        case .general:
            displayLanguage = source.displayLanguage
            launchOpensLastBook = source.launchOpensLastBook
            launchFullScreen = source.launchFullScreen
            launchInPrivateMode = source.launchInPrivateMode
            quitWhenLastWindowClosed = source.quitWhenLastWindowClosed
            confirmBeforeClosingMultipleTabsWindow = source.confirmBeforeClosingMultipleTabsWindow
            // maxTrackedBooksCount / recentFilesLimit は意図的に戻さない(keys(for:)のコメント参照)。
            showRecentFilesOnWelcome = source.showRecentFilesOnWelcome
            showRecentFavoritesOnWelcome = source.showRecentFavoritesOnWelcome
            sidePanelFeatureEnabled = source.sidePanelFeatureEnabled
            sidePanelPosition = source.sidePanelPosition
            sidePanelUsesDoubleClick = source.sidePanelUsesDoubleClick
            sidePanelSortOrder = source.sidePanelSortOrder
            siblingNavigationFollowsBrowserSort = source.siblingNavigationFollowsBrowserSort
        case .appearance:
            backgroundColorOption = source.backgroundColorOption
            customBackgroundColor = source.customBackgroundColor
            thumbnailGridCellSize = source.thumbnailGridCellSize
            thumbnailGridHorizontalSpacing = source.thumbnailGridHorizontalSpacing
            thumbnailGridVerticalSpacing = source.thumbnailGridVerticalSpacing
            thumbnailGridHorizontalMarginPercent = source.thumbnailGridHorizontalMarginPercent
            thumbnailGridVerticalMarginPercent = source.thumbnailGridVerticalMarginPercent
            thumbnailGridCaptionStyle = source.thumbnailGridCaptionStyle
            thumbnailGridCaptionFontSize = source.thumbnailGridCaptionFontSize
            thumbnailGridBorderColorOption = source.thumbnailGridBorderColorOption
            thumbnailGridBorderCustomColor = source.thumbnailGridBorderCustomColor
            showThumbnailHoverPreview = source.showThumbnailHoverPreview
            thumbnailGridWheelScrollRows = source.thumbnailGridWheelScrollRows
            for surface in PanelSurface.allCases {
                setSurfaceStyle(source.surfaceStyle(for: surface), for: surface)
            }
        case .opening:
            reopenBehavior = source.reopenBehavior
            finderOpenBehavior = source.finderOpenBehavior
            favoriteOpenBehavior = source.favoriteOpenBehavior
            spreadBookmarkTargetBehavior = source.spreadBookmarkTargetBehavior
        case .rendering:
            defaultScalingMode = source.defaultScalingMode
            maxUpscalePercent = source.maxUpscalePercent
            maxPinchZoomPercent = source.maxPinchZoomPercent
            interpolationQuality = source.interpolationQuality
            loupeMagnificationPercent = source.loupeMagnificationPercent
            loupeDiameter = source.loupeDiameter
            singlePageAspectRatioThreshold = source.singlePageAspectRatioThreshold
        case .reading:
            loopBehavior = source.loopBehavior
            treatTrackpadFlickAsWheel = source.treatTrackpadFlickAsWheel
            invertTwoFingerScrolling = source.invertTwoFingerScrolling
            showProgressBarThumbnailPreview = source.showProgressBarThumbnailPreview
            thumbnailHoverPreviewDelay = source.thumbnailHoverPreviewDelay
            thumbnailHoverPreviewSize = source.thumbnailHoverPreviewSize
            slideshowInterval = source.slideshowInterval
            autoHideCursor = source.autoHideCursor
            cursorAutoHideDelay = source.cursorAutoHideDelay
        case .cache:
            pageImageCacheLimitMB = source.pageImageCacheLimitMB
            prefetchPageCount = source.prefetchPageCount
            preloadThumbnailGridPreviews = source.preloadThumbnailGridPreviews
            thumbnailDiskCacheEnabled = source.thumbnailDiskCacheEnabled
            thumbnailDiskCacheLimitMB = source.thumbnailDiskCacheLimitMB
        case .keyboard, .mouse, .modeInput, .access, .reset:
            break
        }
    }
}
