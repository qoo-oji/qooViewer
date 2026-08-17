import SwiftUI

/// 環境設定ウインドウ(Cmd+, で開く)。一般設定・開く・描画・閲覧・キー/マウス設定・アクセス権・
/// リセットのタブを持つ。以前は「一般」タブに画像描画やページ送り/スライドショーの設定も
/// 含まれていたが、項目が増えて長くなったため、「描画」(RenderingSettingsView)と
/// 「閲覧」(ReadingSettingsView)の2つのタブに分離した。その後も「一般」タブの項目数が
/// 増え続けたため、本を開き直す/Finderやお気に入りから開く際の挙動と見開き表示中の
/// ブックマーク追加先に関する設定を、「開く」(OpeningSettingsView)タブとしてさらに分離した。
///
/// 「リセット」(ResetDataSettingsView)は、すべてのお気に入り・ブックマーク・読書履歴を
/// 強制的に削除する、非常に強力な操作専用のタブ。他のタブに混在させず独立させることで、
/// 誤って触れてしまう可能性を下げている(ユーザーからの要望)。
///
/// ■ ウインドウ幅について
/// 幅は480 → 580ptに広げてある。これは「ラベルが折り返す」問題への対処ではない
/// (それはSettingsControls.swiftの行コンポーネント側で解決している)。
/// 目的は、行が横並びレイアウト(左ラベル/右コントロール)に収まる確率を上げて、
/// タブ内で縦積みの行と横並びの行が混在してガタつくのを防ぐこと。
/// 高さは最も縦に長い「キー/マウス設定」タブに合わせている。
///
/// ■ タブ名は1語の名詞に統一してある
/// macOSのタブは内容に合わせて幅が決まるため、ラベルの長さがそのまま不揃いになる。
/// 英語で「Key & Mouse Bindings」「Access Permissions」だけが突出して長く、
/// タブバーが不格好に見えていた(ユーザーからの指摘)。
/// Apple純正の環境設定も General / Appearance / Privacy / Advanced のように1語で揃えているので、
/// それぞれ「Input」「Access」へ短縮した(日本語も「キー・マウス操作」→「入力」)。
/// タブ名はウインドウのタイトルにもそのまま出るため、短いほうが収まりもよい。
/// 意味が落ちるぶんは、各タブのSectionヘッダとfooterが補っている。
///
/// ■ 将来: タブが増え続けるなら TabView をやめる
/// 現在7タブで、macOSのタブバーは横一列なのでこれ以上増やすと1つあたりが狭くなり、
/// ラベルが省略され始める。8つ目が必要になった時点で、TabViewではなく
/// NavigationSplitView(システム設定/Xcode方式のサイドバー)へ移すことを勧める。
/// 各タブのViewはすでに `SettingsTabContainer` で包まれた自己完結な `Form` なので、
/// 移行時に触るのはこのファイルだけで済むようにしてある。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            OpeningSettingsView()
                .tabItem { Label("Opening", systemImage: "book.pages") }
            RenderingSettingsView()
                .tabItem { Label("Rendering", systemImage: "paintpalette") }
            ReadingSettingsView()
                .tabItem { Label("Reading", systemImage: "book") }
            KeyBindingSettingsView()
                .tabItem { Label("Input", systemImage: "keyboard") }
            ModeInputSettingsView()
                .tabItem { Label("Input 2", systemImage: "square.split.2x1") }
            AccessPermissionsSettingsView()
                .tabItem { Label("Access", systemImage: "lock.shield") }
            ResetDataSettingsView()
                .tabItem { Label("Reset", systemImage: "exclamationmark.triangle") }
        }
        .frame(width: 580, height: 500)
    }
}
