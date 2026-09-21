import AppKit
import Combine
import SwiftUI

/// 本のウインドウ(ホーム・ビューア。ContentView)のタイトルバーを、環境設定「外観」の「タイトルバーの色」で塗る
/// (AppearanceSettings.titleBarColor。2026-09-22、ユーザー要望)。
///
/// ■ 塗り方
/// タイトルバーを透明にし、その下に見えるウインドウの地の色(`NSWindow.backgroundColor`)を指定の色にする。
/// 透明にするのは SwiftUI の `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` で、AppKit の
/// `titlebarAppearsTransparent` を直接立てない ―― 立てても SwiftUI が更新のたびに(BarAppearanceBridge.updateWindowToolbar)
/// ツールバーの地の設定から false へ書き戻す(2026-09-22 に KVO で呼び出し元まで実測)。SwiftUI の設定として渡せば、
/// SwiftUI 自身が true を保つ。地の色のほうは SwiftUI が触らないので AppKit で塗る。
/// タブバーを出したときは、タブバーの帯も同じ色になる(タブの形はその上に描かれる。実測)。
///
/// SwiftUI の中身でタイトルバーの下を塗る方法(`.fullSizeContentView` + 上端まで広げた背景)は採れない ――
/// ContentView はツールバーを隠したときの不具合を避けるために `.fullSizeContentView` を外していて、
/// 内容領域はタイトルバーの下に存在しない(ContentView の WindowAccessor のコメント参照)。
/// ウインドウの地の色なら、内容領域の外(タイトルバー)にだけ効かせられる。
///
/// ■ 地の色は内容領域にも透ける
/// ウインドウの地の色は、内容が何も塗っていない場所(すりガラスを敷いていないホームなど)にも見える。
/// そこが標準の地の色のままに見えるよう、色を指定している間は ContentView が内容領域の最下層に
/// `windowBackgroundColor` を敷く(下の WindowChromeModifier)。
///
/// ■ 文字の色は変えられない
/// タイトルの文字と信号機ボタンは外観(ライト/ダーク)に従って描かれ、公開 API では色を指定できない。
/// 暗い色を選んだらダークの外観と組み合わせる、といった判断は使う人に委ねる(環境設定の説明文に書いてある)。
enum WindowTitleBarColor {
    /// `color` が nil ならシステムの標準のタイトルバーへ戻す。同じ値を何度呼んでもよい
    /// (WindowAccessor と設定の変化の両方から呼ばれる)。
    static func apply(_ color: RGBColorValue?, to window: NSWindow) {
        if let color {
            // RGBColorValue は sRGB の値(型コメント参照)なので、sRGB として組み立てる。
            window.backgroundColor = NSColor(
                srgbRed: CGFloat(color.red) / 255,
                green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255,
                alpha: 1
            )
        } else {
            window.backgroundColor = .windowBackgroundColor
        }
    }
}

/// 本のウインドウのライト/ダーク(2026-09-22、ユーザー要望)。
///
/// ノーマルの揃いの外観モードはアプリ全体(`NSApp.appearance`。AppAppearanceApplier)に効き、ウインドウはそれを継ぐ。
/// シークレットウインドウが自分の揃いを使っている間だけ、そのウインドウに自分のライト/ダークを掛ける。
/// シートやポップオーバー、右クリックのメニュー、そのウインドウから開く原寸表示のウインドウ(ViewerView.showActualSizeWindow)は
/// このウインドウの外観を継ぐ。環境設定・補助ウインドウ・メニューバーはノーマルのまま(ユーザーの決定)。
///
/// ■ `NSWindow.appearance` ではなく `.preferredColorScheme` で掛ける
/// AppKit で `NSWindow.appearance` を入れても、SwiftUI が更新のたびに(AppKitWindowController.hostingView(_:willUpdate:))
/// 環境の「好みの配色」から書き戻して nil に戻す(2026-09-22 に KVO で呼び出し元まで実測 ―― タイトルバーの透明と同じ話)。
/// SwiftUI の設定として渡せば、SwiftUI 自身がそのウインドウの外観を保つ。nil は「好み無し」= アプリ全体の外観を継ぐ。
/// なお「コントラストを上げる」の高コントラスト版は `ColorScheme` では指定できない(明示指定のときは素のライト/ダークになる)。
enum WindowAppearance {
    static func colorScheme(for settings: AppearanceSettings) -> ColorScheme? {
        guard settings.profile == .privateWindow else { return nil }
        switch settings.appAppearance {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            // アプリ全体もシステムに従っているなら、継ぐだけでシステムの外観になる。アプリ全体がライト/ダークに
            // 決め打ちされているときは継げないので、システムの外観を自分で引く(SystemAppearanceObserver)。
            guard NSApp.appearance != nil else { return nil }
            return SystemAppearanceObserver.isDark ? .dark : .light
        }
    }
}

