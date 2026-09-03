import Combine
import SwiftUI

/// 環境設定ウインドウを「この画面の、この場所」を開いた状態で呼び出すための橋渡し。
///
/// ■ なぜ必要か
/// ツールバー・プログレスバー・サイドパネル・ページ一覧パネルを右クリックしたときの「調整…」
/// (PanelPartContextMenu参照)から、環境設定「外観」画面の**対応する面のページ**へ
/// 直接飛べるようにしたい、というユーザー要望のためのもの。環境設定ウインドウを開く操作
/// そのものはSwiftUIの`openSettings`が持っているが、`openSettings`には「どの画面を開くか」
/// 「どの面のページを開くか」を伝える口が無い。そこで、開く**前に**行き先をここへ置いておき、
/// 環境設定側(SettingsView / AppearanceSettingsView)がそれを拾う、という形にしている。
///
/// ■ 行き先は「面」そのもの
/// 以前の「外観」画面は全部の面のセクションを1枚に縦に並べていて、行き先は
/// 「そのセクションまでスクロールする位置」だった(ページ一覧だけ、すりガラスではなく
/// サムネイルのセクションを指す別のcaseがあった)。面ごとの設定を子ページへ分けてからは
/// (AppearanceSettingsView参照)、行き先は「どの面の子ページを開くか」の1つになり、
/// ページ一覧のサムネイル設定もその面の子ページの中にあるので、`PanelSurface`だけで表せる。
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

    /// 「外観」画面を開いたときに子ページとして開く面。開き終わったらnilへ戻す
    /// (次に環境設定を開いたときに、前回の行き先へ勝手に飛ばないようにするため)。
    @Published var appearanceTarget: PanelSurface?

    /// 「外観」画面で**いま開いている**面の子ページ。nilなら一覧。
    ///
    /// 上の`appearanceTarget`(これから開く行き先)とは別に持つ。`AppearanceSettingsView`の
    /// 中の`@State`にせずここに置いてあるのは、「戻る」ボタンが`SettingsView`のツールバー
    /// (ウインドウのタイトルバー)にあり、どの画面を開いていても同じ場所に出るため
    /// (SettingsView.backButton参照)。環境設定ウインドウはアプリに1つなので、状態も1つでよい。
    @Published var openedAppearanceSurface: PanelSurface?

    private init() {}

    /// 環境設定の「外観」画面を選び、指定した面の子ページを行き先として覚える。
    /// ウインドウを実際に開く(または前面に出す)のは呼び出し側の`openSettings()`の役目。
    /// **こちらを先に呼ぶこと** ―― 開いた後に行き先を書いても、既に組み上がった画面が
    /// 拾える保証が無いため。
    func prepareAppearance(opening surface: PanelSurface) {
        UserDefaults.standard.set(SettingsPane.appearance.rawValue, forKey: Self.selectedPaneDefaultsKey)
        appearanceTarget = surface
    }
}
