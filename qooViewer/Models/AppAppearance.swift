import AppKit
import SwiftUI

/// アプリの外観(ライト/ダーク)。**macOSのシステム設定とは独立して**選べる(ユーザー要望)。
///
/// 表示言語(AppLanguage)とまったく同じ形 ―― 「システムに従う」+ 明示指定 ―― にしてある。
/// 実際にアプリへ反映するのはAppAppearanceApplier(下)。
enum AppAppearance: String, CaseIterable, Identifiable, Codable, Hashable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// この設定が実際に対応するNSAppearance。「システムに従う」の場合はnil
    /// (`NSApp.appearance`にnilを入れると、macOS側のシステム外観をそのまま継承する)。
    ///
    /// - Parameter increasesContrast: システム設定「アクセシビリティ ▸ ディスプレイ ▸
    ///   コントラストを上げる」がONかどうか。ONのときに素の`.aqua`/`.darkAqua`を渡すと、
    ///   **このアプリだけが高コントラストの外観から外れてしまう**ため、対応する
    ///   高コントラスト版の外観を選ぶ。
    func nsAppearance(increasesContrast: Bool) -> NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: increasesContrast ? .accessibilityHighContrastAqua : .aqua)
        case .dark:
            return NSAppearance(named: increasesContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
        }
    }
}

/// 選ばれた外観をアプリ全体へ適用する役。
///
/// ■ なぜSwiftUIの`.preferredColorScheme`ではなく`NSApp.appearance`なのか
/// `.preferredColorScheme`は、それを付けたビュー(が載っているウインドウ)にしか効かない。
/// このアプリはウインドウの中身以外にもAppKitのUIを多数出しており ―― 起動時の
/// SwiftDataの復旧ダイアログ(NSAlert)、ファイル選択ダイアログ、カラーパネル、
/// Dockアイコンのメニュー、メニューバー ―― それらには届かない。
/// `NSApp.appearance`ならSwiftUIのウインドウも含めてアプリ内のすべてが一度に切り替わり、
/// 各ビューの`@Environment(\.colorScheme)`も、ウインドウのeffectiveAppearance経由で
/// そのまま追従する(すりガラスの面の文字色や輪郭もこの値を見ている。
/// PanelSurfaceBackground参照)。
@MainActor
final class AppAppearanceApplier {
    static let shared = AppAppearanceApplier()

    /// 最後に適用した設定。「コントラストを上げる」が切り替わったときの再適用に使う。
    private var current: AppAppearance = .system
    private var contrastObserver: NSObjectProtocol?

    private init() {}

    func apply(_ appearance: AppAppearance) {
        current = appearance
        // `NSApplication.shared`は、まだ起動処理が始まっていなくても必ずインスタンスを返すので、
        // 起動のごく初期 ―― 最初のウインドウが出るより前 ―― に呼んでも安全。最初の1フレーム目から
        // 選んだ外観で描かれるよう、AppPreferences.init()の最後で一度呼んでいる
        // (ウインドウが出てから切り替えると、既定の外観が一瞬見えてしまう)。
        NSApplication.shared.appearance = appearance.nsAppearance(
            increasesContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        installContrastObserverIfNeeded()
    }

    /// 「コントラストを上げる」の切り替えに追従するための購読。システム外観に任せている間は
    /// macOS自身が面倒を見てくれるので不要で、一度でも明示指定になったときだけ必要になる
    /// (アプリの生存期間中に1回だけ張り、以後は外さない ―― この型はsharedしか無い)。
    private func installContrastObserverIfNeeded() {
        guard contrastObserver == nil, current != .system else { return }
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .mainで届くが、クロージャ自体はメインアクター隔離ではないため、
            // AppKitに触る処理はTask { @MainActor in ... }へ渡す。弱参照は外側で1回だけ
            // 強参照に変換してから内側のTaskへ渡す(AppDelegate.applicationDidFinishLaunchingの
            // 通知購読と同じ書き方。並行実行されるコードから弱参照を読むと警告になる)。
            guard let self else { return }
            Task { @MainActor in
                self.apply(self.current)
            }
        }
    }
}