/// システムのライト/ダークの切り替わりを知らせる(WindowAppearance の「システムに従う」用)。
///
/// アプリ全体をライト/ダークに決め打ちしていると、アプリの中からはシステムの外観が見えない(`NSApp.effectiveAppearance` は
/// 決め打ちした外観を返す)。システムの外観はグローバルドメインの `AppleInterfaceStyle`("Dark" か無し)で読み、
/// 切り替わりは分散通知 `AppleInterfaceThemeChangedNotification` で知る(macOS の定番の手段。受け取るだけなので
/// サンドボックスでも届く)。
@MainActor
final class SystemAppearanceObserver: ObservableObject {
    static let shared = SystemAppearanceObserver()

    /// 切り替わるたびに1つ進む。値そのものに意味は無く、onChange の合図にだけ使う。
    @Published private(set) var revision = 0

    static var isDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            // 弱参照は外側で1回だけ強参照にしてから Task へ渡す(AppAppearanceApplier の購読と同じ書き方)。
            guard let self else { return }
            Task { @MainActor in self.revision += 1 }
        }
    }
}

extension View {
    /// ContentView の最下層に付ける。そのウインドウの外観の揃い(環境の AppearanceSettings)に合わせて、ライト/ダークを掛け、
    /// タイトルバーの色を塗り直し、タイトルバーの色を指定している間は内容領域に標準の地の色を敷く。
    func windowChrome(window: NSWindow?) -> some View {
        modifier(WindowChromeModifier(window: window))
    }
}

private struct WindowChromeModifier: ViewModifier {
    @EnvironmentObject private var appearance: AppearanceSettings
    /// システムのライト/ダークの切り替わりで colorScheme を引き直すため(値は読まないが、観察して描き直させる)。
    @ObservedObject private var systemAppearance = SystemAppearanceObserver.shared
    /// ノーマルの揃いのライト/ダーク(= アプリ全体の外観)。シークレットの揃いが「システムに従う」のとき、アプリ全体が
    /// 決め打ちかどうかで答えが変わる(WindowAppearance.colorScheme)ので、変わったら引き直す。
    @EnvironmentObject private var preferences: AppPreferences
    @State private var appAppearanceRevision = 0
    /// 弱く持つ ―― View の値が閉じたウインドウを生かし続けないように(CLAUDE.md「Menu bar ↔ viewer bridging」の
    /// リークの話と同じ用心)。
    weak var window: NSWindow?

    func body(content: Content) -> some View {
        let color = appearance.titleBarColor
        let _ = appAppearanceRevision
        content
            // シークレットウインドウが自分の揃いを使っている間のライト/ダーク(WindowAppearance)。
            .preferredColorScheme(WindowAppearance.colorScheme(for: appearance))
            // タイトルバーを透明にする(WindowTitleBarColor の型コメント「塗り方」。AppKit で立てても SwiftUI が書き戻す)。
            .toolbarBackgroundVisibility(color != nil ? .hidden : .automatic, for: .windowToolbar)
            // 色を指定している間は、ウインドウの地の色がその色になり、内容が何も塗っていない場所
            // (すりガラスを敷いていないホームなど)にも透ける。内容領域は標準の地の色のままに見せる。
            .background {
                if color != nil {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .onReceive(preferences.appearance.$appAppearance.dropFirst()) { _ in
                // didSet より前(willSet)に届くので、NSApp.appearance が掛け替わってから引き直す。
                Task { @MainActor in appAppearanceRevision += 1 }
            }
            // ウインドウが決まった時点の一度目は ContentView の WindowAccessor が塗る。揃いが入れ替わった(「別の外観を使う」を
            // 切り替えた)ときも色が変わる。
            .onChange(of: color) { _, newColor in
                guard let window else { return }
                WindowTitleBarColor.apply(newColor, to: window)
            }
    }
}
