import AppKit
import Combine
import SwiftUI

/// 外観の設定のひと揃いが、どのウインドウのためのものか(2026-09-22、ユーザー要望)。
///
/// ノーマルウインドウ用(`.normal`)が従来からの設定で、保存キーも従来のまま。シークレットウインドウ用(`.privateWindow`)は
/// 環境設定「外観」の「シークレットウインドウに別の外観を使う」を ON にしたときだけ使われ、同じキーの末尾に
/// `.privateWindow` を付けた別のキーへ保存する(AppPreferences.privateWindowsUseOwnAppearance参照)。
nonisolated enum AppearanceProfile: String, CaseIterable, Hashable, Sendable {
    case normal
    case privateWindow

    /// この揃いの保存キー。ノーマルは従来のキーそのもの(既存の利用者の設定をそのまま読むため)。
    func key(_ base: String) -> String {
        switch self {
        case .normal: base
        case .privateWindow: base + ".privateWindow"
        }
    }
}

/// 環境設定「外観」タブの設定一式(2026-09-22 に AppPreferences から切り出した)。
///
/// ■ なぜ AppPreferences から分けたのか
/// ノーマルウインドウとシークレットウインドウで別々の外観を使えるようにするため(ユーザー要望)。外観タブの設定は
/// **全部**が対象で(ユーザーの決定)、同じ名前の設定が2揃い同時に生きている必要がある。1つの AppPreferences の中に
/// 2揃いを持たせると、読む側(ページ一覧・プログレスバー・すりガラスの面など)がどのウインドウの値かを毎回選ぶ
/// ことになるので、揃いを1つの型にし、ウインドウごとに環境オブジェクトとして渡す(ContentView。どちらを渡すかは
/// AppPreferences.appearance(forPrivateWindow:))。読む側は `@EnvironmentObject var appearance: AppearanceSettings`
/// を見るだけで、自分がどちらのウインドウにいるかを知らなくてよい。
///
/// 本のウインドウ以外(環境設定・補助ウインドウ・メニューバー)はノーマルの揃いを見る(QooViewerApp が
/// どのシーンにも `preferences.appearance` を渡す)。
///
/// ■ ライト/ダーク(appAppearance)
/// ノーマルの揃いの値だけがアプリ全体(`NSApp.appearance`)に効く(`appliesToApp`)。シークレットの揃いの値は、
/// そのウインドウの `NSWindow.appearance` として ContentView が掛ける(WindowAppearance参照)。
///
/// 各設定のコメントは AppPreferences にあった頃のまま(「keys(for:)」とあるのは、いまはこの型の `allKeys`)。
@MainActor
final class AppearanceSettings: ObservableObject {
    enum Keys {
        static let backgroundColorOption = "qooViewer.pref.backgroundColorOption"
        static let customBackgroundColor = "qooViewer.pref.customBackgroundColor"
        static let toolbarRevealDelay = "qooViewer.pref.toolbarRevealDelay"
        static let progressBarRevealDelay = "qooViewer.pref.progressBarRevealDelay"
        static let sidePanelRevealDelay = "qooViewer.pref.sidePanelRevealDelay"
        static let toolbarDockedGlass = "qooViewer.pref.toolbarDockedGlass"
        static let progressBarDockedGlass = "qooViewer.pref.progressBarDockedGlass"
        static let sidePanelDockedGlass = "qooViewer.pref.sidePanelDockedGlass"
        static let welcomeGlass = "qooViewer.pref.welcomeGlass"
        static let collectionCoverCaptionStyle = "qooViewer.pref.collectionCoverCaptionStyle"
        static let collectionCoverCaptionFontSize = "qooViewer.pref.collectionCoverCaptionFontSize"
        static let collectionTileNameFontSize = "qooViewer.pref.collectionTileNameFontSize"
        static let collectionTileBadgeSize = "qooViewer.pref.collectionTileBadgeSize"
        static let collectionTileBackgroundColor = "qooViewer.pref.collectionTileBackgroundColor"
        static let appAppearance = "qooViewer.pref.appAppearance"
        static let titleBarColor = "qooViewer.pref.titleBarColor"
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
        static let thumbnailGridCellSize = "qooViewer.pref.thumbnailGridCellSize"
        static let thumbnailGridHorizontalSpacing = "qooViewer.pref.thumbnailGridHorizontalSpacing"
        static let thumbnailGridVerticalSpacing = "qooViewer.pref.thumbnailGridVerticalSpacing"
        static let thumbnailGridHorizontalMarginPercent = "qooViewer.pref.thumbnailGridHorizontalMarginPercent"
        static let thumbnailGridVerticalMarginPercent = "qooViewer.pref.thumbnailGridVerticalMarginPercent"
        static let showThumbnailHoverPreview = "qooViewer.pref.showThumbnailHoverPreview"
        static let thumbnailGridCaptionStyle = "qooViewer.pref.thumbnailGridCaptionStyle"
        static let thumbnailGridCaptionFontSize = "qooViewer.pref.thumbnailGridCaptionFontSize"
        static let thumbnailGridBorderColorOption = "qooViewer.pref.thumbnailGridBorderColorOption"
        static let thumbnailGridBorderCustomColor = "qooViewer.pref.thumbnailGridBorderCustomColor"
        static let thumbnailGridWheelScrollRows = "qooViewer.pref.thumbnailGridWheelScrollRows"
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

