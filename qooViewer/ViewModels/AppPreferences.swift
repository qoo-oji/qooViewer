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
        static let maxTrackedBooksCount = "qooViewer.pref.maxTrackedBooksCount"
        static let hideToolbar = "qooViewer.pref.hideToolbar"
        static let hideProgressBar = "qooViewer.pref.hideProgressBar"
        static let showProgressBarThumbnailPreview = "qooViewer.pref.showProgressBarThumbnailPreview"
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
        self.maxTrackedBooksCount = defaults.object(forKey: Keys.maxTrackedBooksCount) as? Double ?? 500
        self.hideToolbar = defaults.object(forKey: Keys.hideToolbar) as? Bool ?? false
        self.hideProgressBar = defaults.object(forKey: Keys.hideProgressBar) as? Bool ?? false
        self.showProgressBarThumbnailPreview =
            defaults.object(forKey: Keys.showProgressBarThumbnailPreview) as? Bool ?? true
    }
}
