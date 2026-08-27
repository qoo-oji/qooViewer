import Combine
import SwiftUI

/// 環境設定「外観」画面の中の、スクロールの行き先になれるセクション。
///
/// 面ごとのセクション(すりガラスの濃さ・重ね色・文字の輪郭・表示までの時間)は
/// `PanelSurface`から機械的に生成されている(AppearanceSettingsView.surfaceSection参照)ため
/// `.surface(_)`でまとめて表せるが、「ページ一覧」のセクション(サムネイルの大きさ・間隔・
/// 余白・枠の色)だけはその生成の外にある独立したセクションなので、別のcaseとして持つ。
enum AppearanceSection: Hashable {
    /// 「ページ一覧」セクション。ページ一覧パネルの中身(サムネイル)の見え方。
    case pageList
    /// すりガラスの面1つ分のセクション。
    case surface(PanelSurface)
}

/// 環境設定ウインドウを「この画面の、この場所」を開いた状態で呼び出すための橋渡し。
///
/// ■ なぜ必要か
/// ツールバー・プログレスバー・サイドパネル・ページ一覧パネルを右クリックしたときの「調整…」
/// (PanelPartContextMenu参照)から、環境設定「外観」画面の**対応するセクション**へ
/// 直接飛べるようにしたい、というユーザー要望のためのもの。環境設定ウインドウを開く操作
/// そのものはSwiftUIの`openSettings`が持っているが、`openSettings`には「どの画面を開くか」
/// 「どこまでスクロールするか」を伝える口が無い。そこで、開く**前に**行き先をここへ置いておき、
/// 環境設定側(SettingsView / AppearanceSettingsView)がそれを拾う、という形にしている。
///
/// ■ シングルトンである理由
/// 環境設定ウインドウはアプリ全体で1つ(`Settings`シーン)なのに対し、呼び出し元の
/// ビューアウインドウは何枚でも開ける。ウインドウごとに持つAppStateに載せると、
/// 「どのウインドウから開かれた環境設定か」を環境設定側が知る必要が出てしまう。
/// 行き先はアプリに1つで足りるため、アプリ全体で共有する1つの箱にしてある。
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()

    /// SettingsViewが`@AppStorage`で読み書きしているのと同じUserDefaultsのキー。
    /// 画面の切り替えはこのキーへ書き込むだけで済む(`@AppStorage`は外部からの変更も拾う)ので、
    /// SettingsViewへ選択用の口を新設する必要が無い。**キーの綴りが2箇所に散らないよう、
    /// SettingsView側もこの定数を参照している。**
    static let selectedPaneDefaultsKey = "qooViewer.settings.selectedPane"

    /// 「外観」画面を開いたときにスクロールして見せるセクション。見せ終わったらnilへ戻す
    /// (次に環境設定を開いたときに、前回の行き先へ勝手に飛ばないようにするため)。
    @Published var appearanceTarget: AppearanceSection?

    private init() {}

    /// 環境設定の「外観」画面を選び、指定したセクションを行き先として覚える。
    /// ウインドウを実際に開く(または前面に出す)のは呼び出し側の`openSettings()`の役目。
    /// **こちらを先に呼ぶこと** ―― 開いた後に行き先を書いても、既に組み上がった画面が
    /// 拾える保証が無いため。
    func prepareAppearance(scrollingTo section: AppearanceSection) {
        UserDefaults.standard.set(SettingsPane.appearance.rawValue, forKey: Self.selectedPaneDefaultsKey)
        appearanceTarget = section
    }
}
