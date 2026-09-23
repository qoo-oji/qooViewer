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
        static let cursorAutoHideDelay = "qooViewer.pref.cursorAutoHideDelay"
        static let prefetchPageCount = "qooViewer.pref.prefetchPageCount"
        static let displayLanguage = AppLanguage.defaultsKey
        static let privateWindowsUseOwnAppearance = "qooViewer.pref.privateWindowsUseOwnAppearance"
        static let privateWindowTitlePrefix = "qooViewer.pref.privateWindowTitlePrefix"
        /// シークレットの揃いをノーマルの値から始めたかどうか(設定ではなく記録。privateWindowsUseOwnAppearance参照)。
        static let privateAppearanceInitialized = "qooViewer.pref.privateAppearanceInitialized"
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
        /// 環境設定「ファイルブラウザ」(改善要望7 段階3)。
        static let fileBrowserStartupLocation = "qooViewer.pref.fileBrowser.startupLocation"
        static let fileBrowserStartupFavoriteID = "qooViewer.pref.fileBrowser.startupFavoriteID"
        static let fileBrowserFoldersFirst = "qooViewer.pref.fileBrowser.foldersFirst"
        static let fileBrowserExternalDropAction = "qooViewer.pref.fileBrowser.externalDropAction"
        static let fileBrowserExpandsTreeToCurrentFolder = "qooViewer.pref.fileBrowser.expandsTreeToCurrentFolder"
        static let fileBrowserTreeFollowsListSort = "qooViewer.pref.fileBrowser.treeFollowsListSort"
        static let fileBrowserCompressionFormat = "qooViewer.pref.fileBrowser.compressionFormat"
        static let fileBrowserVideoThumbnailsEnabled = "qooViewer.pref.fileBrowser.videoThumbnailsEnabled"
        static let fileBrowserRevealDestination = "qooViewer.pref.fileBrowser.revealDestination"
        static let fileBrowserReadOnly = "qooViewer.pref.fileBrowser.readOnly"
        static let fileBrowserImageFolderOpenAction = "qooViewer.pref.fileBrowser.imageFolderOpenAction"
        static let sidePanelPosition = "qooViewer.pref.sidePanelPosition"
        static let sidePanelMode = "qooViewer.pref.sidePanelMode"
        static let offersRemovingMissingCollectionBooks =
            "qooViewer.pref.offersRemovingMissingCollectionBooks"
        static let libraryFeatureEnabled = "qooViewer.pref.libraryFeatureEnabled"
        static let fileBrowserFeatureEnabled = "qooViewer.pref.fileBrowserFeatureEnabled"
        static let smartLibraryFeatureEnabled = "qooViewer.pref.smartLibraryFeatureEnabled"
        static let showRecentFavoritesOnWelcome = "qooViewer.pref.showRecentFavoritesOnWelcome"
        static let thumbnailHoverPreviewDelay = "qooViewer.pref.thumbnailHoverPreviewDelay"
        static let thumbnailHoverPreviewSize = "qooViewer.pref.thumbnailHoverPreviewSize"
        static let preloadThumbnailGridPreviews = "qooViewer.pref.preloadThumbnailGridPreviews"
        static let defaultReadingDirection = "qooViewer.pref.defaultReadingDirection"
        static let spreadBookmarkTargetBehavior = "qooViewer.pref.spreadBookmarkTargetBehavior"
        static let launchInPrivateMode = "qooViewer.pref.launchInPrivateMode"
        static let thumbnailDiskCacheEnabled = "qooViewer.pref.thumbnailDiskCacheEnabled"
        static let thumbnailDiskCacheLimitMB = "qooViewer.pref.thumbnailDiskCacheLimitMB"
        static let fileBrowserThumbnailCacheEnabled = "qooViewer.pref.fileBrowserThumbnailCacheEnabled"
        static let fileBrowserThumbnailCacheLimitMB = "qooViewer.pref.fileBrowserThumbnailCacheLimitMB"
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

    }

    /// 設定の保存先。通常はアプリの`UserDefaults.standard`で、テストだけが専用の
    /// suite(`UserDefaults(suiteName:)`)を渡す。
    ///
    /// この型は**すべての設定の既定値の正典**(`init`の`?? 既定値`)であり、旧キーの読み替え
    /// (`migrateLoopBehaviorIfNeeded`)や面ごとの「初期設定に戻す」(`resetToDefaults`)も
    /// ここにしか無い。保存先が`.standard`に固定されていると、それらをテストから確かめる手段が
    /// 実際にアプリの設定を書き換えることになってしまうため、保存先だけを差し替えられるように
    /// してある。通常の経路(引数なしの`AppPreferences()`)の挙動はこれまでと1つも変わらない。
    private let defaults: UserDefaults

    /// 保存先が実際のアプリのもの(`.standard`)かどうか。
    ///
    /// falseのとき ―― つまりテストが専用のsuiteを渡したとき ―― は、**保存先の外へ出ていく
    /// 副作用**を行わない: サムネイルのディスクキャッシュの設定(実ファイルの削除を伴う)、
    /// 外観の適用(`NSApp.appearance`)、履歴を切り詰めさせる通知。`AppleLanguages`は保存先の中で完結するので、こちらは`defaults`へ
    /// 素直に書く(渡されたsuiteに書かれるだけで、アプリには効かない)。
    private let sharesGlobalState: Bool

    /// 入力ファイルなしで起動した場合(Finderでの直接オープンやDockアイコンへの
    /// ドラッグ&ドロップ以外の、通常の起動)に、前回終了時にアクティブだった画面/タブが
    /// 表示していた本を自動的に開く。すべてのウインドウ・タブを復元するわけではなく、
    /// その1冊だけが対象。復元前に、そのファイルが削除されていないか、前回開いたときから
    /// 中身が変わっていないかを確認し、どちらかに該当する場合は復元しない
    /// (詳細はContentView.swiftのresolveLastActiveBookURLIfUnchanged参照)。
    @Published var launchOpensLastBook: Bool {
        didSet { defaults.set(launchOpensLastBook, forKey: Keys.launchOpensLastBook) }
    }
    /// 起動時にフルスクリーンにする
    @Published var launchFullScreen: Bool {
        didSet { defaults.set(launchFullScreen, forKey: Keys.launchFullScreen) }
    }
    /// 最初のページで「前のページへ」の操作をしたときの挙動(FirstPageBehavior参照)
    @Published var firstPageBehavior: FirstPageBehavior {
        didSet { defaults.set(firstPageBehavior.rawValue, forKey: Keys.firstPageBehavior) }
    }
    /// 最後のページで「次のページへ」の操作をしたときの挙動(LastPageBehavior参照)
    @Published var lastPageBehavior: LastPageBehavior {
        didSet { defaults.set(lastPageBehavior.rawValue, forKey: Keys.lastPageBehavior) }
    }
    /// 画像が画面より小さいとき、最大何%まで拡大して表示するか(100〜800)
    @Published var maxUpscalePercent: Double {
        didSet { defaults.set(maxUpscalePercent, forKey: Keys.maxUpscalePercent) }
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
        didSet { defaults.set(maxPinchZoomPercent, forKey: Keys.maxPinchZoomPercent) }
    }
    /// ルーペの拡大率(%、100〜800)
    @Published var loupeMagnificationPercent: Double {
        didSet { defaults.set(loupeMagnificationPercent, forKey: Keys.loupeMagnificationPercent) }
    }
    /// ルーペの表示直径(pt)
    @Published var loupeDiameter: Double {
        didSet { defaults.set(loupeDiameter, forKey: Keys.loupeDiameter) }
    }
    /// 拡大縮小時の補間品質
    @Published var interpolationQuality: InterpolationQuality {
        didSet { defaults.set(interpolationQuality.rawValue, forKey: Keys.interpolationQuality) }
    }
    /// しばらく操作がないときマウスカーソルを自動的に隠す
    @Published var autoHideCursor: Bool {
        didSet { defaults.set(autoHideCursor, forKey: Keys.autoHideCursor) }
    }
    /// スライドショーでページがめくられる間隔(秒)
    @Published var slideshowInterval: Double {
        didSet { defaults.set(slideshowInterval, forKey: Keys.slideshowInterval) }
    }
    /// 新しく開いた本に最初に適用する表示モード
    @Published var defaultScalingMode: ScalingMode {
        didSet { defaults.set(defaultScalingMode.rawValue, forKey: Keys.defaultScalingMode) }
    }
    /// トラックパッドでのページ送りに、Macの「ページ間をスワイプ」ジェスチャー(フリック)を
    /// 使用する。ONにすると、トラックパッドの2本指の縦スクロールによるページ送りは行われなく
    /// なり(完全に無視される)、代わりに左右へのフリックでページ送りするようになる
    /// (詳細はViewerView.swiftのhandleTrackpadScrollGesture/handleSwipeのコメント参照)。
    /// 物理的なマウスホイールでのページ送りには影響しない。
    @Published var treatTrackpadFlickAsWheel: Bool {
        didSet { defaults.set(treatTrackpadFlickAsWheel, forKey: Keys.treatTrackpadFlickAsWheel) }
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
        didSet { defaults.set(invertTwoFingerScrolling, forKey: Keys.invertTwoFingerScrolling) }
    }
    /// すべてのウインドウ(実寸表示・環境設定ウインドウを含む)を閉じたときにqooViewerを終了する。
    /// OFF(既定)のときは、macOSの標準的なアプリと同様にウインドウを閉じてもDockに残ります。
    @Published var quitWhenLastWindowClosed: Bool {
        didSet { defaults.set(quitWhenLastWindowClosed, forKey: Keys.quitWhenLastWindowClosed) }
    }
    /// 見開き表示中でも、この値(横÷縦)以上の横長画像は単ページ表示にする。既定は1.0(正方形以上で単ページ)。
    @Published var singlePageAspectRatioThreshold: Double {
        didSet {
            defaults.set(singlePageAspectRatioThreshold, forKey: Keys.singlePageAspectRatioThreshold)
        }
    }
    /// しばらく操作がないと判定してマウスカーソルを自動的に隠すまでの時間(秒)
    @Published var cursorAutoHideDelay: Double {
        didSet { defaults.set(cursorAutoHideDelay, forKey: Keys.cursorAutoHideDelay) }
    }
    /// 現在のページの前後何ページ分を先読みするか
    @Published var prefetchPageCount: Double {
        didSet { defaults.set(prefetchPageCount, forKey: Keys.prefetchPageCount) }
    }
    // MARK: - 外観(ノーマルウインドウ用・シークレットウインドウ用。2026-09-22)

    /// 環境設定「外観」タブの設定一式。ノーマルウインドウ用(従来の設定そのもの)と、シークレットウインドウ用の2揃い。
    /// 型コメントは AppearanceSettings。どちらを使うかは appearance(forPrivateWindow:)。
    let appearance: AppearanceSettings
    let privateAppearance: AppearanceSettings

    /// シークレットウインドウに、ノーマルウインドウとは別の外観を使うか(既定OFF = シークレットもノーマルの外観に従う。ユーザー要望)。
    ///
    /// 初めてONにした時点で、シークレットの揃いをノーマルの揃いの写しから始める(「初めから別の見た目」ではなく
    /// 「今の見た目から変えていく」ため)。2回目以降は写さない ―― OFFにしてもシークレットの揃いは消さずに残し、
    /// ONに戻せば前に作った見た目で戻る。
    ///
    /// どの画面の「初期設定に戻す」でも戻さない(外観タブのボタンは編集中の揃いを戻すもので、このスイッチは揃いではないため)。
    @Published var privateWindowsUseOwnAppearance: Bool {
        didSet {
            defaults.set(privateWindowsUseOwnAppearance, forKey: Keys.privateWindowsUseOwnAppearance)
            if privateWindowsUseOwnAppearance, !defaults.bool(forKey: Keys.privateAppearanceInitialized) {
                privateAppearance.copyValues(from: appearance)
                defaults.set(true, forKey: Keys.privateAppearanceInitialized)
            }
        }
    }

    /// シークレットウインドウのタイトルの先頭に付ける文字(環境設定「外観」→「ウインドウ」。2026-09-22、ユーザー要望)。
    ///
    /// **nil = 既定**の「(シークレット)」(表示言語に合わせて訳す。文字列カタログの "(Private) %@")。ユーザーが書き換えたら
    /// その文字列をそのまま使い(絵文字も可)、**空なら何も付けない** ―― タイトルバーの色でシークレットウインドウを見分けられる
    /// ようになったので、文字は要らないという人のため(ユーザー要望)。既定を「未指定」として別に持つのは、表示言語を切り替えたときに
    /// 既定の文字も追従させるため(タイトルバーの色の nil と同じ考え方)。
    ///
    /// 外観の揃いではなくアプリ全体で1つ(タイトルの文字はノーマル/シークレットの外観の切り替えとは関係なく、シークレットウインドウ
    /// にだけ付くもの)。「ウインドウ」セクションのスイッチと同じく、外観の画面の「初期設定に戻す」では戻さない(行の右の矢印で既定へ戻す)。
    @Published var privateWindowTitlePrefix: String? {
        didSet {
            if let privateWindowTitlePrefix {
                defaults.set(privateWindowTitlePrefix, forKey: Keys.privateWindowTitlePrefix)
            } else {
                defaults.removeObject(forKey: Keys.privateWindowTitlePrefix)
            }
        }
    }

    /// 既定の「(シークレット)」(いまの表示言語で)。環境設定の入力欄に、未指定のときに出す文字でもある。
    var defaultPrivateWindowTitlePrefix: String {
        // カタログのキーは "(Private) %@"(ウインドウのタイトルの組み立てにずっと使ってきたもの)。訳語の側で語順が
        // 変わっていても崩れないよう、本題を空にした形から前置きだけを取り出す。
        String(localized: "(Private) \("")", language: effectiveLocale).trimmingCharacters(in: .whitespaces)
    }

    /// シークレットウインドウのタイトル。`base` は本の名前やフォルダ名など、ノーマルウインドウならそのまま出すもの。
    func privateWindowTitle(for base: String) -> String {
        guard let privateWindowTitlePrefix else {
            return String(localized: "(Private) \(base)", language: effectiveLocale)
        }
        let prefix = privateWindowTitlePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? base : "\(prefix) \(base)"
    }

    /// そのウインドウが使う外観の揃い。シークレットウインドウでも、「シークレットウインドウに固有の外観を適用」がOFFならノーマルの揃い。
    func appearance(forPrivateWindow isPrivateWindow: Bool) -> AppearanceSettings {
        isPrivateWindow && privateWindowsUseOwnAppearance ? privateAppearance : appearance
    }

    /// アプリの表示言語(既定は「システムに従う」)
    @Published var displayLanguage: AppLanguage {
        didSet {
            defaults.set(displayLanguage.rawValue, forKey: Keys.displayLanguage)
            // メニューバーなど起動中には切り替えられない部分を、次回起動から揃える
            // (AppLanguage.applyAppleLanguagesOverrideのコメント参照)。
            AppLanguage.applyAppleLanguagesOverride(for: displayLanguage, defaults: defaults)
        }
    }
    /// 以前開いたことのある本を再度開いたときの挙動(既定は「前回のページから再開する」)
    @Published var reopenBehavior: ReopenBehavior {
        didSet { defaults.set(reopenBehavior.rawValue, forKey: Keys.reopenBehavior) }
    }
    /// 複数のタブを開いているウインドウを、赤い閉じるボタンまたはウインドウメニューの
    /// 「ウインドウを閉じる」で閉じようとしたとき、本当に閉じてよいか確認するダイアログを
    /// 表示するかどうか(既定はON)。OFFのときは確認なしで閉じる。
    /// (Cmd+Wやタブバー自身の×ボタンでは、AppKit上の制約によりこの確認は出せない。
    ///  QooViewerApp.swiftのBookClosingWindowDelegateのコメント参照)。
    @Published var confirmBeforeClosingMultipleTabsWindow: Bool {
        didSet {
            defaults.set(
                confirmBeforeClosingMultipleTabsWindow,
                forKey: Keys.confirmBeforeClosingMultipleTabsWindow
            )
        }
    }
    /// 既に本を表示している状態で、Finderから(ダブルクリックや「このアプリケーションで開く」で)
    /// 別の本を開こうとしたときの挙動(既定は「現在の本を閉じて新しい本を開く」=以前からの挙動)。
    @Published var finderOpenBehavior: FinderOpenBehavior {
        didSet { defaults.set(finderOpenBehavior.rawValue, forKey: Keys.finderOpenBehavior) }
    }
    /// 既に本を表示している状態で、お気に入り一覧(メニューバー・ツールバー・ウェルカム画面)から
    /// 別の本を開こうとしたときの挙動(既定は「現在の本を閉じて新しい本を開く」)。
    /// FinderOpenBehaviorと選択肢(現在の本を閉じて開く/新しいタブ/新しいウインドウ)が同じ
    /// ため、型はそのまま再利用している。以前はお気に入りを開くたびにサブメニューから
    /// 「開く/新しいウインドウで開く/新しいタブで開く」を毎回選ぶ形式だったが、
    /// この環境設定1箇所で挙動を固定できるように変更した。
    @Published var favoriteOpenBehavior: FinderOpenBehavior {
        didSet { defaults.set(favoriteOpenBehavior.rawValue, forKey: Keys.favoriteOpenBehavior) }
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
            defaults.set(
                spreadBookmarkTargetBehavior.rawValue, forKey: Keys.spreadBookmarkTargetBehavior
            )
        }
    }
    /// 本ごとの読書状態(最後に読んだページなど)とブックマークを保持しておく本の数の上限。
    /// これを超えて新しい本を開くと、最後に読んだ時刻が古い本のデータから自動的に削除される
    /// (LibraryDataPruner参照)。データが際限なく増え続けるのを防ぐための設定(既定500冊)。
    @Published var maxTrackedBooksCount: Double {
        didSet { defaults.set(maxTrackedBooksCount, forKey: Keys.maxTrackedBooksCount) }
    }
    /// 表示メニューの「ツールバーを隠す」。以前はAppState(ウインドウごとに新規作成される)だけが
    /// 持つ一時的な状態だったため、アプリを終了して再度起動するとOFFに戻ってしまっていた。
    /// ここに持たせてUserDefaultsへ保存することで、次回起動時にも再現するようにしている
    /// (新しく開いたウインドウは、AppState側でここの値を初期値として引き継ぐ)。
    @Published var hideToolbar: Bool {
        didSet { defaults.set(hideToolbar, forKey: Keys.hideToolbar) }
    }
    /// 表示メニューの「プログレスバーを隠す」。hideToolbarと同じ理由でここに持たせている。
    @Published var hideProgressBar: Bool {
        didSet { defaults.set(hideProgressBar, forKey: Keys.hideProgressBar) }
    }
    /// 表示メニューの「サイドパネルを隠す」。hideToolbarと同じ理由でここに持たせている。
    /// hideToolbar/hideProgressBarと異なり、サイドパネルは既定でOFF(=常時表示)。ONにすると
    /// ツールバー/プログレスバーの自動隠しと同様、マウスをウインドウ左端に近づけたときだけ
    /// 一時的に表示される(ContentView.installSidePanelHoverMonitorIfNeeded参照)。
    @Published var hideSidePanel: Bool {
        didSet { defaults.set(hideSidePanel, forKey: Keys.hideSidePanel) }
    }
    /// サイドパネルの幅(pt)。ユーザーが右端のドラッグハンドルで調整した値を次回起動時にも
    /// 再現する(SidePanelView.widthDragHitArea参照)。CGFloatではなくDoubleで持つのは
    /// maxTrackedBooksCountと同じ理由(UserDefaultsとの親和性)で、ContentView側で
    /// CGFloatへ変換して使う。
    @Published var sidePanelWidth: Double {
        didSet { defaults.set(sidePanelWidth, forKey: Keys.sidePanelWidth) }
    }
    /// 環境設定「一般」タブの、サイドパネル機能自体のON/OFF(既定ON)。hideSidePanelが
    /// 「常時表示か、ホバーで一時表示か」を切り替えるだけなのに対し、こちらはOFFにすると
    /// サイドパネル自体を一切表示しなくする(ContentView.body参照)。OFFの間は、表示メニューの
    /// 「サイドパネルを隠す」項目もメニューごと非表示になる(意味の無い設定を見せないため。
    /// QooViewerApp.swiftのCommandGroup参照)。
    @Published var sidePanelFeatureEnabled: Bool {
        didSet { defaults.set(sidePanelFeatureEnabled, forKey: Keys.sidePanelFeatureEnabled) }
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
        didSet { defaults.set(sidePanelUsesDoubleClick, forKey: Keys.sidePanelUsesDoubleClick) }
    }
    // 撤去した設定(改善要望7、2026-09-13)。**UserDefaultsの値は消さない** ―― 古い版を起動した
    // 人の設定を壊さないため。キーの一覧はdocs/06「環境設定」。
    // - 「ウェルカム画面でも表示する」(qooViewer.pref.showSidePanelOnWelcome) … 本を開いていない
    //   間はサイドパネルを常に出さなくなった(ContentView.isSidePanelSuppressedForWelcome。ライブラリ・ファイルブラウザ・
    //   スマートライブラリが3つともOFFのホームだけは例外で出す ―― 設定は戻していない)
    // - 「並び順をFinderに揃える」(PageOrder.retiredSettingKey) … 表示順は常に正準順
    //   (PageOrder.swift冒頭)
    // - 「最近開いたファイルを表示」(qooViewer.pref.showRecentFilesOnWelcome) … ウェルカム画面の
    //   「履歴から開く」ボタンごと無くなった(WelcomeTopBar)
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
        didSet { defaults.set(sidePanelSortOrder.rawValue, forKey: Keys.sidePanelSortOrder) }
    }
    /// サイドパネル上段(フォルダブラウザ)の並べ替えの基準と向き(ユーザー要望)。環境設定
    /// ウインドウではなく、パネル上部の並べ替えメニュー(SidePanelView.folderSection)から
    /// 直接切り替える。上のsidePanelSortOrder(フォルダをまとめて上に置くかどうか)とは
    /// 独立した設定で、そちらが上段・下段の共通設定なのに対し、こちらは上段専用
    /// (FolderBrowserSortKeyのコメント参照)。
    @Published var folderBrowserSortKey: FolderBrowserSortKey {
        didSet { defaults.set(folderBrowserSortKey.rawValue, forKey: Keys.folderBrowserSortKey) }
    }
    @Published var folderBrowserSortDirection: FolderBrowserSortDirection {
        didSet {
            defaults.set(folderBrowserSortDirection.rawValue, forKey: Keys.folderBrowserSortDirection)
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
            defaults.set(
                siblingNavigationFollowsBrowserSort, forKey: Keys.siblingNavigationFollowsBrowserSort
            )
        }
    }

    // MARK: - ファイルブラウザ(改善要望7 段階3、2026-09-13)

    /// ファイルブラウザを最初に開いたときに表示するフォルダ(環境設定「ファイルブラウザ」)。
    /// ウインドウごとに1回だけ効く ―― 一度開いたあとは、そのウインドウで最後にいた場所に戻る
    /// (FileBrowserState.activate)。
    @Published var fileBrowserStartupLocation: FileBrowserStartupLocation {
        didSet { defaults.set(fileBrowserStartupLocation.rawValue, forKey: Keys.fileBrowserStartupLocation) }
    }
    /// 上が`.favorite`のときに開く、よく使う項目の id(FavoriteLocationStore.Item.id の文字列)。
    /// 空なら未選択(ホームへ読み替える)。**UUID? ではなく文字列で持つ** ―― 登録を消した項目の id が
    /// 残っていても、読む側が「無ければホーム」と読み替えるだけで済むので、型で守る意味が薄い。
    @Published var fileBrowserStartupFavoriteID: String {
        didSet { defaults.set(fileBrowserStartupFavoriteID, forKey: Keys.fileBrowserStartupFavoriteID) }
    }
    /// ファイルブラウザで、フォルダを名前などの並びより先にまとめて上に出すか(既定ON)。
    ///
    /// **サイドパネルの「並び順」(sidePanelSortOrder)とは別に持つ。** あちらは「一般」の設定で、
    /// ファイルブラウザの環境設定の画面から変えられるものが別の画面の設定を書き換えると、
    /// 「初期設定に戻す」の担当もずれる。Finderでも「フォルダを常に上部に表示」は独立した設定。
    @Published var fileBrowserFoldersFirst: Bool {
        didSet { defaults.set(fileBrowserFoldersFirst, forKey: Keys.fileBrowserFoldersFirst) }
    }
    /// 他のアプリからファイルブラウザへドロップしたときにすること(既定: ビューアで開く)。
    /// アプリの中のドラッグには効かない(FileBrowserExternalDropActionの型コメント)。
    @Published var fileBrowserExternalDropAction: FileBrowserExternalDropAction {
        didSet { defaults.set(fileBrowserExternalDropAction.rawValue, forKey: Keys.fileBrowserExternalDropAction) }
    }
    /// 右ペインで移動するたびに、左のツリーを現在のフォルダまで開いてその行を選ぶか(既定OFF。2026-09-14、ユーザー要望)。
    /// 開き方は FileBrowserTreeView の型コメント「現在のフォルダまで開く」。
    @Published var fileBrowserExpandsTreeToCurrentFolder: Bool {
        didSet {
            defaults.set(fileBrowserExpandsTreeToCurrentFolder, forKey: Keys.fileBrowserExpandsTreeToCurrentFolder)
        }
    }
    /// 左のツリーで開いた行の子(サブフォルダ)を、右ペインと同じ並べ替えの基準・向きで並べるか(既定OFF = 名前の昇順。
    /// 2026-09-14、ユーザー要望)。根(ボリューム・ホーム・よく使う項目)の並びは変えない。並べ方は FileBrowserTreeView の
    /// 型コメント「子の並び」。
    @Published var fileBrowserTreeFollowsListSort: Bool {
        didSet { defaults.set(fileBrowserTreeFollowsListSort, forKey: Keys.fileBrowserTreeFollowsListSort) }
    }
    /// 「圧縮」で作る書庫の拡張子(既定 zip。段階 6)。
    @Published var fileBrowserCompressionFormat: FileBrowserCompressionFormat {
        didSet { defaults.set(fileBrowserCompressionFormat.rawValue, forKey: Keys.fileBrowserCompressionFormat) }
    }
    /// 本を表示しているウインドウで「ファイルブラウザで開く」を選んだときの行き先(既定: 新規タブ。決定事項 Q6、段階 8)。
    @Published var fileBrowserRevealDestination: FileBrowserRevealDestination {
        didSet { defaults.set(fileBrowserRevealDestination.rawValue, forKey: Keys.fileBrowserRevealDestination) }
    }
    /// 読み取り専用モード(決定事項 Q12、段階 8.5)。**既定 ON**(段階 4 から書く操作を使っていた人も、初回は ON で始まる)。
    /// ON の間はファイルそのものを変える操作(ペースト・カット・ゴミ箱・名前の変更・新規フォルダ・一括リネーム・圧縮・展開・
    /// ファイルを動かす D&D・ファイル操作の取り消し/やり直し)をできなくする。判定の窓口は `FileBrowserOperations.isReadOnly`。
    /// 途中で ON にしても走っている操作は止めない(次の操作から効く)。
    @Published var fileBrowserReadOnly: Bool {
        didSet { defaults.set(fileBrowserReadOnly, forKey: Keys.fileBrowserReadOnly) }
    }
    /// 右ペインで画像フォルダをダブルクリック / Return で開いたときにすること(既定: フォルダを開く。2026-09-14、ユーザー要望)。
    /// 右クリックの「開く」はこの反対をする(FileBrowserImageFolderOpenAction の型コメント)。
    @Published var fileBrowserImageFolderOpenAction: FileBrowserImageFolderOpenAction {
        didSet {
            defaults.set(fileBrowserImageFolderOpenAction.rawValue, forKey: Keys.fileBrowserImageFolderOpenAction)
        }
    }
    /// アイコン表示で動画の絵を作るか(QuickLook。既定ON、段階 7b)。**よく使う項目の中の動画を裏で先に作っておくのも、
    /// この 1 つで切り替える**(ユーザーの判断 2026-09-14。行を分けない)。OFF にすると動画は種類のアイコンに戻り、
    /// 先に作る掃引も止まる(作り済みの絵はディスクキャッシュに残り、刈り込み・削除は本の絵と同じ)。
    @Published var fileBrowserVideoThumbnailsEnabled: Bool {
        didSet { defaults.set(fileBrowserVideoThumbnailsEnabled, forKey: Keys.fileBrowserVideoThumbnailsEnabled) }
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
        didSet { defaults.set(sidePanelPosition.rawValue, forKey: Keys.sidePanelPosition) }
    }
    /// サイドパネルの表示モード(ブラウザ/ブックマーク。SidePanelMode参照)。パネル最上部の
    /// スイッチで切り替える。ウインドウごとではなくアプリ全体で1つの値として持つ
    /// (sidePanelWidthと同じ考え方: 新しいウインドウ/タブや次回起動時も同じ見た目で始まる)。
    /// sidePanelWidthと違ってドラッグ中に高頻度で変化する値ではないため、ContentView側で
    /// @Stateへ写し取らず、この@Publishedを直接Bindingとして使う。
    @Published var sidePanelMode: SidePanelMode {
        didSet { defaults.set(sidePanelMode.rawValue, forKey: Keys.sidePanelMode) }
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
            defaults.set(recentFilesLimit, forKey: Self.recentFilesLimitDefaultsKey)
            // 件数を減らした場合に、その場で履歴側も切り詰めさせる(次に本を開くまで
            // 古い履歴が残り続けないようにするため)。
            if sharesGlobalState {
                NotificationCenter.default.post(name: .recentFilesLimitDidChange, object: nil)
            }
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
            defaults.set(thumbnailDiskCacheEnabled, forKey: Keys.thumbnailDiskCacheEnabled)
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
            defaults.set(thumbnailDiskCacheLimitMB, forKey: Keys.thumbnailDiskCacheLimitMB)
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
        didSet { defaults.set(pageImageCacheLimitMB, forKey: Keys.pageImageCacheLimitMB) }
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
        Int(clampedMegabytes(megabytes, default: defaultPageImageCacheLimitMB, range: pageImageCacheLimitRangeMB)) * 1024 * 1024
    }

    /// 保存されていた MB の値。数でなければ・有限でなければ既定値、範囲の外なら端へ寄せる。
    static func storedMegabytes(_ stored: Any?, default defaultValue: Double, range: ClosedRange<Double>) -> Double {
        clampedMegabytes((stored as? Double) ?? defaultValue, default: defaultValue, range: range)
    }

    /// NaN は `min` / `max` を素通りする(比較が常に偽)ので、先に有限かを見る。
    static func clampedMegabytes(_ megabytes: Double, default defaultValue: Double, range: ClosedRange<Double>) -> Double {
        guard megabytes.isFinite else { return defaultValue }
        return min(max(megabytes, range.lowerBound), range.upperBound)
    }

    /// 入れ子になった書庫(書庫の中の書庫)を、メモリ上に置いておく合計の上限(MB、既定256)。
    /// 2026-09に128から256へ上げた ―― 入れ子のrar/7zもメモリから開けるようになり、この値が
    /// 「1本をメモリで開いてよい大きさ」も兼ねるため、章ごとの書庫(50〜200MB)が収まる余裕を持たせた。
    ///
    /// 入れ子の書庫は「必要になったときに親から取り出す」方式で、取り出したものをしばらく
    /// 手元に置いておくと、同じ章のページを続けて読むあいだ取り出し直さずに済む
    /// (NestedArchiveResolver参照)。ここはその置き場の大きさ。
    ///
    /// 3形式ともメモリに置ける(2026-09までrar/7zはライブラリがファイルパスしか受け付けず
    /// 必ず一時ファイルになっていた)。これより大きい書庫は一時ファイルになるが、その一時
    /// ファイルの上限もこの値から導いている(NestedArchiveResolver.Limits.standard参照)ので、
    /// この1つを動かせば両方が動く。
    /// 上限を2つ3つ並べても意味が伝わらないため、ユーザーに見せるのはこれだけにしてある。
    ///
    /// 0にすると「メモリには一切置かず、常に一時ファイルを使う」という意味になる。
    ///
    /// nonisolated: PageLoader(actor)とBookLoaderのinitの既定引数から参照されるため
    /// (defaultPageImageCacheLimitMBと同じ理由)。
    @Published var nestedArchiveMemoryLimitMB: Double {
        didSet { defaults.set(nestedArchiveMemoryLimitMB, forKey: Keys.nestedArchiveMemoryLimitMB) }
    }
    nonisolated static let defaultNestedArchiveMemoryLimitMB: Double = 256
    static let nestedArchiveMemoryLimitRangeMB: ClosedRange<Double> = 0...1024
    nonisolated static let defaultNestedArchiveMemoryLimitBytes =
        Int(defaultNestedArchiveMemoryLimitMB) * 1024 * 1024
    /// PageLoader/BookLoaderへ渡す形(バイト数)。
    var nestedArchiveMemoryLimitBytes: Int {
        Self.nestedArchiveMemoryLimitBytes(forMB: nestedArchiveMemoryLimitMB)
    }
    /// 値を引数で受ける版(pageImageCacheLimitBytes(forMB:)と同じ理由・同じ使い方)。
    static func nestedArchiveMemoryLimitBytes(forMB megabytes: Double) -> Int {
        let clamped = clampedMegabytes(megabytes, default: defaultNestedArchiveMemoryLimitMB, range: nestedArchiveMemoryLimitRangeMB)
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
        // テスト用の保存先で作られたインスタンスは、実物のキャッシュ(共有のディレクトリ)に
        // 触らない。ここは設定OFFのときに溜まっているサムネイルを削除する入口でもあるため。
        guard sharesGlobalState else { return }
        let isEnabled = thumbnailDiskCacheEnabled
        let maxTotalBytes = Int(Self.clampedMegabytes(
            thumbnailDiskCacheLimitMB, default: Self.defaultThumbnailDiskCacheLimitMB, range: Self.thumbnailDiskCacheLimitRangeMB
        )) * 1024 * 1024
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

    /// ファイルブラウザの絵をディスクにも保存しておくか(FileBrowserThumbnailDiskCache、**既定はON**。改善要望7 段階 7a)。
    ///
    /// ページサムネイル(thumbnailDiskCacheEnabled)と既定が逆なのは、ユーザーの判断(2026-09-14)。書庫の並んだフォルダを
    /// 開くたびに全冊の索引を読み直すことになるので、既定で持つ。代わりに環境設定「キャッシュ」に使用量と削除を並べて見えるようにし、
    /// OFF にすればその場で消える(ページサムネイルが「黙って数百MB」と言われたのは、見えなかったことのほう)。
    @Published var fileBrowserThumbnailCacheEnabled: Bool {
        didSet {
            defaults.set(fileBrowserThumbnailCacheEnabled, forKey: Keys.fileBrowserThumbnailCacheEnabled)
            applyFileBrowserThumbnailCacheSettings()
        }
    }
    /// ファイルブラウザの絵のディスクキャッシュの合計上限(MB、既定200)。刈り込みの規則はページサムネイルと同じ。
    @Published var fileBrowserThumbnailCacheLimitMB: Double {
        didSet {
            defaults.set(fileBrowserThumbnailCacheLimitMB, forKey: Keys.fileBrowserThumbnailCacheLimitMB)
            applyFileBrowserThumbnailCacheSettings()
        }
    }
    static let defaultFileBrowserThumbnailCacheLimitMB: Double = 200
    static let fileBrowserThumbnailCacheLimitRangeMB: ClosedRange<Double> = 50...2000

    /// applyThumbnailDiskCacheSettingsと同じ(起動時の1回と、変更のたびに世代番号付きで届ける)。
    private func applyFileBrowserThumbnailCacheSettings() {
        guard sharesGlobalState else { return }
        let isEnabled = fileBrowserThumbnailCacheEnabled
        let maxTotalBytes = Int(Self.clampedMegabytes(
            fileBrowserThumbnailCacheLimitMB, default: Self.defaultFileBrowserThumbnailCacheLimitMB,
            range: Self.fileBrowserThumbnailCacheLimitRangeMB
        )) * 1024 * 1024
        fileBrowserThumbnailCacheConfigurationGeneration &+= 1
        let generation = fileBrowserThumbnailCacheConfigurationGeneration
        Task {
            await FileBrowserThumbnailDiskCache.shared.configure(
                isEnabled: isEnabled, maxTotalBytes: maxTotalBytes, generation: generation
            )
        }
    }
    private var fileBrowserThumbnailCacheConfigurationGeneration: UInt64 = 0

    /// 起動時に、**見つからなくなった本をコレクションから外すか**を尋ねるかどうか
    /// (ユーザー要望 2026-09-10。既定OFF)。
    ///
    /// 尋ねる対象は`BookLocation.missing`の本だけ ―― ボリュームは付いているのに実体に届かない
    /// 本に限る(外付けを外しているだけの本は入らない。判定の根拠はBookLocationの型コメント)。
    /// ONでも勝手には消さず、**起動時に一覧を出して「削除」を押されたときだけ**消す
    /// (キャンセルすれば何も起きず、次の起動でまた尋ねる)。中の本が全部なくなる
    /// コレクションは、コレクションごと削除する。
    ///
    /// 既定をOFFにしてあるのは、取り消せない削除を、設定を見ていない人の起動経路に
    /// 割り込ませないため(従来からのユーザーは設定を変えなければ何も変わらない、という
    /// このアプリの既定の決め方に従う)。
    @Published var offersRemovingMissingCollectionBooks: Bool {
        didSet {
            defaults.set(
                offersRemovingMissingCollectionBooks,
                forKey: Keys.offersRemovingMissingCollectionBooks
            )
        }
    }
    /// ホームのライブラリ機能(本棚: ライブラリ・コレクション)を使うか(ユーザー要望 2026-09-21。既定ON)。
    ///
    /// OFFにすると、ホームはファイルブラウザだけになり(帯ごと消える)、メニュー・右クリック・サイドパネルのライブラリの項目が
    /// 消え、**ライブラリのためだけの仕事が止まる**(登録した本の実体確認・表紙の抽出・自動登録フォルダの監視と走査・起動時の掃除)。
    /// サイドパネル機能のON/OFF(sidePanelFeatureEnabled)と同じ位置づけで、ファイルビューアとしてだけ使う人向け。
    /// **保存データは消さない** ―― ONへ戻せば棚は元のまま見える(止めていた仕事はその時点で動き出す)。何が止まり何が
    /// 止まらないかの一覧は `AppStores.applyLibraryFeature` のコメント。
    @Published var libraryFeatureEnabled: Bool {
        didSet { defaults.set(libraryFeatureEnabled, forKey: Keys.libraryFeatureEnabled) }
    }
    /// 保存されている値(無ければON)。環境設定のオブジェクトが届く前に要る場所のための口 ―― ウインドウの最初の1コマを
    /// 本棚で描かないために、WelcomeLibraryState が init で読む。
    static func storedLibraryFeatureEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.libraryFeatureEnabled) as? Bool ?? true
    }
    /// ホームのファイルブラウザ機能を使うか(ユーザー要望 2026-09-21。既定ON)。`libraryFeatureEnabled` と対の設定。
    ///
    /// OFFにすると、ホームからファイルブラウザが消え(帯の切り替えボタンも)、メニュー・右クリックのファイルブラウザの項目
    /// (「ファイルブラウザで開く」を含む)が消え、**ファイルブラウザのためだけの仕事が止まる**(自動リネーム・よく使う項目の中の
    /// 動画のサムネイルの先回り)。ホームの形はスマートライブラリを含む3つの設定の組で決まる(8通りの表は
    /// docs/plans/feature-toggle-audit.md、決める場所は `WelcomeLibraryState.constrained`)。スマートライブラリOFFのときは:
    /// - ライブラリON・ファイルブラウザON: 帯(切り替え + ライブラリ)と、本棚かファイルブラウザ
    /// - ライブラリON・ファイルブラウザOFF: ファイルブラウザを足す前の形(帯はライブラリだけ、中身は本棚)
    /// - ライブラリOFF・ファイルブラウザON: ファイルブラウザだけ(帯なし)
    /// - 3つともOFF: 本棚を足す前のウェルカム画面(「開く…」と最近開いた本。ClassicWelcomeView)
    /// 規則・よく使う項目・サムネイルのキャッシュなどの**保存したものは消さない**。何が止まり何が止まらないかの一覧は
    /// `AppStores.applyFileBrowserFeature` のコメント。
    @Published var fileBrowserFeatureEnabled: Bool {
        didSet { defaults.set(fileBrowserFeatureEnabled, forKey: Keys.fileBrowserFeatureEnabled) }
    }
    /// 保存されている値(無ければON)。`storedLibraryFeatureEnabled` と同じ理由の口。
    static func storedFileBrowserFeatureEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.fileBrowserFeatureEnabled) as? Bool ?? true
    }
    /// ホームのスマートライブラリを使うか(2026-09-22、利用者の要望。既定ON)。ライブラリ・ファイルブラウザと並ぶ 3 つ目の設定で、
    /// 3 つとも個別に切り替えられる(スマートライブラリの本は自分の対象フォルダの中だけなので、ほかの 2 つに頼らない)。
    /// OFF にすると帯・「ホーム」メニューからスマートライブラリが消え、メタデータの編集ウインドウの対象から対象フォルダの本が外れる
    /// (フォルダを探しに行かない)。対象フォルダ・スマートコレクション・ピン留めは**消さない**。ホームの形は 3 つの組で決まる
    /// (WelcomeLibraryState.constrained)。
    @Published var smartLibraryFeatureEnabled: Bool {
        didSet { defaults.set(smartLibraryFeatureEnabled, forKey: Keys.smartLibraryFeatureEnabled) }
    }
    /// 保存されている値(無ければON)。`storedLibraryFeatureEnabled` と同じ理由の口。
    static func storedSmartLibraryFeatureEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.smartLibraryFeatureEnabled) as? Bool ?? true
    }
    /// ウェルカム画面に「最近お気に入りに追加したファイル」一覧(最大10件)を表示するかどうか(既定ON)。
    @Published var showRecentFavoritesOnWelcome: Bool {
        didSet {
            defaults.set(showRecentFavoritesOnWelcome, forKey: Keys.showRecentFavoritesOnWelcome)
        }
    }


    // MARK: - レイアウト(環境設定「レイアウト」画面。ユーザー要望)

    /// レイアウトの保存データを持っていない本を開いたときに、本全体を自動レイアウトするか
    /// (MissingLayoutAutoLayout参照)。
    @Published var missingLayoutAutoLayout: MissingLayoutAutoLayout {
        didSet {
            defaults.set(missingLayoutAutoLayout.rawValue, forKey: Keys.missingLayoutAutoLayout)
        }
    }

    /// 右クリックの「本の書き出し」で、いま開いている本を書き出し終えたあとの動作
    /// (BookExportCompletionBehavior参照)。形式によらず1つの設定にしてある ――
    /// 「書き出したら次の本へ」という流れは、どの形式で書き出すかとは無関係のため。
    @Published var bookExportCompletionBehavior: BookExportCompletionBehavior {
        didSet {
            defaults.set(
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
        didSet { Self.saveFormatSettings(bookExportDestinationModes, key: Keys.bookExportDestinationMode, defaults: defaults) }
    }
    @Published private var bookExportDataCleanups: [BookExportFormat: BookExportCleanup] {
        didSet { Self.saveFormatSettings(bookExportDataCleanups, key: Keys.bookExportDataCleanup, defaults: defaults) }
    }
    @Published private var bookExportHistoryCleanups: [BookExportFormat: BookExportCleanup] {
        didSet { Self.saveFormatSettings(bookExportHistoryCleanups, key: Keys.bookExportHistoryCleanup, defaults: defaults) }
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
        didSet { Self.saveFormatFlags(
                bookExportRenumbersImages, key: Keys.bookExportRenumbersImages, defaults: defaults
            ) }
    }
    @Published private var bookExportIncludesExcludedPages: [BookExportFormat: Bool] {
        didSet {
            Self.saveFormatFlags(
                bookExportIncludesExcludedPages, key: Keys.bookExportIncludesExcludedPages,
                defaults: defaults
            )
        }
    }
    /// CBZのComicInfo.xmlの`Volume`要素にも巻数を書き出すか(CBZ専用)。
    @Published var bookExportWritesVolumeElement: Bool {
        didSet {
            defaults.set(bookExportWritesVolumeElement, forKey: Keys.bookExportWritesVolumeElement)
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
        _ values: [BookExportFormat: Bool], key: (BookExportFormat) -> String, defaults: UserDefaults
    ) {
        for format in BookExportFormat.allCases {
            guard let value = values[format] else { continue }
            defaults.set(value, forKey: key(format))
        }
    }

    private static func loadFormatFlags(
        key: (BookExportFormat) -> String, fallback: (BookExportFormat) -> Bool, defaults: UserDefaults
    ) -> [BookExportFormat: Bool] {
        var result: [BookExportFormat: Bool] = [:]
        for format in BookExportFormat.allCases {
            result[format] = defaults.object(forKey: key(format)) as? Bool ?? fallback(format)
        }
        return result
    }

    private static func saveFormatSettings<Value: RawRepresentable>(
        _ values: [BookExportFormat: Value], key: (BookExportFormat) -> String, defaults: UserDefaults
    ) where Value.RawValue == String {
        for format in BookExportFormat.allCases {
            guard let value = values[format] else { continue }
            defaults.set(value.rawValue, forKey: key(format))
        }
    }

    private static func loadFormatSettings<Value: RawRepresentable>(
        key: (BookExportFormat) -> String, fallback: Value, defaults: UserDefaults
    ) -> [BookExportFormat: Value] where Value.RawValue == String {
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
        didSet { defaults.set(launchInPrivateMode, forKey: Keys.launchInPrivateMode) }
    }

    /// 上の値を、AppPreferencesのインスタンスを持たない箇所(ContentViewのinit、
    /// LaunchCoordinator、AppDelegate)から読むための窓口。
    static var isPrivateModeDefault: Bool {
        UserDefaults.standard.bool(forKey: Keys.launchInPrivateMode)
    }

    /// 「隠す」3つ(ツールバー / プログレスバー / サイドパネル)の、ウインドウを組み立てる
    /// 時点での値。
    ///
    /// ■ なぜインスタンスを介さずに読むのか(ユーザー報告 2026-09-09)
    /// この3つはウインドウごとの状態(AppState)で、これまでは`ContentView`の`onAppear`で
    /// AppPreferencesから写していた。onAppearが走るのは**最初のフレームを描いた後**なので、
    /// 隠してあるはずのパーツが1フレームだけ現れ、直後に閉じる様子が見えていた ――
    /// サイドパネルは幅を持つうえ0.15秒のアニメーションが掛かるので、起動直後に
    /// 「サイドパネルが隠れる様子」としてはっきり見える。AppStateを作る時点
    /// (`ContentView.init`)で渡してしまえば、最初のフレームから正しい姿で描かれる。
    /// onAppearの写しはそのまま残してある ―― 他のウインドウでこの設定が変わった後に
    /// 開いたタブにも効かせるためで、値が同じなら何も起きない。
    /// `nonisolated`: `AppState.init`の既定値として書けるようにするため。このプロジェクトは
    /// 既定のアクター隔離がMainActorなので、そのままだとメンバーワイズのinit自体が
    /// MainActor隔離になり、同期の非隔離文脈から呼べない。
    nonisolated struct HiddenChrome: Equatable, Sendable {
        var toolbar = false
        var progressBar = false
        var sidePanel = false
    }

    /// 上の値の窓口(isPrivateModeDefaultと同じ理由でstatic)。
    static var hiddenChromeDefaults: HiddenChrome {
        HiddenChrome(
            toolbar: UserDefaults.standard.bool(forKey: Keys.hideToolbar),
            progressBar: UserDefaults.standard.bool(forKey: Keys.hideProgressBar),
            sidePanel: UserDefaults.standard.bool(forKey: Keys.hideSidePanel)
        )
    }

    // MARK: - サムネイルのホバー拡大プレビュー(ページ一覧・サイドパネル・ブックマーク編集・書き出し共通)

    /// ホバー開始からプレビューを出すまでの時間(秒)。こちらはページ一覧・サイドパネル・
    /// ブックマーク編集・書き出しウインドウのすべてで共通。以前は各所で350msの定数をコピー
    /// していた(通り抜けるだけの動きで次々開くのを避けるための遅延。0でも可)。
    @Published var thumbnailHoverPreviewDelay: Double {
        didSet { defaults.set(thumbnailHoverPreviewDelay, forKey: Keys.thumbnailHoverPreviewDelay) }
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
        didSet { defaults.set(thumbnailHoverPreviewSize, forKey: Keys.thumbnailHoverPreviewSize) }
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
        didSet { defaults.set(preloadThumbnailGridPreviews, forKey: Keys.preloadThumbnailGridPreviews) }
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
            defaults.set(defaultReadingDirection.rawValue, forKey: Keys.defaultReadingDirection)
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

    /// - Parameter defaults: 設定の保存先。既定は実際のアプリの保存先(`.standard`)。
    ///   テストだけが専用の suite を渡す(`sharesGlobalState` のコメント参照)。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sharesGlobalState = defaults === UserDefaults.standard
        // ノーマルの揃いは、ライト/ダークをアプリ全体へ掛ける(AppearanceSettings.appliesToApp)。
        self.appearance = AppearanceSettings(profile: .normal, defaults: defaults)
        self.privateAppearance = AppearanceSettings(profile: .privateWindow, defaults: defaults)
        self.privateWindowsUseOwnAppearance =
            defaults.object(forKey: Keys.privateWindowsUseOwnAppearance) as? Bool ?? false
        self.privateWindowTitlePrefix = defaults.string(forKey: Keys.privateWindowTitlePrefix)
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
        self.cursorAutoHideDelay = defaults.object(forKey: Keys.cursorAutoHideDelay) as? Double ?? 2.0
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
        self.fileBrowserStartupLocation = FileBrowserStartupLocation(
            rawValue: defaults.string(forKey: Keys.fileBrowserStartupLocation) ?? ""
        ) ?? .home
        self.fileBrowserStartupFavoriteID = defaults.string(forKey: Keys.fileBrowserStartupFavoriteID) ?? ""
        self.fileBrowserFoldersFirst = defaults.object(forKey: Keys.fileBrowserFoldersFirst) as? Bool ?? true
        self.fileBrowserExternalDropAction = FileBrowserExternalDropAction(
            rawValue: defaults.string(forKey: Keys.fileBrowserExternalDropAction) ?? ""
        ) ?? .openInViewer
        self.fileBrowserExpandsTreeToCurrentFolder =
            defaults.object(forKey: Keys.fileBrowserExpandsTreeToCurrentFolder) as? Bool ?? false
        self.fileBrowserTreeFollowsListSort =
            defaults.object(forKey: Keys.fileBrowserTreeFollowsListSort) as? Bool ?? false
        self.fileBrowserVideoThumbnailsEnabled =
            defaults.object(forKey: Keys.fileBrowserVideoThumbnailsEnabled) as? Bool ?? true
        self.fileBrowserCompressionFormat = FileBrowserCompressionFormat(
            rawValue: defaults.string(forKey: Keys.fileBrowserCompressionFormat) ?? ""
        ) ?? .zip
        self.fileBrowserReadOnly = defaults.object(forKey: Keys.fileBrowserReadOnly) as? Bool ?? true
        self.fileBrowserRevealDestination = FileBrowserRevealDestination(
            rawValue: defaults.string(forKey: Keys.fileBrowserRevealDestination) ?? ""
        ) ?? .newTab
        self.fileBrowserImageFolderOpenAction = FileBrowserImageFolderOpenAction(
            rawValue: defaults.string(forKey: Keys.fileBrowserImageFolderOpenAction) ?? ""
        ) ?? .openFolder
        self.sidePanelPosition =
            SidePanelPosition(rawValue: defaults.string(forKey: Keys.sidePanelPosition) ?? "") ?? .left
        self.sidePanelMode =
            SidePanelMode(rawValue: defaults.string(forKey: Keys.sidePanelMode) ?? "") ?? .browser
        self.recentFilesLimit =
            defaults.object(forKey: Self.recentFilesLimitDefaultsKey) as? Double
            ?? Self.defaultRecentFilesLimit
        self.offersRemovingMissingCollectionBooks =
            defaults.object(forKey: Keys.offersRemovingMissingCollectionBooks) as? Bool ?? false
        self.libraryFeatureEnabled = Self.storedLibraryFeatureEnabled(in: defaults)
        self.fileBrowserFeatureEnabled = Self.storedFileBrowserFeatureEnabled(in: defaults)
        self.smartLibraryFeatureEnabled = Self.storedSmartLibraryFeatureEnabled(in: defaults)
        self.showRecentFavoritesOnWelcome =
            defaults.object(forKey: Keys.showRecentFavoritesOnWelcome) as? Bool ?? true
        self.thumbnailHoverPreviewDelay = defaults.object(forKey: Keys.thumbnailHoverPreviewDelay) as? Double ?? 0.35
        // 既定値440は、設定にする前に各所へ直接書かれていた値そのもの(見た目を変えないため)。
        self.thumbnailHoverPreviewSize = defaults.object(forKey: Keys.thumbnailHoverPreviewSize) as? Double ?? 440
        self.preloadThumbnailGridPreviews =
            defaults.object(forKey: Keys.preloadThumbnailGridPreviews) as? Bool ?? false
        self.launchInPrivateMode = defaults.object(forKey: Keys.launchInPrivateMode) as? Bool ?? false
        self.thumbnailDiskCacheEnabled =
            defaults.object(forKey: Keys.thumbnailDiskCacheEnabled) as? Bool ?? false
        // MB の値は**範囲へ収めて読む**(2026-09-14 の監査)。どれもバイト数へ `Int(_:)` で換算するので、手で書き換えた・壊れた
        // plist の NaN や巨大な値が起動時のトラップになっていた(`Int(Double)` は非有限・範囲外で落ちる)。
        self.thumbnailDiskCacheLimitMB = Self.storedMegabytes(
            defaults.object(forKey: Keys.thumbnailDiskCacheLimitMB),
            default: Self.defaultThumbnailDiskCacheLimitMB, range: Self.thumbnailDiskCacheLimitRangeMB
        )
        self.fileBrowserThumbnailCacheEnabled =
            defaults.object(forKey: Keys.fileBrowserThumbnailCacheEnabled) as? Bool ?? true
        self.fileBrowserThumbnailCacheLimitMB = Self.storedMegabytes(
            defaults.object(forKey: Keys.fileBrowserThumbnailCacheLimitMB),
            default: Self.defaultFileBrowserThumbnailCacheLimitMB, range: Self.fileBrowserThumbnailCacheLimitRangeMB
        )
        self.pageImageCacheLimitMB = Self.storedMegabytes(
            defaults.object(forKey: Keys.pageImageCacheLimitMB),
            default: Self.defaultPageImageCacheLimitMB, range: Self.pageImageCacheLimitRangeMB
        )
        self.nestedArchiveMemoryLimitMB = Self.storedMegabytes(
            defaults.object(forKey: Keys.nestedArchiveMemoryLimitMB),
            default: Self.defaultNestedArchiveMemoryLimitMB, range: Self.nestedArchiveMemoryLimitRangeMB
        )

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
            key: Keys.bookExportDestinationMode, fallback: .askEachTime, defaults: defaults
        )
        self.bookExportDataCleanups = Self.loadFormatSettings(
            key: Keys.bookExportDataCleanup, fallback: .keep, defaults: defaults
        )
        self.bookExportHistoryCleanups = Self.loadFormatSettings(
            key: Keys.bookExportHistoryCleanup, fallback: .keep, defaults: defaults
        )
        self.bookExportRenumbersImages = Self.loadFormatFlags(
            key: Keys.bookExportRenumbersImages, fallback: { $0 == .cbz }, defaults: defaults
        )
        self.bookExportIncludesExcludedPages = Self.loadFormatFlags(
            key: Keys.bookExportIncludesExcludedPages, fallback: { _ in false }, defaults: defaults
        )
        self.bookExportWritesVolumeElement =
            defaults.object(forKey: Keys.bookExportWritesVolumeElement) as? Bool ?? false

        // すべてのプロパティが揃ってから、サムネイルのディスクキャッシュへ設定を届ける
        // (didSetは初期化中には走らないので、ここで一度だけ明示的に呼ぶ必要がある)。
        // OFF(既定)ならこの呼び出しが、溜まっているキャッシュの削除の合図にもなる。
        applyThumbnailDiskCacheSettings()
        applyFileBrowserThumbnailCacheSettings()
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
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        apply(AppPreferences(defaults: defaults), for: pane)
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
                Keys.showRecentFavoritesOnWelcome,
                Keys.offersRemovingMissingCollectionBooks,
                Keys.libraryFeatureEnabled,
                Keys.fileBrowserFeatureEnabled,
                Keys.smartLibraryFeatureEnabled,
                Keys.sidePanelFeatureEnabled,
                Keys.sidePanelPosition,
                Keys.sidePanelUsesDoubleClick,
                Keys.sidePanelSortOrder,
                Keys.siblingNavigationFollowsBrowserSort,
            ]
        case .appearance:
            // 外観タブの設定は AppearanceSettings が揃いごとに持ち、「初期設定に戻す」も編集中の揃いに対して
            // AppearanceSettings.resetToDefaults() で行う(AppearanceSettingsView.rootPage)。ここで戻すものは無い。
            return []
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
                Keys.fileBrowserThumbnailCacheEnabled,
                Keys.fileBrowserThumbnailCacheLimitMB,
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
        case .fileBrowser:
            return [
                Keys.fileBrowserStartupLocation,
                Keys.fileBrowserStartupFavoriteID,
                Keys.fileBrowserFoldersFirst,
                Keys.fileBrowserExternalDropAction,
                Keys.fileBrowserExpandsTreeToCurrentFolder,
                Keys.fileBrowserTreeFollowsListSort,
                Keys.fileBrowserCompressionFormat,
                Keys.fileBrowserVideoThumbnailsEnabled,
                Keys.fileBrowserRevealDestination,
                Keys.fileBrowserReadOnly,
                Keys.fileBrowserImageFolderOpenAction,
            ]
        // 「読み込みと書き出し」はウインドウを開くボタンだけで、戻せる設定を持たない。
        case .keyboard, .mouse, .modeInput, .access, .dataTransfer, .reset:
            return []
        }
    }

    /// 保存先を読み直して、いまの設定をまるごと入れ替える(保存データの取り込みが `UserDefaults` を
    /// 書き替えたあとに呼ぶ。2026-09-23)。
    ///
    /// 画面ごとの `apply(_:for:)` を全画面ぶん回したうえで、**どの画面にも並んでいない設定**を
    /// 足している。`keys(for:)` は「その画面に実際に並んでいる項目だけ」を対象にしていて
    /// (あちらのコメント)、「表示」メニューやパネル自身が変える値・保管件数の 2 つは外れている ――
    /// 「初期設定に戻す」では外して正しいが、**バックアップから戻すときは全部戻す**のが正しい。
    ///
    /// キー/マウスの割り当ては `KeyBindingStore` が持つので、呼び出し側がそちらの
    /// `reloadFromDefaults()` も呼ぶこと(外観は `AppearanceSettings.copyValues(from:)`)。
    func reloadFromDefaults() {
        let fresh = AppPreferences(defaults: defaults)
        for pane in SettingsPane.allCases {
            apply(fresh, for: pane)
        }
        // 画面ごとの担当から外してある設定(keys(for:) のコメント)。
        maxTrackedBooksCount = fresh.maxTrackedBooksCount
        recentFilesLimit = fresh.recentFilesLimit
        hideToolbar = fresh.hideToolbar
        hideProgressBar = fresh.hideProgressBar
        hideSidePanel = fresh.hideSidePanel
        sidePanelWidth = fresh.sidePanelWidth
        sidePanelMode = fresh.sidePanelMode
        folderBrowserSortKey = fresh.folderBrowserSortKey
        folderBrowserSortDirection = fresh.folderBrowserSortDirection
        defaultReadingDirection = fresh.defaultReadingDirection
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
            showRecentFavoritesOnWelcome = source.showRecentFavoritesOnWelcome
            offersRemovingMissingCollectionBooks = source.offersRemovingMissingCollectionBooks
            libraryFeatureEnabled = source.libraryFeatureEnabled
            fileBrowserFeatureEnabled = source.fileBrowserFeatureEnabled
            smartLibraryFeatureEnabled = source.smartLibraryFeatureEnabled
            sidePanelFeatureEnabled = source.sidePanelFeatureEnabled
            sidePanelPosition = source.sidePanelPosition
            sidePanelUsesDoubleClick = source.sidePanelUsesDoubleClick
            sidePanelSortOrder = source.sidePanelSortOrder
            siblingNavigationFollowsBrowserSort = source.siblingNavigationFollowsBrowserSort
        case .appearance:
            // keys(for:)の.appearance参照(外観は AppearanceSettings が戻す)。
            break
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
            fileBrowserThumbnailCacheEnabled = source.fileBrowserThumbnailCacheEnabled
            fileBrowserThumbnailCacheLimitMB = source.fileBrowserThumbnailCacheLimitMB
        case .layout:
            missingLayoutAutoLayout = source.missingLayoutAutoLayout
            bookExportCompletionBehavior = source.bookExportCompletionBehavior
            bookExportDestinationModes = source.bookExportDestinationModes
            bookExportDataCleanups = source.bookExportDataCleanups
            bookExportHistoryCleanups = source.bookExportHistoryCleanups
            bookExportRenumbersImages = source.bookExportRenumbersImages
            bookExportIncludesExcludedPages = source.bookExportIncludesExcludedPages
            bookExportWritesVolumeElement = source.bookExportWritesVolumeElement
        case .fileBrowser:
            fileBrowserStartupLocation = source.fileBrowserStartupLocation
            fileBrowserStartupFavoriteID = source.fileBrowserStartupFavoriteID
            fileBrowserFoldersFirst = source.fileBrowserFoldersFirst
            fileBrowserExternalDropAction = source.fileBrowserExternalDropAction
            fileBrowserExpandsTreeToCurrentFolder = source.fileBrowserExpandsTreeToCurrentFolder
            fileBrowserTreeFollowsListSort = source.fileBrowserTreeFollowsListSort
            fileBrowserCompressionFormat = source.fileBrowserCompressionFormat
            fileBrowserVideoThumbnailsEnabled = source.fileBrowserVideoThumbnailsEnabled
            fileBrowserRevealDestination = source.fileBrowserRevealDestination
            fileBrowserReadOnly = source.fileBrowserReadOnly
            fileBrowserImageFolderOpenAction = source.fileBrowserImageFolderOpenAction
        case .keyboard, .mouse, .modeInput, .access, .dataTransfer, .reset:
            break
        }
    }
}