    let profile: AppearanceProfile
    private let defaults: UserDefaults
    /// ノーマルの揃いで、かつ実際のアプリの保存先のときだけ、ライト/ダークをアプリ全体へ掛ける
    /// (テストの suite では外へ出る副作用を起こさない。AppPreferences.sharesGlobalState と同じ考え方)。
    private let appliesToApp: Bool

    /// ビューワーの背景色(プリセット、または「カスタム」)
    @Published var backgroundColorOption: BackgroundColorOption {
        didSet { defaults.set(backgroundColorOption.rawValue, forKey: profile.key(Keys.backgroundColorOption)) }
    }
    /// `backgroundColorOption`が`.custom`のときに使う、ユーザーが自分で指定した背景色。
    /// 環境設定「外観」の「ビューア」→「背景色」で「カスタム」を選ぶと開くダイアログ
    /// (CustomColorPickerSheet)で編集する。
    ///
    /// プリセット側(`backgroundColorOption`)とは独立に保存しているので、いったんプリセットの
    /// 黒に戻してから再び「カスタム」を選び直しても、作った色はそのまま残る。
    @Published var customBackgroundColor: RGBColorValue {
        didSet {
            defaults.set(customBackgroundColor.hexString, forKey: profile.key(Keys.customBackgroundColor))
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
        didSet { defaults.set(toolbarRevealDelay, forKey: profile.key(Keys.toolbarRevealDelay)) }
    }
    /// プログレスバー側の同じもの(toolbarRevealDelay参照)。
    @Published var progressBarRevealDelay: Double {
        didSet { defaults.set(progressBarRevealDelay, forKey: profile.key(Keys.progressBarRevealDelay)) }
    }
    /// サイドパネル側の同じもの(toolbarRevealDelay参照)。こちらのきっかけは左右どちらかの
    /// 端の帯(ContentView.updateSidePanelReveal参照)。
    @Published var sidePanelRevealDelay: Double {
        didSet { defaults.set(sidePanelRevealDelay, forKey: profile.key(Keys.sidePanelRevealDelay)) }
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
        didSet { defaults.set(toolbarDockedGlass, forKey: profile.key(Keys.toolbarDockedGlass)) }
    }
    /// プログレスバー側の同じもの(toolbarDockedGlass参照)。
    @Published var progressBarDockedGlass: Bool {
        didSet { defaults.set(progressBarDockedGlass, forKey: profile.key(Keys.progressBarDockedGlass)) }
    }
    /// サイドパネル側の同じもの(toolbarDockedGlass参照)。
    @Published var sidePanelDockedGlass: Bool {
        didSet { defaults.set(sidePanelDockedGlass, forKey: profile.key(Keys.sidePanelDockedGlass)) }
    }
    /// ウェルカム画面版の同じもの(toolbarDockedGlass参照。既定OFFの理由も同じ)。
    /// ウェルカム画面には「隠す」状態が無いので、これは画面全体のすりガラス
    /// (と面の設定一式)を使うかどうかのスイッチになる。OFFなら従来どおり、
    /// ウインドウの地の色のまま何も敷かない(WelcomeView参照)。
    @Published var welcomeGlass: Bool {
        didSet { defaults.set(welcomeGlass, forKey: profile.key(Keys.welcomeGlass)) }
    }
    /// コレクションの中で、本のカバーの下に何を書くか(CollectionCoverCaptionStyle参照)。
    /// 既定は「表示しない」= 従来どおりカバーだけが並ぶ。
    ///
    /// すりガラスの設定ではないが、**ウェルカム画面の見え方を決める設定はウェルカム画面の
    /// ページに揃える**という「外観」の方針(AppearanceSettingsView冒頭)に従って、
    /// 環境設定「外観」→「ウェルカム画面」に置いてある。
    @Published var collectionCoverCaptionStyle: CollectionCoverCaptionStyle {
        didSet {
            defaults.set(collectionCoverCaptionStyle.rawValue, forKey: profile.key(Keys.collectionCoverCaptionStyle))
        }
    }
    /// カバーの下の文字の大きさ(pt)。
    ///
    /// 既定の10ptは、設定にする前に使っていた`.caption`の実寸そのもの ―― 既定値のままなら
    /// 見た目は1ピクセルも変わらない(filmstripFontSize / thumbnailGridCaptionFontSizeと
    /// 同じ考え方)。**範囲もページ一覧の「文字の大きさ」と揃えてある**(片方だけ別の範囲にしない)。
    @Published var collectionCoverCaptionFontSize: Double {
        didSet {
            defaults.set(collectionCoverCaptionFontSize, forKey: profile.key(Keys.collectionCoverCaptionFontSize))
        }
    }
    static let collectionCoverCaptionFontSizeRange: ClosedRange<Double> = 8...20

    /// コレクションの一覧(札)で、札の下に出るコレクション名の文字の大きさ(pt)。
    ///
    /// 既定の13ptは、設定にする前の`Text`の既定(macOSの`.body` = システムのフォントサイズ)
    /// そのもの ―― 既定値のままなら見た目は1ピクセルも変わらない。範囲は上の2つと揃える。
    @Published var collectionTileNameFontSize: Double {
        didSet {
            defaults.set(collectionTileNameFontSize, forKey: profile.key(Keys.collectionTileNameFontSize))
        }
    }
    static let collectionTileNameFontSizeRange: ClosedRange<Double> = 8...20

    /// コレクションの札の右下に出す冊数バッジの大きさ(ユーザー要望 2026-09-13。
    /// CollectionTileBadgeSize参照)。既定の`.small`は設定にする前の大きさ。
    @Published var collectionTileBadgeSize: CollectionTileBadgeSize {
        didSet {
            defaults.set(collectionTileBadgeSize.rawValue, forKey: profile.key(Keys.collectionTileBadgeSize))
        }
    }

    /// コレクションの一覧(札)の地の色。**nil = 既定**(`defaultCollectionTileBackground`)。
    ///
    /// ■ ライブラリごとの設定から、アプリ全体で1つの設定へ移した(ユーザー指示 2026-09-09)
    /// 最初はライブラリ1つ分の設定(ウェルカム画面の歯車 → LibrarySettingsPopover)として
    /// `BookLibrary.coverBackgroundColorRaw`に持たせていたが、棚の地の色はライブラリを
    /// 切り替えるたびに変わってよいものではない ―― 帯でライブラリを選び直すたびに一覧の
    /// 地の色が入れ替わると、同じアプリの同じ画面には見えなくなる。カバーの形と切り取る
    /// 位置(こちらはライブラリごとのまま)と違って、これは「アプリの外観」の設定なので、
    /// 環境設定「外観」→「パネル」→「ウェルカム画面」の「ライブラリ」へ移した。
    ///
    /// ■ nilを残してあるのは、既定の地が明暗の外観に追従するため
    /// 既定は`Color.primary.opacity(0.07)`= ライト/ダークのどちらにも馴染む薄い地で、
    /// 色を1つ決め打ちで保存するとこの追従が失われる。「未指定」を別の状態として持ち、
    /// 「初期設定に戻す」とは別に、行の右の矢印ボタンでいつでもここへ戻せる。
    @Published var collectionTileBackgroundColor: RGBColorValue? {
        didSet {
            // nilは「キーごと消す」。空文字などの番人を書くと、既定値の判定が
            // 「無い or 空」の2通りになってしまう。
            if let hexString = collectionTileBackgroundColor?.hexString {
                defaults.set(hexString, forKey: profile.key(Keys.collectionTileBackgroundColor))
            } else {
                defaults.removeObject(forKey: profile.key(Keys.collectionTileBackgroundColor))
            }
        }
    }

    /// 本のウインドウ(ホーム・ビューア)のタイトルバーの色(環境設定「外観」→「アプリ」。2026-09-22、ユーザー要望)。
    ///
    /// nil(既定)は「システムの標準のタイトルバー」。札の地の色(collectionTileBackgroundColor)と同じく「未指定」を
    /// 別の状態として持つ ―― 標準のタイトルバーは明暗の外観に追従する素材で、1色に決め打ちするとそれが失われるため。
    /// 塗り方は WindowTitleBarColor(ウインドウの地の色 + 透明なタイトルバー)。
    @Published var titleBarColor: RGBColorValue? {
        didSet {
            // nilは「キーごと消す」(collectionTileBackgroundColorと同じ理由)。
            if let hexString = titleBarColor?.hexString {
                defaults.set(hexString, forKey: profile.key(Keys.titleBarColor))
            } else {
                defaults.removeObject(forKey: profile.key(Keys.titleBarColor))
            }
        }
    }

    /// 色を指定していないときの札の地(明暗どちらの外観にも馴染む薄い地)。
    static let defaultCollectionTileBackground = Color.primary.opacity(0.07)

    /// 実際に札の地を塗るのに使う色。既定とカスタムの解決をここ1箇所に集約し、
    /// 表示側(CollectionGridView)がnilの扱いを持たなくて済むようにしている
    /// (`effectiveBackgroundColor`と同じ形)。
    var effectiveCollectionTileBackground: Color {
        collectionTileBackgroundColor?.color ?? Self.defaultCollectionTileBackground
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

    /// アプリの外観(ライト/ダーク。既定は「システムに従う」)。
    /// 表示言語と同じく、macOSのシステム設定とは独立して選べる(ユーザー要望)。
    /// 表示言語はSceneごとの`.environment(\.locale, ...)`で効かせるが、こちらはウインドウの外の
    /// AppKitのUI(ダイアログ・カラーパネル・Dockメニュー)にも効かせる必要があるため、
    /// SwiftUIではなくNSApp.appearanceで反映する(AppAppearanceApplierの型コメント参照)。
    @Published var appAppearance: AppAppearance {
        didSet {
            defaults.set(appAppearance.rawValue, forKey: profile.key(Keys.appAppearance))
            if appliesToApp { AppAppearanceApplier.shared.apply(appAppearance) }
        }
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
            defaults.set(
                showProgressBarThumbnailPreview,
                forKey: profile.key(Keys.showProgressBarThumbnailPreview)
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
        didSet { defaults.set(filmstripThumbnailCount, forKey: profile.key(Keys.filmstripThumbnailCount)) }
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
            defaults.set(filmstripCaptionStyle.rawValue, forKey: profile.key(Keys.filmstripCaptionStyle))
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
        didSet { defaults.set(filmstripFontSize, forKey: profile.key(Keys.filmstripFontSize)) }
    }
    static let filmstripFontSizeRange: ClosedRange<Double> = 8...20

    /// カーソル位置以外のサムネイルを暗くするか(既定ON=従来どおり)。
    ///
    /// ONのときは、カーソル直下のセル**以外**の画像と文字を少し暗くして、直下のセルが
    /// 相対的に目立つようにする。暗くされたページの中身を読み取りたい場合に邪魔になる
    /// (画像そのものが暗いページでは特に)ため、OFFにできるようにした。OFFでも、
    /// カーソル直下のセルは枠・光彩・ページ番号バッジの色で区別が付く。
    @Published var filmstripDimsOtherPages: Bool {
        didSet { defaults.set(filmstripDimsOtherPages, forKey: profile.key(Keys.filmstripDimsOtherPages)) }
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
            defaults.set(
                filmstripHighlightColorOption.rawValue, forKey: profile.key(Keys.filmstripHighlightColorOption)
            )
        }
    }
    /// 上が`.custom`のときに使うRGB値(thumbnailGridBorderCustomColorとまったく同じ考え方)。
    @Published var filmstripHighlightCustomColor: RGBColorValue {
        didSet {
            defaults.set(
                filmstripHighlightCustomColor.hexString, forKey: profile.key(Keys.filmstripHighlightCustomColor)
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
            defaults.set(
                filmstripHighlightBorderWidth, forKey: profile.key(Keys.filmstripHighlightBorderWidth)
            )
        }
    }
    static let filmstripHighlightBorderWidthRange: ClosedRange<Double> = 1...8

    // MARK: - ページ一覧(サムネイルグリッド)。ユーザー要望: サイズ・間隔・余白を調整したい

    /// ページ一覧のサムネイル1枚の大きさ(pt、正方形の一辺)。パネル上部のスライダーと
    /// 環境設定「閲覧中の動作」の両方から同じ値を変える。以前は120pt固定だった。
    @Published var thumbnailGridCellSize: Double {
        didSet { defaults.set(thumbnailGridCellSize, forKey: profile.key(Keys.thumbnailGridCellSize)) }
    }
    static let thumbnailGridCellSizeRange: ClosedRange<Double> = 80...320
    /// サムネイル同士の横の間隔(pt)。
    @Published var thumbnailGridHorizontalSpacing: Double {
        didSet { defaults.set(thumbnailGridHorizontalSpacing, forKey: profile.key(Keys.thumbnailGridHorizontalSpacing)) }
    }
    /// サムネイル同士の縦の間隔(pt)。
    @Published var thumbnailGridVerticalSpacing: Double {
        didSet { defaults.set(thumbnailGridVerticalSpacing, forKey: profile.key(Keys.thumbnailGridVerticalSpacing)) }
    }
    static let thumbnailGridSpacingRange: ClosedRange<Double> = 0...40
    /// パネルの左右に残す余白(画像表示領域の幅に対する片側の%)。列数は残りの幅から自動で決まる。
    @Published var thumbnailGridHorizontalMarginPercent: Double {
        didSet { defaults.set(thumbnailGridHorizontalMarginPercent, forKey: profile.key(Keys.thumbnailGridHorizontalMarginPercent)) }
    }
    /// パネルの上下に残す余白(画像表示領域の高さに対する片側の%)。
    @Published var thumbnailGridVerticalMarginPercent: Double {
        didSet { defaults.set(thumbnailGridVerticalMarginPercent, forKey: profile.key(Keys.thumbnailGridVerticalMarginPercent)) }
    }
    static let thumbnailGridMarginPercentRange: ClosedRange<Double> = 0...40

    /// サムネイルの下に何を書くか(ThumbnailCaptionStyle参照)。既定はこれまでどおりページ番号。
    @Published var thumbnailGridCaptionStyle: ThumbnailCaptionStyle {
        didSet {
            defaults.set(thumbnailGridCaptionStyle.rawValue, forKey: profile.key(Keys.thumbnailGridCaptionStyle))
        }
    }
    /// サムネイルの下の文字の大きさ(pt)。既定の11ptは、従来使っていた`.caption2`の実寸に
    /// 合わせたもの(値を変えていない人の見た目が変わらないようにするため)。
    @Published var thumbnailGridCaptionFontSize: Double {
        didSet {
            defaults.set(thumbnailGridCaptionFontSize, forKey: profile.key(Keys.thumbnailGridCaptionFontSize))
        }
    }
    /// 下限8ptは、Retinaでもぎりぎり字形が潰れない大きさ。上限20ptは、サムネイルの最小サイズ
    /// (80pt)に対して文字が主役になってしまわない範囲。
    static let thumbnailGridCaptionFontSizeRange: ClosedRange<Double> = 8...20

    /// 表示中のページを示す枠の色(プリセット、または「カスタム」)。ユーザー要望。
    @Published var thumbnailGridBorderColorOption: PageBorderColorOption {
        didSet {
            defaults.set(thumbnailGridBorderColorOption.rawValue, forKey: profile.key(Keys.thumbnailGridBorderColorOption))
        }
    }
    /// 上が`.custom`のときに使うRGB値。`customBackgroundColor`とまったく同じ考え方で、
    /// プリセットへ戻してからカスタムを選び直しても、作った色はそのまま残る。
    @Published var thumbnailGridBorderCustomColor: RGBColorValue {
        didSet {
            defaults.set(thumbnailGridBorderCustomColor.hexString, forKey: profile.key(Keys.thumbnailGridBorderCustomColor))
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
            defaults.set(thumbnailGridWheelScrollRows, forKey: profile.key(Keys.thumbnailGridWheelScrollRows))
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
        didSet { Self.save(pageListSurfaceStyle, for: .pageList, profile: profile, defaults: defaults) }
    }
    /// ツールバーの背景(自動的に隠す設定のときに重ねて表示される帯)。
    @Published var toolbarSurfaceStyle: PanelSurfaceStyle {
        didSet { Self.save(toolbarSurfaceStyle, for: .toolbar, profile: profile, defaults: defaults) }
    }
    /// プログレスバーの背景(同上)。
    @Published var progressBarSurfaceStyle: PanelSurfaceStyle {
        didSet { Self.save(progressBarSurfaceStyle, for: .progressBar, profile: profile, defaults: defaults) }
    }
    /// サイドパネルの背景。
    @Published var sidePanelSurfaceStyle: PanelSurfaceStyle {
        didSet { Self.save(sidePanelSurfaceStyle, for: .sidePanel, profile: profile, defaults: defaults) }
    }
    /// 上記以外の浮かぶ表示(「情報を見る」パネル・トースト・拡大率表示)の背景。
    @Published var welcomeSurfaceStyle: PanelSurfaceStyle {
        didSet { Self.save(welcomeSurfaceStyle, for: .welcome, profile: profile, defaults: defaults) }
    }
    @Published var overlaySurfaceStyle: PanelSurfaceStyle {
        didSet { Self.save(overlaySurfaceStyle, for: .overlays, profile: profile, defaults: defaults) }
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

    private static func save(
        _ style: PanelSurfaceStyle, for surface: PanelSurface, profile: AppearanceProfile, defaults: UserDefaults
    ) {
        defaults.set(style.materialOpacity, forKey: profile.key(Keys.panelSurfaceMaterialOpacity(surface)))
        defaults.set(style.tintColor.hexString, forKey: profile.key(Keys.panelSurfaceTintColor(surface)))
        defaults.set(style.tintOpacity, forKey: profile.key(Keys.panelSurfaceTintOpacity(surface)))
        defaults.set(style.contentShadowLevel, forKey: profile.key(Keys.panelSurfaceContentShadowLevel(surface)))
    }

    /// 保存済みの設定を読む。1つでも欠けていればその項目だけ既定値で補う
    /// (面を後から増やしたときに、既存ユーザーの環境で既定値が使われるようにするため)。
    private static func loadSurfaceStyle(
        for surface: PanelSurface, profile: AppearanceProfile, defaults: UserDefaults
    ) -> PanelSurfaceStyle {
        let fallback = surface.defaultStyle
        let materialOpacity =
            defaults.object(forKey: profile.key(Keys.panelSurfaceMaterialOpacity(surface))) as? Double
            ?? fallback.materialOpacity
        let tintColor =
            (defaults.string(forKey: profile.key(Keys.panelSurfaceTintColor(surface))).flatMap(RGBColorValue.init(hexString:)))
            ?? fallback.tintColor
        let tintOpacity =
            defaults.object(forKey: profile.key(Keys.panelSurfaceTintOpacity(surface))) as? Double
            ?? fallback.tintOpacity
        let contentShadowLevel =
            defaults.object(forKey: profile.key(Keys.panelSurfaceContentShadowLevel(surface))) as? Int
            ?? fallback.contentShadowLevel
        return PanelSurfaceStyle(
            materialOpacity: materialOpacity, tintColor: tintColor, tintOpacity: tintOpacity,
            contentShadowLevel: contentShadowLevel
        )
    }

    /// ページ一覧のサムネイルにカーソルを合わせたとき拡大プレビュー(ポップオーバー)を出すか。
    /// OFFにしたい、というユーザー要望。**ページ一覧だけ**に効く。サイドパネルのページモード・
    /// ブックマーク編集・書き出しウインドウの同種のプレビューには効かせない(それらのサムネイルは
    /// サイズ調整が無く、拡大が無いと何のページか分からなくなるため。ユーザー指示)。
    @Published var showThumbnailHoverPreview: Bool {
        didSet { defaults.set(showThumbnailHoverPreview, forKey: profile.key(Keys.showThumbnailHoverPreview)) }
    }

    init(profile: AppearanceProfile, defaults: UserDefaults) {
        self.profile = profile
        self.defaults = defaults
        self.appliesToApp = profile == .normal && defaults === UserDefaults.standard
        self.backgroundColorOption =
            BackgroundColorOption(rawValue: defaults.string(forKey: profile.key(Keys.backgroundColorOption)) ?? "") ?? .black
        self.customBackgroundColor =
            RGBColorValue(hexString: defaults.string(forKey: profile.key(Keys.customBackgroundColor)) ?? "")
            ?? Self.defaultCustomBackgroundColor
        // 既定は0(待たずに表示)。この設定を入れる前と同じ挙動にしておく。
        self.toolbarRevealDelay = defaults.object(forKey: profile.key(Keys.toolbarRevealDelay)) as? Double ?? 0
        self.progressBarRevealDelay = defaults.object(forKey: profile.key(Keys.progressBarRevealDelay)) as? Double ?? 0
        self.sidePanelRevealDelay = defaults.object(forKey: profile.key(Keys.sidePanelRevealDelay)) as? Double ?? 0
        self.appAppearance = AppAppearance(rawValue: defaults.string(forKey: profile.key(Keys.appAppearance)) ?? "") ?? .system
        self.showProgressBarThumbnailPreview =
            defaults.object(forKey: profile.key(Keys.showProgressBarThumbnailPreview)) as? Bool ?? true
        // フィルムストリップの見た目。既定値はどれも「これまでの見た目と1ピクセルも変わらない」値
        // (9枚・10pt・暗くする・アクセントカラー・3pt)。
        self.filmstripThumbnailCount =
            defaults.object(forKey: profile.key(Keys.filmstripThumbnailCount)) as? Double ?? 9
        self.filmstripFontSize = defaults.object(forKey: profile.key(Keys.filmstripFontSize)) as? Double ?? 10
        self.filmstripCaptionStyle =
            FilmstripCaptionStyle(rawValue: defaults.string(forKey: profile.key(Keys.filmstripCaptionStyle)) ?? "")
            ?? .fileNameAndPageNumber
        self.filmstripDimsOtherPages =
            defaults.object(forKey: profile.key(Keys.filmstripDimsOtherPages)) as? Bool ?? true
        self.filmstripHighlightColorOption =
            PageBorderColorOption(rawValue: defaults.string(forKey: profile.key(Keys.filmstripHighlightColorOption)) ?? "")
            ?? .accent
        self.filmstripHighlightCustomColor =
            defaults.string(forKey: profile.key(Keys.filmstripHighlightCustomColor)).flatMap(RGBColorValue.init(hexString:))
            ?? Self.defaultFilmstripHighlightCustomColor
        self.filmstripHighlightBorderWidth =
            defaults.object(forKey: profile.key(Keys.filmstripHighlightBorderWidth)) as? Double ?? 3
        self.thumbnailGridCellSize = defaults.object(forKey: profile.key(Keys.thumbnailGridCellSize)) as? Double ?? 120
        self.thumbnailGridHorizontalSpacing =
            defaults.object(forKey: profile.key(Keys.thumbnailGridHorizontalSpacing)) as? Double ?? 10
        self.thumbnailGridVerticalSpacing =
            defaults.object(forKey: profile.key(Keys.thumbnailGridVerticalSpacing)) as? Double ?? 10
        self.thumbnailGridHorizontalMarginPercent =
            defaults.object(forKey: profile.key(Keys.thumbnailGridHorizontalMarginPercent)) as? Double ?? 10
        self.thumbnailGridVerticalMarginPercent =
            defaults.object(forKey: profile.key(Keys.thumbnailGridVerticalMarginPercent)) as? Double ?? 5
        self.showThumbnailHoverPreview = defaults.object(forKey: profile.key(Keys.showThumbnailHoverPreview)) as? Bool ?? true
        self.thumbnailGridCaptionStyle =
            ThumbnailCaptionStyle(rawValue: defaults.string(forKey: profile.key(Keys.thumbnailGridCaptionStyle)) ?? "")
            ?? .pageNumber
        self.thumbnailGridCaptionFontSize =
            defaults.object(forKey: profile.key(Keys.thumbnailGridCaptionFontSize)) as? Double ?? 11
        self.thumbnailGridBorderColorOption =
            PageBorderColorOption(rawValue: defaults.string(forKey: profile.key(Keys.thumbnailGridBorderColorOption)) ?? "")
            ?? .accent
        self.thumbnailGridBorderCustomColor =
            defaults.string(forKey: profile.key(Keys.thumbnailGridBorderCustomColor)).flatMap(RGBColorValue.init(hexString:))
            ?? Self.defaultThumbnailGridBorderCustomColor
        self.thumbnailGridWheelScrollRows =
            defaults.object(forKey: profile.key(Keys.thumbnailGridWheelScrollRows)) as? Double ?? 1
        self.pageListSurfaceStyle = Self.loadSurfaceStyle(for: .pageList, profile: profile, defaults: defaults)
        self.toolbarSurfaceStyle = Self.loadSurfaceStyle(for: .toolbar, profile: profile, defaults: defaults)
        self.progressBarSurfaceStyle = Self.loadSurfaceStyle(for: .progressBar, profile: profile, defaults: defaults)
        self.sidePanelSurfaceStyle = Self.loadSurfaceStyle(for: .sidePanel, profile: profile, defaults: defaults)
        self.welcomeSurfaceStyle = Self.loadSurfaceStyle(for: .welcome, profile: profile, defaults: defaults)
        self.overlaySurfaceStyle = Self.loadSurfaceStyle(for: .overlays, profile: profile, defaults: defaults)
        // 背後を透かすすりガラスの4スイッチ。既定OFF(toolbarDockedGlassのコメント参照)。
        self.toolbarDockedGlass = defaults.object(forKey: profile.key(Keys.toolbarDockedGlass)) as? Bool ?? false
        self.progressBarDockedGlass =
            defaults.object(forKey: profile.key(Keys.progressBarDockedGlass)) as? Bool ?? false
        self.sidePanelDockedGlass =
            defaults.object(forKey: profile.key(Keys.sidePanelDockedGlass)) as? Bool ?? false
        self.welcomeGlass = defaults.object(forKey: profile.key(Keys.welcomeGlass)) as? Bool ?? false
        self.collectionCoverCaptionStyle =
            CollectionCoverCaptionStyle(
                rawValue: defaults.string(forKey: profile.key(Keys.collectionCoverCaptionStyle)) ?? ""
            ) ?? .none
        self.collectionCoverCaptionFontSize =
            defaults.object(forKey: profile.key(Keys.collectionCoverCaptionFontSize)) as? Double ?? 10
        self.collectionTileNameFontSize =
            defaults.object(forKey: profile.key(Keys.collectionTileNameFontSize)) as? Double ?? 13
        self.collectionTileBadgeSize =
            CollectionTileBadgeSize(
                rawValue: defaults.string(forKey: profile.key(Keys.collectionTileBadgeSize)) ?? ""
            ) ?? .small
        self.collectionTileBackgroundColor =
            defaults.string(forKey: profile.key(Keys.collectionTileBackgroundColor))
            .flatMap(RGBColorValue.init(hexString:))
        self.titleBarColor = defaults.string(forKey: profile.key(Keys.titleBarColor)).flatMap(RGBColorValue.init(hexString:))
        // didSet は初期化では走らないので、ライト/ダークはここから1回。最初のウインドウが作られるより前
        // (AppStores 経由で QooViewerApp.init() から呼ばれる)なので、既定の外観が一瞬見えてから切り替わる、ということにはならない。
        if appliesToApp { AppAppearanceApplier.shared.apply(appAppearance) }
    }

    // MARK: - 揃いごと写す・戻す

    /// この揃いが使う保存キー(ノーマルなら従来のキー、シークレットなら末尾に `.privateWindow`)のすべて。
    /// 設定を1つ足したら**ここにも足すこと**(AppearanceSettingsTests が網羅を確かめる)。
    var allKeys: [String] {
        let plain: [String] = [
            // アプリ全体のライト/ダーク。画面上もこの画面のいちばん上にある
            // (AppearanceSettingsView.appSection参照)。
            Keys.appAppearance,
            Keys.titleBarColor,
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
            // 「キャッシュ」画面へ移した(AppPreferences.keys(for:)のcase .cache参照)。
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
            // コレクションのカバーの下の表示も、画面上は「外観」→「ウェルカム画面」に
            // ある(PanelSurfaceSettingsView.welcomeSection参照)。
            Keys.collectionCoverCaptionStyle,
            Keys.collectionCoverCaptionFontSize,
            Keys.collectionTileNameFontSize,
            Keys.collectionTileBadgeSize,
            Keys.collectionTileBackgroundColor,
        ]
        // 面ごとの設定を1つ増やしたら**ここにも足すこと**。resetToDefaults() は保存先から読み直すので、キーを消し忘れると
        // 古い値がそのまま戻ってきて「初期設定に戻す」が効かない(ユーザー報告: 「文字の影」だけリセットされない)。
        let surfaces = PanelSurface.allCases.flatMap {
            [
                Keys.panelSurfaceMaterialOpacity($0),
                Keys.panelSurfaceTintColor($0),
                Keys.panelSurfaceTintOpacity($0),
                Keys.panelSurfaceContentShadowLevel($0),
            ]
        }
        return (plain + surfaces).map(profile.key)
    }

    /// 別の揃いの値をすべて写す。代入で各プロパティの didSet が走り、この揃いのキーへ書かれる。
    /// シークレットの揃いを初めて使うときにノーマルの値から始める(AppPreferences.privateWindowsUseOwnAppearance)のと、
    /// 「初期設定に戻す」(下)に使う。設定を1つ足したら**ここにも足すこと**(テストが名前を挙げて落ちる)。
    func copyValues(from source: AppearanceSettings) {
        backgroundColorOption = source.backgroundColorOption
        customBackgroundColor = source.customBackgroundColor
        toolbarRevealDelay = source.toolbarRevealDelay
        progressBarRevealDelay = source.progressBarRevealDelay
        sidePanelRevealDelay = source.sidePanelRevealDelay
        toolbarDockedGlass = source.toolbarDockedGlass
        progressBarDockedGlass = source.progressBarDockedGlass
        sidePanelDockedGlass = source.sidePanelDockedGlass
        welcomeGlass = source.welcomeGlass
        collectionCoverCaptionStyle = source.collectionCoverCaptionStyle
        collectionCoverCaptionFontSize = source.collectionCoverCaptionFontSize
        collectionTileNameFontSize = source.collectionTileNameFontSize
        collectionTileBadgeSize = source.collectionTileBadgeSize
        collectionTileBackgroundColor = source.collectionTileBackgroundColor
        titleBarColor = source.titleBarColor
        appAppearance = source.appAppearance
        showProgressBarThumbnailPreview = source.showProgressBarThumbnailPreview
        filmstripThumbnailCount = source.filmstripThumbnailCount
        filmstripCaptionStyle = source.filmstripCaptionStyle
        filmstripFontSize = source.filmstripFontSize
        filmstripDimsOtherPages = source.filmstripDimsOtherPages
        filmstripHighlightColorOption = source.filmstripHighlightColorOption
        filmstripHighlightCustomColor = source.filmstripHighlightCustomColor
        filmstripHighlightBorderWidth = source.filmstripHighlightBorderWidth
        thumbnailGridCellSize = source.thumbnailGridCellSize
        thumbnailGridHorizontalSpacing = source.thumbnailGridHorizontalSpacing
        thumbnailGridVerticalSpacing = source.thumbnailGridVerticalSpacing
        thumbnailGridHorizontalMarginPercent = source.thumbnailGridHorizontalMarginPercent
        thumbnailGridVerticalMarginPercent = source.thumbnailGridVerticalMarginPercent
        thumbnailGridCaptionStyle = source.thumbnailGridCaptionStyle
        thumbnailGridCaptionFontSize = source.thumbnailGridCaptionFontSize
        thumbnailGridBorderColorOption = source.thumbnailGridBorderColorOption
        thumbnailGridBorderCustomColor = source.thumbnailGridBorderCustomColor
        thumbnailGridWheelScrollRows = source.thumbnailGridWheelScrollRows
        showThumbnailHoverPreview = source.showThumbnailHoverPreview
        for surface in PanelSurface.allCases {
            setSurfaceStyle(source.surfaceStyle(for: surface), for: surface)
        }
    }

    /// 環境設定「外観」の「初期設定に戻す」。**この揃いだけ**を出荷時の値へ戻す(もう一方の揃いには触れない)。
    ///
    /// 先にキーを消してから、既定値だけを持つ揃い(消した後の保存先から読み直したもの)を写す ―― キーを消し忘れると
    /// 読み直しで古い値が戻ってくるので、`allKeys` の網羅が効く(AppPreferences.resetToDefaults と同じ作り)。
    func resetToDefaults() {
        for key in allKeys {
            defaults.removeObject(forKey: key)
        }
        copyValues(from: AppearanceSettings(profile: profile, defaults: defaults))
    }
}
