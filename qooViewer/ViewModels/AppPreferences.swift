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
        static let firstPageBehavior = "qooViewer.pref.firstPageBehavior"
        static let lastPageBehavior = "qooViewer.pref.lastPageBehavior"
        /// 最初/最後のページで共通だった頃の旧キー。init()の移行処理でだけ読み、
        /// 読んだ時点で削除する(下のmigrateLoopBehaviorIfNeeded参照)。
        static let legacyLoopBehavior = "qooViewer.pref.loopBehavior"
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
        static let toolbarRevealDelay = "qooViewer.pref.toolbarRevealDelay"
        static let progressBarRevealDelay = "qooViewer.pref.progressBarRevealDelay"
        static let sidePanelRevealDelay = "qooViewer.pref.sidePanelRevealDelay"
        static let toolbarDockedGlass = "qooViewer.pref.toolbarDockedGlass"
        static let progressBarDockedGlass = "qooViewer.pref.progressBarDockedGlass"
        static let sidePanelDockedGlass = "qooViewer.pref.sidePanelDockedGlass"
        static let welcomeGlass = "qooViewer.pref.welcomeGlass"
        static let prefetchPageCount = "qooViewer.pref.prefetchPageCount"
        static let displayLanguage = AppLanguage.defaultsKey
        static let appAppearance = "qooViewer.pref.appAppearance"
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
        /// キーの実体はPageOrder側にある。nonisolatedなコード(BookLoaderなど)が同じ値を
        /// 読むため、文字列を2か所に書かない(PageOrder.defaultsKeyのコメント参照)。
        static let usesFinderSortOrder = PageOrder.defaultsKey
        static let folderBrowserSortKey = "qooViewer.pref.folderBrowserSortKey"
        static let folderBrowserSortDirection = "qooViewer.pref.folderBrowserSortDirection"
        static let siblingNavigationFollowsBrowserSort = "qooViewer.pref.siblingNavigationFollowsBrowserSort"
        static let sidePanelPosition = "qooViewer.pref.sidePanelPosition"
        static let sidePanelMode = "qooViewer.pref.sidePanelMode"
        static let showProgressBarThumbnailPreview = "qooViewer.pref.showProgressBarThumbnailPreview"
        /// プログレスバーのフィルムストリップの見た目(ユーザー要望)。上のON/OFFと同じく
        /// 環境設定「外観」の「プログレスバーのフィルムストリップ」セクションに並ぶ。
        static let filmstripThumbnailCount = "qooViewer.pref.filmstripThumbnailCount"
        static let filmstripFontSize = "qooViewer.pref.filmstripFontSize"
        static let filmstripCaptionStyle = "qooViewer.pref.filmstripCaptionStyle"
        static let filmstripDimsOtherPages = "qooViewer.pref.filmstripDimsOtherPages"
        static let filmstripHighlightColorOption = "qooViewer.pref.filmstripHighlightColorOption"
        static let filmstripHighlightCustomColor = "qooViewer.pref.filmstripHighlightCustomColor"
        static let filmstripHighlightBorderWidth = "qooViewer.pref.filmstripHighlightBorderWidth"
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
        static let nestedArchiveMemoryLimitMB = "qooViewer.pref.nestedArchiveMemoryLimitMB"
        static let missingLayoutAutoLayout = "qooViewer.pref.missingLayoutAutoLayout"
        static let bookExportCompletionBehavior = "qooViewer.pref.bookExportCompletionBehavior"

        /// 書き出しの形式ごとの設定(BookExportFormat参照)。形式の識別子ごとに3つのキーへ
        /// 分かれる。形式を1つ増やしてもここは触らなくてよい(allCasesから導出される)。
        /// 固定の保存先フォルダ自体はブックマーク(Data)なので、ここではなく
        /// LastUsedFolderMemory.fixedExportFolder(_:)が持つ。
        static func bookExportDestinationMode(_ format: BookExportFormat) -> String {
            "qooViewer.pref.bookExport.\(format.rawValue).destinationMode"
        }
        static func bookExportDataCleanup(_ format: BookExportFormat) -> String {
            "qooViewer.pref.bookExport.\(format.rawValue).dataCleanup"
        }
        static func bookExportHistoryCleanup(_ format: BookExportFormat) -> String {
            "qooViewer.pref.bookExport.\(format.rawValue).historyCleanup"
        }
        static func bookExportRenumbersImages(_ format: BookExportFormat) -> String {
            "qooViewer.pref.bookExport.\(format.rawValue).renumbersImages"
        }
        static func bookExportIncludesExcludedPages(_ format: BookExportFormat) -> String {
            "qooViewer.pref.bookExport.\(format.rawValue).includesExcludedPages"
        }
        /// CBZ専用の項目なので、形式ごとのキーにはしない(ComicInfo.xmlのVolume要素の話で、
        /// EPUB/PDFには対応する概念が無い。CbzExportOptions.writesVolumeElement参照)。
        static let bookExportWritesVolumeElement = "qooViewer.pref.bookExport.cbz.writesVolumeElement"

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
    /// 最初のページで「前のページへ」の操作をしたときの挙動(FirstPageBehavior参照)
    @Published var firstPageBehavior: FirstPageBehavior {
        didSet { UserDefaults.standard.set(firstPageBehavior.rawValue, forKey: Keys.firstPageBehavior) }
    }
    /// 最後のページで「次のページへ」の操作をしたときの挙動(LastPageBehavior参照)
    @Published var lastPageBehavior: LastPageBehavior {
        didSet { UserDefaults.standard.set(lastPageBehavior.rawValue, forKey: Keys.lastPageBehavior) }
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
    /// 環境設定「外観」の「ビューア」→「背景色」で「カスタム」を選ぶと開くダイアログ
    /// (CustomColorPickerSheet)で編集する。
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
    /// 自動隠し中のツールバーを、カーソルをウインドウの端へ近づけてから実際に表示するまでの
    /// 待ち時間(秒)。既定は0=これまでどおり即座に表示する。
    ///
    /// ユーザー要望: 別のウインドウやメニューバーへカーソルを動かしたいだけなのに、通りすがりで
    /// 隠していた部分が反応するのが鬱陶しいことがある。待っている間にカーソルを端から離せば
    /// 表示されないままになる(ViewerView.scheduleToolbarReveal参照)。
    ///
    /// 待ち時間はツールバー・プログレスバー・サイドパネルで**別々に**持つ(ユーザー要望)。
    /// ツールバーとプログレスバーは従来どおり「上端/下端どちらの帯でも両方が対象」という
    /// 同じきっかけで表示されるが、そこから何秒待つかだけがこの3つの値で決まる。
    ///
    /// 環境設定の画面上は「外観」の面ごとのセクション(ツールバー/プログレスバー/サイドパネル)に
    /// あり、リセットの担当もそちらの画面になる(keys(for:)の.appearance参照。**画面の置き場所と
    /// keys(for:)は必ず揃えること**)。
    @Published var toolbarRevealDelay: Double {
        didSet { UserDefaults.standard.set(toolbarRevealDelay, forKey: Keys.toolbarRevealDelay) }
    }
    /// プログレスバー側の同じもの(toolbarRevealDelay参照)。
    @Published var progressBarRevealDelay: Double {
        didSet { UserDefaults.standard.set(progressBarRevealDelay, forKey: Keys.progressBarRevealDelay) }
    }
    /// サイドパネル側の同じもの(toolbarRevealDelay参照)。こちらのきっかけは左右どちらかの
    /// 端の帯(ContentView.updateSidePanelReveal参照)。
    @Published var sidePanelRevealDelay: Double {
        didSet { UserDefaults.standard.set(sidePanelRevealDelay, forKey: Keys.sidePanelRevealDelay) }
    }
    /// 隠していない(常に表示の)状態のツールバーにも、ウインドウの背後(デスクトップ/
    /// 他のウインドウ)がうっすら透けるすりガラスを敷くかどうか。
    ///
    /// **既定はOFF** ―― 従来からのユーザーが設定を変更しなければ、見た目が1ピクセルも
    /// 変わらないようにするため(ユーザーの指定。面ごとの設定の既定値と同じ方針)。
    /// OFFのときの常時表示側は従来どおりの見た目 ―― ツールバー/プログレスバーは
    /// 色の層だけ(重ね色の設定は従来から常時表示にも効いていたので、それはOFFでも効く)、
    /// サイドパネルはウインドウ内をぼかすサイドバーのすりガラス。
    /// 自動的に隠す設定で画像の上に浮かべる帯/パネルには、この設定は関係しない。
    @Published var toolbarDockedGlass: Bool {
        didSet { UserDefaults.standard.set(toolbarDockedGlass, forKey: Keys.toolbarDockedGlass) }
    }
    /// プログレスバー側の同じもの(toolbarDockedGlass参照)。
    @Published var progressBarDockedGlass: Bool {
        didSet { UserDefaults.standard.set(progressBarDockedGlass, forKey: Keys.progressBarDockedGlass) }
    }
    /// サイドパネル側の同じもの(toolbarDockedGlass参照)。
    @Published var sidePanelDockedGlass: Bool {
        didSet { UserDefaults.standard.set(sidePanelDockedGlass, forKey: Keys.sidePanelDockedGlass) }
    }
    /// ウェルカム画面版の同じもの(toolbarDockedGlass参照。既定OFFの理由も同じ)。
    /// ウェルカム画面には「隠す」状態が無いので、これは画面全体のすりガラス
    /// (と面の設定一式)を使うかどうかのスイッチになる。OFFなら従来どおり、
    /// ウインドウの地の色のまま何も敷かない(WelcomeView参照)。
    @Published var welcomeGlass: Bool {
        didSet { UserDefaults.standard.set(welcomeGlass, forKey: Keys.welcomeGlass) }
    }
    /// 上の3つに共通の、指定できる範囲。0.1秒刻みで最大2秒まで(ユーザーの指定)。
    static let autoRevealDelayRange: ClosedRange<Double> = 0...2
    /// 3つの遅延をTask.sleep用のナノ秒で返す。保存値が負でも0として扱う。
    var toolbarRevealDelayNanoseconds: UInt64 { Self.revealDelayNanoseconds(toolbarRevealDelay) }
    var progressBarRevealDelayNanoseconds: UInt64 { Self.revealDelayNanoseconds(progressBarRevealDelay) }
    var sidePanelRevealDelayNanoseconds: UInt64 { Self.revealDelayNanoseconds(sidePanelRevealDelay) }
    private static func revealDelayNanoseconds(_ seconds: Double) -> UInt64 {
        UInt64(max(seconds, 0) * 1_000_000_000)
    }
    /// 現在のページの前後何ページ分を先読みするか
    @Published var prefetchPageCount: Double {
        didSet { UserDefaults.standard.set(prefetchPageCount, forKey: Keys.prefetchPageCount) }
    }
    /// アプリの表示言語(既定は「システムに従う」)
    @Published var displayLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(displayLanguage.rawValue, forKey: Keys.displayLanguage)
            // メニューバーなど起動中には切り替えられない部分を、次回起動から揃える
            // (AppLanguage.applyAppleLanguagesOverrideのコメント参照)。
            AppLanguage.applyAppleLanguagesOverride(for: displayLanguage)
        }
    }
    /// アプリの外観(ライト/ダーク。既定は「システムに従う」)。
    /// 表示言語と同じく、macOSのシステム設定とは独立して選べる(ユーザー要望)。
    /// 表示言語はSceneごとの`.environment(\.locale, ...)`で効かせるが、こちらはウインドウの外の
    /// AppKitのUI(ダイアログ・カラーパネル・Dockメニュー)にも効かせる必要があるため、
    /// SwiftUIではなくNSApp.appearanceで反映する(AppAppearanceApplierの型コメント参照)。
    @Published var appAppearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appAppearance.rawValue, forKey: Keys.appAppearance)
            AppAppearanceApplier.shared.apply(appAppearance)
        }
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
    /// 環境設定「一般」タブの「並び順をFinderに揃える」(既定はOFF)。ユーザー報告:
    /// `_Com-title-cover.JPG` / `Com_title_name_size_0001.JPG` / `Com-title-cover-clean.JPG`
    /// のような名前で、Finderの表示順と本のページ順が食い違い、しかも先頭の3文字が"Com"か
    /// "com"かで並びが丸ごと変わっていた。
    ///
    /// 効く先は、本のページ順(BookLoader)・サイドパネル下段の本の中身の一覧
    /// (BookInternalBrowsing)・複数の画像を1冊にまとめるときの並び
    /// (naturalOrderSortedByPath)・CBZ書き出しのComicInfoが書くページ番号(CbzExporter)。
    /// 上段のフォルダブラウザは元からFinderと同じ照合(DirectoryBrowser.compare)なので、
    /// この設定に関わらず変わらない。
    ///
    /// **このプロパティを直接読んでよいのは、環境設定画面のトグルだけ。** 実際に並べ替える
    /// 側はすべてnonisolatedなコードで、UserDefaultsから同じキーを読む
    /// (PageOrder.usesFinderOrder。他の設定のように引数で配らない理由もそこに書いてある)。
    /// ここが持つのは「画面に出すための値」と「didSetでの保存」だけ。
    @Published var usesFinderSortOrder: Bool {
        didSet {
            guard usesFinderSortOrder != oldValue else { return }
            UserDefaults.standard.set(usesFinderSortOrder, forKey: Keys.usesFinderSortOrder)
            // 開いている本・一覧をその場で並べ直させる(Notification.Name.
            // pageOrderSettingDidChange参照)。UserDefaultsへ書いた**後**に送ること ――
            // 受け取る側はPageOrder.usesFinderOrder(UserDefaults)を読んで並べ直すため。
            NotificationCenter.default.post(name: .pageOrderSettingDidChange, object: nil)
        }
    }
    /// 環境設定「一般」タブの、サイドパネル上段(フォルダブラウザ)のフォルダ・ファイルの
    /// 並び順(既定はフォルダをまとめて上に表示、Finderと同じ考え方)。DirectoryBrowserは
    /// nonisolated enum(MainActor隔離のAppPreferencesを直接読めない)のため、
    /// SidePanelBrowserStateがreload()のたびにこの値を引数として渡す。
    ///
    /// **下段(本の中身ブラウザ)には効かせない。** 以前は下段にも「フォルダを上にまとめる」
    /// だけが効いていた(名前順のほうは、下段が本のページ順で並ぶようになった時点で既に
    /// 効かなくなっていた)が、下段の役目はビューアの表示ページを追従して「本の中のどこに
    /// いるか」を示すことで、行の並びが本のページ順そのものでなければ追従の意味が薄れる。
    /// フォルダを上にまとめると、ルートの表紙画像が章フォルダの列の下へ沈むなど、ページ順と
    /// 食い違う並びになる(監査で指摘。BookInternalBrowsing.sortedEntries参照)。
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
    ///
    /// 画面上の置き場所は、環境設定「閲覧中の動作」から「外観」の
    /// 「プログレスバーのフィルムストリップ」セクションへ移してある。以下のフィルムストリップの
    /// 見た目の設定(枚数・文字の大きさ・強調)を足すにあたって、**この1つだけ別の画面に残すと
    /// 「どれがどこに効くのか分からない」**からで、ページ一覧の拡大プレビューを「外観」へ
    /// 移したときとまったく同じ理由(AppearanceSettingsView.pageListSectionのコメント参照)。
    /// keys(for:)/apply(_:for:)での担当も`.reading`から`.appearance`へ移してある。
    @Published var showProgressBarThumbnailPreview: Bool {
        didSet {
            UserDefaults.standard.set(
                showProgressBarThumbnailPreview,
                forKey: Keys.showProgressBarThumbnailPreview
            )
        }
    }

    // MARK: - プログレスバーのフィルムストリップの見た目(ユーザー要望)

    /// フィルムストリップに一度に並べるサムネイルの枚数(既定9枚)。
    ///
    /// **枚数を減らすと1枚が大きくなる**(バーの幅を均等割りするため。ProgressBarViewの
    /// cellWidth(for:)参照)ので、「サムネイルの大きさ」の設定を別に持たせてはいない ――
    /// 幅いっぱいに並べる仕組みでは、両方を独立に決めさせると必ず矛盾する
    /// (大きさを指定できても、結局は幅に収まる枚数しか置けない)。
    ///
    /// 上限15枚は、これ以上並べても1枚が数十ptになってページを見分けられなくなるため。
    /// 下限3枚は、カーソル位置の前後が1枚ずつは見えるという最低限。なお枚数を減らしすぎた
    /// ときに1枚が画面を突き抜けるほど大きくならないよう、1枚の幅には上限がある
    /// (ProgressBarView.maxCellWidth参照)。
    /// SettingsSliderがDoubleを扱うため、枚数もDoubleとして持つ(recentFilesLimitと同じ)。
    @Published var filmstripThumbnailCount: Double {
        didSet { UserDefaults.standard.set(filmstripThumbnailCount, forKey: Keys.filmstripThumbnailCount) }
    }
    static let filmstripThumbnailCountRange: ClosedRange<Double> = 3...15

    /// フィルムストリップのサムネイルに添える文字として何を出すか(FilmstripCaptionStyle参照)。
    /// 既定はこれまでどおりファイル名とページ番号の2行。
    ///
    /// 枚数を増やすとファイル名は潰れて読めなくなり、ただの帯になってしまうため、
    /// 出す情報を選べるようにした(ユーザー要望)。カーソル位置のページ番号だけは
    /// この設定に関わらず常に出す(理由はFilmstripCaptionStyleのコメント参照)。
    @Published var filmstripCaptionStyle: FilmstripCaptionStyle {
        didSet {
            UserDefaults.standard.set(filmstripCaptionStyle.rawValue, forKey: Keys.filmstripCaptionStyle)
        }
    }

    /// フィルムストリップのサムネイルに添える文字(ファイル名・ページ番号・書庫内の相対パス)の
    /// 大きさ(pt、既定10)。
    ///
    /// 既定の10ptは、設定にする前に使っていた`.caption`/`.caption2`の実寸そのもの ――
    /// macOSではこの2つはどちらも10ptなので、既定値のままなら見た目は1ピクセルも変わらない
    /// (thumbnailGridCaptionFontSizeの既定11ptと同じ考え方)。
    /// 範囲もページ一覧の「文字の大きさ」と揃えてある(片方だけ別の範囲にしない)。
    @Published var filmstripFontSize: Double {
        didSet { UserDefaults.standard.set(filmstripFontSize, forKey: Keys.filmstripFontSize) }
    }
    static let filmstripFontSizeRange: ClosedRange<Double> = 8...20

    /// カーソル位置以外のサムネイルを暗くするか(既定ON=従来どおり)。
    ///
    /// ONのときは、カーソル直下のセル**以外**の画像と文字を少し暗くして、直下のセルが
    /// 相対的に目立つようにする。暗くされたページの中身を読み取りたい場合に邪魔になる
    /// (画像そのものが暗いページでは特に)ため、OFFにできるようにした。OFFでも、
    /// カーソル直下のセルは枠・光彩・ページ番号バッジの色で区別が付く。
    @Published var filmstripDimsOtherPages: Bool {
        didSet { UserDefaults.standard.set(filmstripDimsOtherPages, forKey: Keys.filmstripDimsOtherPages) }
    }

    /// カーソル位置のサムネイルを強調する色(プリセット、または「カスタム」)。
    /// 枠線・光彩(shadow)・ページ番号バッジの3つに同じ色を使う(ProgressBarView参照)。
    ///
    /// 選択肢はページ一覧の「表示中のページの枠の色」と同じ`PageBorderColorOption`を使い回す ――
    /// 「サムネイルの中の1枚を色で示す」というまったく同じ用途で、同じ選択肢が要るため
    /// (同じ意味の列挙を2つ持つと、片方にだけ色を足したときに食い違う)。
    /// 既定の`.accent`は従来どおりシステムの強調表示の色(多くの環境では青)。
    @Published var filmstripHighlightColorOption: PageBorderColorOption {
        didSet {
            UserDefaults.standard.set(
                filmstripHighlightColorOption.rawValue, forKey: Keys.filmstripHighlightColorOption
            )
        }
    }
    /// 上が`.custom`のときに使うRGB値(thumbnailGridBorderCustomColorとまったく同じ考え方)。
    @Published var filmstripHighlightCustomColor: RGBColorValue {
        didSet {
            UserDefaults.standard.set(
                filmstripHighlightCustomColor.hexString, forKey: Keys.filmstripHighlightCustomColor
            )
        }
    }
    /// カスタムの強調色をまだ一度も指定していないときの初期値。ページ一覧の枠と同じ橙
    /// (既定の`.accent`から遠く、暗いサムネイルの上でも埋もれない色)。
    static let defaultFilmstripHighlightCustomColor = RGBColorValue(red: 255, green: 149, blue: 0)

    /// 実際に強調に使う色。プリセット・カスタム・アクセントカラーの解決をここへ集約する
    /// (effectiveCurrentPageBorderColorとまったく同じ)。
    var effectiveFilmstripHighlightColor: Color {
        if let preset = filmstripHighlightColorOption.presetColor { return preset }
        if filmstripHighlightColorOption == .accent { return .accentColor }
        return filmstripHighlightCustomColor.color
    }

    /// カーソル位置のサムネイルの枠線の太さ(pt、既定3)。強調していないセルの枠は1ptのまま。
    /// 上限8ptは、サムネイルを小さくしている(=枚数を多くしている)ときに枠だけで
    /// セルが埋まってしまわない範囲。
    @Published var filmstripHighlightBorderWidth: Double {
        didSet {
            UserDefaults.standard.set(
                filmstripHighlightBorderWidth, forKey: Keys.filmstripHighlightBorderWidth
            )
        }
    }
    static let filmstripHighlightBorderWidthRange: ClosedRange<Double> = 1...8
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
    var pageImageCacheLimitBytes: Int { Self.pageImageCacheLimitBytes(forMB: pageImageCacheLimitMB) }
    /// 上と同じ換算を、値を引数で受ける形にしたもの。`$pageImageCacheLimitMB`の購読
    /// (ViewerViewModel)が、受け取った新しい値をそのまま換算するために使う。
    ///
    /// **購読の中で`pageImageCacheLimitBytes`(プロパティ)を読んではいけない。** `@Published`の
    /// 発行はプロパティが書き換わる**前**(willSet)に行われるため、そこで読めるのは1つ前の値で、
    /// 設定と実体が常に1段ずれる(監査で指摘: 300→200と動かすと300が、次に200→100と動かすと
    /// 200がPageLoaderへ渡っていた)。
    static func pageImageCacheLimitBytes(forMB megabytes: Double) -> Int {
        let range = pageImageCacheLimitRangeMB
        let clamped = min(max(megabytes, range.lowerBound), range.upperBound)
        return Int(clamped) * 1024 * 1024
    }

    /// 入れ子になった書庫(書庫の中の書庫)を、メモリ上に置いておく合計の上限(MB、既定128)。
    ///
    /// 入れ子の書庫は「必要になったときに親から取り出す」方式で、取り出したものをしばらく
    /// 手元に置いておくと、同じ章のページを続けて読むあいだ取り出し直さずに済む
    /// (NestedArchiveResolver参照)。ここはその置き場の大きさ。
    ///
    /// zip/cbzだけがメモリに置ける。rar/7zはライブラリがファイルパスしか受け付けないため
    /// 必ず一時ファイルになる ―― が、その一時ファイルの上限もこの値から導いている
    /// (NestedArchiveResolver.Limits.standard参照)ので、この1つを動かせば両方が動く。
    /// 上限を2つ3つ並べても意味が伝わらないため、ユーザーに見せるのはこれだけにしてある。
    ///
    /// 0にすると「メモリには一切置かず、常に一時ファイルを使う」という意味になる。
    ///
    /// nonisolated: PageLoader(actor)とBookLoaderのinitの既定引数から参照されるため
    /// (defaultPageImageCacheLimitMBと同じ理由)。
    @Published var nestedArchiveMemoryLimitMB: Double {
        didSet { UserDefaults.standard.set(nestedArchiveMemoryLimitMB, forKey: Keys.nestedArchiveMemoryLimitMB) }
    }
    nonisolated static let defaultNestedArchiveMemoryLimitMB: Double = 128
    static let nestedArchiveMemoryLimitRangeMB: ClosedRange<Double> = 0...1024
    nonisolated static let defaultNestedArchiveMemoryLimitBytes =
        Int(defaultNestedArchiveMemoryLimitMB) * 1024 * 1024
    /// PageLoader/BookLoaderへ渡す形(バイト数)。
    var nestedArchiveMemoryLimitBytes: Int {
        Self.nestedArchiveMemoryLimitBytes(forMB: nestedArchiveMemoryLimitMB)
    }
    /// 値を引数で受ける版(pageImageCacheLimitBytes(forMB:)と同じ理由・同じ使い方)。
    static func nestedArchiveMemoryLimitBytes(forMB megabytes: Double) -> Int {
        let range = nestedArchiveMemoryLimitRangeMB
        let clamped = min(max(megabytes, range.lowerBound), range.upperBound)
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
    @Published var welcomeSurfaceStyle: PanelSurfaceStyle {
        didSet { Self.save(welcomeSurfaceStyle, for: .welcome) }
    }
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
        case .welcome: return welcomeSurfaceStyle
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
        case .welcome: welcomeSurfaceStyle = style
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

    // MARK: - レイアウト(環境設定「レイアウト」画面。ユーザー要望)

    /// レイアウトの保存データを持っていない本を開いたときに、本全体を自動レイアウトするか
    /// (MissingLayoutAutoLayout参照)。
    @Published var missingLayoutAutoLayout: MissingLayoutAutoLayout {
        didSet {
            UserDefaults.standard.set(missingLayoutAutoLayout.rawValue, forKey: Keys.missingLayoutAutoLayout)
        }
    }

    /// 右クリックの「本の書き出し」で、いま開いている本を書き出し終えたあとの動作
    /// (BookExportCompletionBehavior参照)。形式によらず1つの設定にしてある ――
    /// 「書き出したら次の本へ」という流れは、どの形式で書き出すかとは無関係のため。
    @Published var bookExportCompletionBehavior: BookExportCompletionBehavior {
        didSet {
            UserDefaults.standard.set(
                bookExportCompletionBehavior.rawValue, forKey: Keys.bookExportCompletionBehavior
            )
        }
    }

    /// 書き出しの形式ごとの設定3つ(保存先の決め方・保存データの扱い・履歴の扱い)。
    ///
    /// 形式(3つ)×設定(3つ)で、素直に書けば`@Published`なプロパティが9本並ぶ。すりガラスの
    /// 面ごとの設定(`surfaceStyle(for:)`)と同じく、**画面側が`allCases`をそのまま`ForEach`で
    /// 回せる**ようにするのが目的なので、実体は辞書1つにして、読み書きは下の`for:`付きの
    /// 窓口から行う。辞書ごと`@Published`にしてあるので、どの形式の値が変わっても
    /// 環境設定の画面は正しく描き直される。
    ///
    /// 未知のrawValueが保存されていた場合(将来caseを消した・改名したとき)は、読み込み時に
    /// 既定値へ落とす(`loadFormatSetting`)。
    @Published private var bookExportDestinationModes: [BookExportFormat: BookExportDestinationMode] {
        didSet { Self.saveFormatSettings(bookExportDestinationModes, key: Keys.bookExportDestinationMode) }
    }
    @Published private var bookExportDataCleanups: [BookExportFormat: BookExportCleanup] {
        didSet { Self.saveFormatSettings(bookExportDataCleanups, key: Keys.bookExportDataCleanup) }
    }
    @Published private var bookExportHistoryCleanups: [BookExportFormat: BookExportCleanup] {
        didSet { Self.saveFormatSettings(bookExportHistoryCleanups, key: Keys.bookExportHistoryCleanup) }
    }

    /// 保存先の決め方(毎回確認 / 保存先を設定)。
    func bookExportDestinationMode(for format: BookExportFormat) -> BookExportDestinationMode {
        bookExportDestinationModes[format] ?? .askEachTime
    }
    func setBookExportDestinationMode(_ mode: BookExportDestinationMode, for format: BookExportFormat) {
        bookExportDestinationModes[format] = mode
    }
    func bookExportDestinationModeBinding(for format: BookExportFormat) -> Binding<BookExportDestinationMode> {
        Binding(
            get: { self.bookExportDestinationMode(for: format) },
            set: { self.setBookExportDestinationMode($0, for: format) }
        )
    }

    /// 書き出し終わった本の保存データ(レイアウト・ブックマーク・メタデータ・読書位置)の扱い。
    func bookExportDataCleanup(for format: BookExportFormat) -> BookExportCleanup {
        bookExportDataCleanups[format] ?? .keep
    }
    func bookExportDataCleanupBinding(for format: BookExportFormat) -> Binding<BookExportCleanup> {
        Binding(
            get: { self.bookExportDataCleanup(for: format) },
            set: { self.bookExportDataCleanups[format] = $0 }
        )
    }

    /// 書き出し終わった本の履歴(「履歴」メニュー・ウェルカム画面に並ぶもの)の扱い。
    func bookExportHistoryCleanup(for format: BookExportFormat) -> BookExportCleanup {
        bookExportHistoryCleanups[format] ?? .keep
    }
    func bookExportHistoryCleanupBinding(for format: BookExportFormat) -> Binding<BookExportCleanup> {
        Binding(
            get: { self.bookExportHistoryCleanup(for: format) },
            set: { self.bookExportHistoryCleanups[format] = $0 }
        )
    }

    // MARK: - 書き出しオプションの既定値(ユーザー要望)

    /// 書き出しウインドウ・右クリックの書き出しシートの「書き出しオプション」の**開いた直後の値**。
    ///
    /// これまでオプションはウインドウを開くたびに固定の初期値(連番リネームはCBZだけON、
    /// 他はOFF)から始まり、毎回同じ設定に直す必要があった。ここで既定値を決めておけば、
    /// 書き出しのたびに触らずに済む ―― 特に固定の保存先と組み合わせて「何も尋ねずに書き出す」
    /// 使い方では、オプションを事前に決めておけないと形式ごとの調整ができない。
    ///
    /// 各画面のトグルは**この既定値から始まる、その1回限りの上書き**として残してある
    /// (BookExportViewModel.init参照)。触ってもここの既定値は変わらない。
    ///
    /// 出荷時の既定値は、この設定を入れる前の固定の初期値をそのまま引き継いでいる
    /// (CBZの連番リネームだけON。理由はCbzExportOptions.renumberImagesSequentially参照)。
    @Published private var bookExportRenumbersImages: [BookExportFormat: Bool] {
        didSet { Self.saveFormatFlags(bookExportRenumbersImages, key: Keys.bookExportRenumbersImages) }
    }
    @Published private var bookExportIncludesExcludedPages: [BookExportFormat: Bool] {
        didSet {
            Self.saveFormatFlags(bookExportIncludesExcludedPages, key: Keys.bookExportIncludesExcludedPages)
        }
    }
    /// CBZのComicInfo.xmlの`Volume`要素にも巻数を書き出すか(CBZ専用)。
    @Published var bookExportWritesVolumeElement: Bool {
        didSet {
            UserDefaults.standard.set(bookExportWritesVolumeElement, forKey: Keys.bookExportWritesVolumeElement)
        }
    }

    /// 画像ファイルを連番へリネームするか。PDF書き出しはページごとの画像ファイル名という概念を
    /// 持たないため、この値を使わない(画面にも出さない。PDFExportOptions参照)。
    func bookExportRenumbersImages(for format: BookExportFormat) -> Bool {
        bookExportRenumbersImages[format] ?? (format == .cbz)
    }
    func bookExportRenumbersImagesBinding(for format: BookExportFormat) -> Binding<Bool> {
        Binding(
            get: { self.bookExportRenumbersImages(for: format) },
            set: { self.bookExportRenumbersImages[format] = $0 }
        )
    }

    /// 除外(非表示)ページを書き出しに含めるか。
    func bookExportIncludesExcludedPages(for format: BookExportFormat) -> Bool {
        bookExportIncludesExcludedPages[format] ?? false
    }
    func bookExportIncludesExcludedPagesBinding(for format: BookExportFormat) -> Binding<Bool> {
        Binding(
            get: { self.bookExportIncludesExcludedPages(for: format) },
            set: { self.bookExportIncludesExcludedPages[format] = $0 }
        )
    }

    private static func saveFormatFlags(
        _ values: [BookExportFormat: Bool], key: (BookExportFormat) -> String
    ) {
        let defaults = UserDefaults.standard
        for format in BookExportFormat.allCases {
            guard let value = values[format] else { continue }
            defaults.set(value, forKey: key(format))
        }
    }

    private static func loadFormatFlags(
        key: (BookExportFormat) -> String, fallback: (BookExportFormat) -> Bool
    ) -> [BookExportFormat: Bool] {
        let defaults = UserDefaults.standard
        var result: [BookExportFormat: Bool] = [:]
        for format in BookExportFormat.allCases {
            result[format] = defaults.object(forKey: key(format)) as? Bool ?? fallback(format)
        }
        return result
    }

    private static func saveFormatSettings<Value: RawRepresentable>(
        _ values: [BookExportFormat: Value], key: (BookExportFormat) -> String
    ) where Value.RawValue == String {
        let defaults = UserDefaults.standard
        for format in BookExportFormat.allCases {
            guard let value = values[format] else { continue }
            defaults.set(value.rawValue, forKey: key(format))
        }
    }

    private static func loadFormatSettings<Value: RawRepresentable>(
        key: (BookExportFormat) -> String, fallback: Value
    ) -> [BookExportFormat: Value] where Value.RawValue == String {
        let defaults = UserDefaults.standard
        var result: [BookExportFormat: Value] = [:]
        for format in BookExportFormat.allCases {
            result[format] = Value(rawValue: defaults.string(forKey: key(format)) ?? "") ?? fallback
        }
        return result
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
    /// SwiftUIのView階層外(AppState・ViewerViewModelなど)で動的な文字列を組み立てるときに、
    /// `String(localized:language:)`(AppLanguage.swift)へ渡す。Foundationの
    /// `String(localized:locale:)`に渡しても翻訳は切り替わらないので注意(同initのコメント参照)。
    /// View階層内では `.environment(\.locale:)` 経由で自動的に反映されるため、通常はこちらを使う必要はない。
    var effectiveLocale: Locale {
        displayLanguage.locale
    }

    /// 最初/最後のページで共通だった旧設定(`Keys.legacyLoopBehavior`)を、前後それぞれの
    /// 新しい設定へ読み替える。既に読み替え済み(旧キーが無い)ならnilを返す。
    ///
    /// **読んだその場で旧キーを削除する**こと自体がこの処理の要。残しておくと、
    /// 「この画面を初期設定に戻す」が新しい2つのキーを消して`AppPreferences()`を作り直す
    /// (resetToDefaults参照)たびに、ここで旧設定が復活してしまい、閲覧中の動作だけ
    /// 初期設定に戻らなくなる(keys(for:)のコメントにある、面ごとの設定で実際に起きた
    /// ユーザー報告と同じ形の不具合)。
    private static func migrateLoopBehaviorIfNeeded(_ defaults: UserDefaults) {
        guard let legacy = defaults.string(forKey: Keys.legacyLoopBehavior) else { return }
        defaults.removeObject(forKey: Keys.legacyLoopBehavior)
        let migrated: (first: FirstPageBehavior, last: LastPageBehavior)
        switch legacy {
        case "loop": migrated = (.loop, .loop)
        case "nextBookFirstPage": migrated = (.previousBookLastPage, .nextBookFirstPage)
        case "nextBook": migrated = (.previousBook, .nextBook)
        default: migrated = (.none, .none)
        }
        // **プロパティへ代入するのではなくUserDefaultsへ直接書く。** init内の代入では
        // didSet(=保存)が走らないため、読み替えた値をメモリに載せるだけでは次回起動時に
        // 消えてしまう(旧キーはここで既に削除済みなので、二度と復元できない)。
        //
        // 既に新しいキーがある場合は上書きしない ―― 分離後に設定し直した値のほうが新しい。
        if defaults.string(forKey: Keys.firstPageBehavior) == nil {
            defaults.set(migrated.first.rawValue, forKey: Keys.firstPageBehavior)
        }
        if defaults.string(forKey: Keys.lastPageBehavior) == nil {
            defaults.set(migrated.last.rawValue, forKey: Keys.lastPageBehavior)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.launchOpensLastBook = defaults.object(forKey: Keys.launchOpensLastBook) as? Bool ?? false
        self.launchFullScreen = defaults.object(forKey: Keys.launchFullScreen) as? Bool ?? false
        // 旧設定の読み替えは、下の2つを読む**前に**済ませる(新しいキーへ書き込むため)。
        Self.migrateLoopBehaviorIfNeeded(defaults)
        self.firstPageBehavior =
            FirstPageBehavior(rawValue: defaults.string(forKey: Keys.firstPageBehavior) ?? "") ?? .none
        self.lastPageBehavior =
            LastPageBehavior(rawValue: defaults.string(forKey: Keys.lastPageBehavior) ?? "") ?? .none
        self.maxUpscalePercent = defaults.object(forKey: Keys.maxUpscalePercent) as? Double ?? 200
        self.maxPinchZoomPercent = defaults.object(forKey: Keys.maxPinchZoomPercent) as? Double ?? 400
        self.loupeMagnificationPercent =
            defaults.object(forKey: Keys.loupeMagnificationPercent) as? Double ?? 250
        self.loupeDiameter = defaults.object(forKey: Keys.loupeDiameter) as? Double ?? 400
        // 廃止した"low"の読み替えを含む(InterpolationQuality.init(storedRawValue:)参照)。
        self.interpolationQuality =
            InterpolationQuality(storedRawValue: defaults.string(forKey: Keys.interpolationQuality)) ?? .high
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
        // 既定は0(待たずに表示)。この設定を入れる前と同じ挙動にしておく。
        self.toolbarRevealDelay = defaults.object(forKey: Keys.toolbarRevealDelay) as? Double ?? 0
        self.progressBarRevealDelay = defaults.object(forKey: Keys.progressBarRevealDelay) as? Double ?? 0
        self.sidePanelRevealDelay = defaults.object(forKey: Keys.sidePanelRevealDelay) as? Double ?? 0
        self.prefetchPageCount = defaults.object(forKey: Keys.prefetchPageCount) as? Double ?? 3
        let displayLanguage = AppLanguage(rawValue: defaults.string(forKey: Keys.displayLanguage) ?? "") ?? .system
        self.displayLanguage = displayLanguage
        // 以前のバージョンで選んだ表示言語には、次回起動からメニューバーにも効かせるための
        // AppleLanguages(AppLanguage.applyAppleLanguagesOverride参照)が書かれていない。
        // 選択が保存されているのに印が無い、という状態をここで一度だけ埋める(didSetは初期化では
        // 走らない。効くのは次の起動から)。「システムに従う」なら何も書かない。
        if displayLanguage != .system {
            AppLanguage.applyAppleLanguagesOverride(for: displayLanguage, defaults: defaults)
        }
        self.appAppearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appAppearance) ?? "") ?? .system
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
        // 既定はOFF(従来どおりの並び)。並びが変わるきっかけはユーザー自身の意思によるものに
        // 限る、という方針のため。未設定(object(forKey:)がnil)のときの既定値を
        // PageOrder.usesFinderOrderと必ず揃えること ―― 食い違うと、画面のトグルと実際の
        // 並びが逆になる。
        self.usesFinderSortOrder = defaults.object(forKey: Keys.usesFinderSortOrder) as? Bool ?? false
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
        // フィルムストリップの見た目。既定値はどれも「これまでの見た目と1ピクセルも変わらない」値
        // (9枚・10pt・暗くする・アクセントカラー・3pt)。
        self.filmstripThumbnailCount =
            defaults.object(forKey: Keys.filmstripThumbnailCount) as? Double ?? 9
        self.filmstripFontSize = defaults.object(forKey: Keys.filmstripFontSize) as? Double ?? 10
        self.filmstripCaptionStyle =
            FilmstripCaptionStyle(rawValue: defaults.string(forKey: Keys.filmstripCaptionStyle) ?? "")
            ?? .fileNameAndPageNumber
        self.filmstripDimsOtherPages =
            defaults.object(forKey: Keys.filmstripDimsOtherPages) as? Bool ?? true
        self.filmstripHighlightColorOption =
            PageBorderColorOption(rawValue: defaults.string(forKey: Keys.filmstripHighlightColorOption) ?? "")
            ?? .accent
        self.filmstripHighlightCustomColor =
            defaults.string(forKey: Keys.filmstripHighlightCustomColor).flatMap(RGBColorValue.init(hexString:))
            ?? Self.defaultFilmstripHighlightCustomColor
        self.filmstripHighlightBorderWidth =
            defaults.object(forKey: Keys.filmstripHighlightBorderWidth) as? Double ?? 3
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
        self.welcomeSurfaceStyle = Self.loadSurfaceStyle(for: .welcome)
        self.overlaySurfaceStyle = Self.loadSurfaceStyle(for: .overlays)
        // 背後を透かすすりガラスの4スイッチ。既定OFF(toolbarDockedGlassのコメント参照)。
        self.toolbarDockedGlass = defaults.object(forKey: Keys.toolbarDockedGlass) as? Bool ?? false
        self.progressBarDockedGlass =
            defaults.object(forKey: Keys.progressBarDockedGlass) as? Bool ?? false
        self.sidePanelDockedGlass =
            defaults.object(forKey: Keys.sidePanelDockedGlass) as? Bool ?? false
        self.welcomeGlass = defaults.object(forKey: Keys.welcomeGlass) as? Bool ?? false
        self.launchInPrivateMode = defaults.object(forKey: Keys.launchInPrivateMode) as? Bool ?? false
        self.thumbnailDiskCacheEnabled =
            defaults.object(forKey: Keys.thumbnailDiskCacheEnabled) as? Bool ?? false
        self.thumbnailDiskCacheLimitMB =
            defaults.object(forKey: Keys.thumbnailDiskCacheLimitMB) as? Double
            ?? Self.defaultThumbnailDiskCacheLimitMB
        self.pageImageCacheLimitMB =
            defaults.object(forKey: Keys.pageImageCacheLimitMB) as? Double
            ?? Self.defaultPageImageCacheLimitMB
        self.nestedArchiveMemoryLimitMB =
            defaults.object(forKey: Keys.nestedArchiveMemoryLimitMB) as? Double
            ?? Self.defaultNestedArchiveMemoryLimitMB

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

        self.missingLayoutAutoLayout =
            MissingLayoutAutoLayout(rawValue: defaults.string(forKey: Keys.missingLayoutAutoLayout) ?? "")
            ?? .none
        self.bookExportCompletionBehavior =
            BookExportCompletionBehavior(
                rawValue: defaults.string(forKey: Keys.bookExportCompletionBehavior) ?? ""
            ) ?? .none
        self.bookExportDestinationModes = Self.loadFormatSettings(
            key: Keys.bookExportDestinationMode, fallback: .askEachTime
        )
        self.bookExportDataCleanups = Self.loadFormatSettings(
            key: Keys.bookExportDataCleanup, fallback: .keep
        )
        self.bookExportHistoryCleanups = Self.loadFormatSettings(
            key: Keys.bookExportHistoryCleanup, fallback: .keep
        )
        self.bookExportRenumbersImages = Self.loadFormatFlags(
            key: Keys.bookExportRenumbersImages, fallback: { $0 == .cbz }
        )
        self.bookExportIncludesExcludedPages = Self.loadFormatFlags(
            key: Keys.bookExportIncludesExcludedPages, fallback: { _ in false }
        )
        self.bookExportWritesVolumeElement =
            defaults.object(forKey: Keys.bookExportWritesVolumeElement) as? Bool ?? false

        // すべてのプロパティが揃ってから、サムネイルのディスクキャッシュへ設定を届ける
        // (didSetは初期化中には走らないので、ここで一度だけ明示的に呼ぶ必要がある)。
        // OFF(既定)ならこの呼び出しが、溜まっているキャッシュの削除の合図にもなる。
        applyThumbnailDiskCacheSettings()
        // 外観も同じ理由でここから1回。最初のウインドウが作られるより前(このinitは
        // AppStores経由でQooViewerApp.init()から呼ばれる)なので、既定の外観が一瞬見えて
        // から切り替わる、ということにはならない。
        AppAppearanceApplier.shared.apply(appAppearance)
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
                Keys.usesFinderSortOrder,
            ]
        case .appearance:
            return [
                // アプリ全体のライト/ダーク。画面上もこの画面のいちばん上にある
                // (AppearanceSettingsView.appSection参照)。
                Keys.appAppearance,
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
                // プログレスバーのフィルムストリップ一式。ON/OFFも見た目の設定も画面上は
                // 同じセクションに並んでいるので、担当もまとめてこの画面
                // (AppearanceSettingsView.filmstripSection参照)。
                Keys.showProgressBarThumbnailPreview,
                Keys.filmstripThumbnailCount,
                Keys.filmstripCaptionStyle,
                Keys.filmstripFontSize,
                Keys.filmstripDimsOtherPages,
                Keys.filmstripHighlightColorOption,
                Keys.filmstripHighlightCustomColor,
                Keys.filmstripHighlightBorderWidth,
                // 「表示までの時間」は、面ごとのセクション(ツールバー/プログレスバー/
                // サイドパネル)の中にあるので、この画面の担当
                // (AppearanceSettingsView.revealDelayBinding(for:)参照)。
                Keys.toolbarRevealDelay,
                Keys.progressBarRevealDelay,
                Keys.sidePanelRevealDelay,
                // 背後を透かすすりガラスの4スイッチも、面ごとのセクションに並ぶ設定なので
                // この画面の担当(AppearanceSettingsView.behindWindowGlassBinding(for:)参照)。
                Keys.toolbarDockedGlass,
                Keys.progressBarDockedGlass,
                Keys.sidePanelDockedGlass,
                Keys.welcomeGlass,
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
                Keys.firstPageBehavior,
                Keys.lastPageBehavior,
                Keys.treatTrackpadFlickAsWheel,
                Keys.invertTwoFingerScrolling,
                // フィルムストリップのON/OFF(showProgressBarThumbnailPreview)は、見た目の設定
                // 一式と一緒に「外観」の担当へ移した(上のcase .appearance参照)。
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
                Keys.nestedArchiveMemoryLimitMB,
                Keys.prefetchPageCount,
                Keys.preloadThumbnailGridPreviews,
                Keys.thumbnailDiskCacheEnabled,
                // 上限を下げても消えるのは再生成できるサムネイルだけなので、保管件数の2つ
                // (maxTrackedBooksCount/recentFilesLimit)と違って対象に含めてよい。
                Keys.thumbnailDiskCacheLimitMB,
            ]
        case .layout:
            return [
                Keys.missingLayoutAutoLayout,
                Keys.bookExportCompletionBehavior,
                Keys.bookExportWritesVolumeElement,
            ]
                + BookExportFormat.allCases.flatMap {
                    [
                        Keys.bookExportDestinationMode($0),
                        Keys.bookExportDataCleanup($0),
                        Keys.bookExportHistoryCleanup($0),
                        Keys.bookExportRenumbersImages($0),
                        Keys.bookExportIncludesExcludedPages($0),
                        // 固定の保存先そのもの(セキュリティスコープ付きブックマークと表示用の
                        // パス)も一緒に忘れる。保存先の決め方だけ「毎回確認」に戻して
                        // フォルダの記憶が残ると、次に「保存先を設定」を選んだ瞬間、
                        // 初期設定に戻したはずの古いフォルダが復活する。
                    ] + $0.fixedFolder.defaultsKeys
                }
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
            usesFinderSortOrder = source.usesFinderSortOrder
        case .appearance:
            appAppearance = source.appAppearance
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
            showProgressBarThumbnailPreview = source.showProgressBarThumbnailPreview
            filmstripThumbnailCount = source.filmstripThumbnailCount
            filmstripCaptionStyle = source.filmstripCaptionStyle
            filmstripFontSize = source.filmstripFontSize
            filmstripDimsOtherPages = source.filmstripDimsOtherPages
            filmstripHighlightColorOption = source.filmstripHighlightColorOption
            filmstripHighlightCustomColor = source.filmstripHighlightCustomColor
            filmstripHighlightBorderWidth = source.filmstripHighlightBorderWidth
            toolbarRevealDelay = source.toolbarRevealDelay
            progressBarRevealDelay = source.progressBarRevealDelay
            sidePanelRevealDelay = source.sidePanelRevealDelay
            toolbarDockedGlass = source.toolbarDockedGlass
            progressBarDockedGlass = source.progressBarDockedGlass
            sidePanelDockedGlass = source.sidePanelDockedGlass
            welcomeGlass = source.welcomeGlass
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
            firstPageBehavior = source.firstPageBehavior
            lastPageBehavior = source.lastPageBehavior
            treatTrackpadFlickAsWheel = source.treatTrackpadFlickAsWheel
            invertTwoFingerScrolling = source.invertTwoFingerScrolling
            thumbnailHoverPreviewDelay = source.thumbnailHoverPreviewDelay
            thumbnailHoverPreviewSize = source.thumbnailHoverPreviewSize
            slideshowInterval = source.slideshowInterval
            autoHideCursor = source.autoHideCursor
            cursorAutoHideDelay = source.cursorAutoHideDelay
        case .cache:
            pageImageCacheLimitMB = source.pageImageCacheLimitMB
            nestedArchiveMemoryLimitMB = source.nestedArchiveMemoryLimitMB
            prefetchPageCount = source.prefetchPageCount
            preloadThumbnailGridPreviews = source.preloadThumbnailGridPreviews
            thumbnailDiskCacheEnabled = source.thumbnailDiskCacheEnabled
            thumbnailDiskCacheLimitMB = source.thumbnailDiskCacheLimitMB
        case .layout:
            missingLayoutAutoLayout = source.missingLayoutAutoLayout
            bookExportCompletionBehavior = source.bookExportCompletionBehavior
            bookExportDestinationModes = source.bookExportDestinationModes
            bookExportDataCleanups = source.bookExportDataCleanups
            bookExportHistoryCleanups = source.bookExportHistoryCleanups
            bookExportRenumbersImages = source.bookExportRenumbersImages
            bookExportIncludesExcludedPages = source.bookExportIncludesExcludedPages
            bookExportWritesVolumeElement = source.bookExportWritesVolumeElement
        case .keyboard, .mouse, .modeInput, .access, .reset:
            break
        }
    }
}
