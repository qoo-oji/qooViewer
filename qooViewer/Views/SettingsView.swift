import SwiftUI

/// 環境設定ウインドウ(Cmd+, で開く)。
/// 左のサイドバーで画面を選び、右にその中身を出す、macOSのシステム設定と同じ2ペイン構成。
///
/// ■ TabViewからの移行(2ペイン化)
/// 以前は `TabView` で、1タブ=1画面だった。項目が増えるたびにタブを分けてきた経緯があり、
///   - 「一般」が長くなりすぎたので「描画」「閲覧」を分離
///   - さらに「一般」から、本を開く際の挙動を「開く」として分離
///   - キー/マウス設定のうち、表示モードで意味が変わるものを「入力2」として分離
/// 最終的に8タブになった。macOSのタブバーは横一列なので、これ以上増やすと1つあたりが
/// 狭くなってラベルが省略され始める。旧 `SettingsView` のコメントには
/// 「8つ目が必要になった時点で `NavigationSplitView` へ移すこと」と書き残してあり、
/// 各画面を `SettingsPaneContainer` で包んで自己完結にしてあったのはこの移行のためだった。
/// 実際、移行にあたって8画面のどれも中身を書き換えずに済んでいる。
///
/// ■ タブ名の1語縛りを解いた
/// `TabView` 時代は「入力」「入力2」「アクセス権」のようにラベルを1語へ切り詰めていた。
/// これはmacOSのタブが内容幅で並ぶため、1つだけ長いラベルがあるとタブバーが不揃いに
/// 見えるという **レイアウト上の制約への対処** であって、その名前が最適だったからではない
/// (ユーザーからの指摘で短縮した経緯)。サイドバーは全行が同じ幅の縦並びなので制約が消えた。
/// 「入力2」のような開くまで中身の分からない名前をやめ、意味の通る名前へ戻してある
/// (`SettingsPane.titleKey` 参照)。
///
/// ■ 画面の一覧はここには無い
/// サイドバーの行・右ペインの中身・ウインドウタイトルは、すべて `SettingsPane` から導出される。
/// 画面を1つ増やすときにこのファイルを触る必要は無い(`SettingsPane` にcaseを足すだけ)。
/// このファイルが持つのは、2ペインの枠・寸法・選択状態の永続化だけに限定してある。
struct SettingsView: View {
    /// 前回開いていた画面を次回も開く。
    /// 8画面もあると、毎回「一般」から目的の画面まで探し直すことになるため
    /// (macOSのシステム設定も直前の画面を憶えている)。
    /// 保存済みの値が未知の文字列だった場合(将来caseを削除・改名したときなど)は
    /// `@AppStorage` が既定値を返すので、「一般」が開くだけで壊れない。
    @AppStorage("qooViewer.settings.selectedPane") private var selectedPane: SettingsPane = .general

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            detail
        }
        // (`columnVisibility: .constant(.all)` について)
        // 環境設定の画面選択はサイドバーが常に見えていることが前提なので、
        // 「サイドバーを畳んだまま次回も開いてしまう」状態を作らせない。
        // 固定するだけではドラッグで幅0にされうるため、サイドバー側にも最小幅を与えてある
        // (sidebar の navigationSplitViewColumnWidth)。
        //
        // ■ ここでのframeが決めるのは「リサイズできる範囲」
        // `Settings` シーンは常に `.windowResizability(.contentSize)` で動き、その指定を
        // 上書きすることもできない(QooViewerApp.swift の Settings 参照)。
        // つまり**中身のframeの上下限が、そのままウインドウのリサイズ可能範囲になる**。
        // 上限を省くとウインドウが1ミリも動かせない固定サイズになってしまうため、
        // `maxWidth`/`maxHeight` に `.infinity` を明示している(消さないこと)。
        //
        // 初回に開いたときの大きさはここではなく、Sceneの `.defaultSize(width:height:)` が決める。
        // `idealWidth`/`idealHeight` をここに書いても初期サイズにはならない
        // ―― あれはウインドウメニューの「拡大/縮小」(Zoom)用であって、初期表示用ではない。
        //
        // 最小幅760ptは「サイドバー最小200 + 右ペイン最小560」の合計。
        // 右ペインの560ptは、TabView時代のウインドウ幅(580pt)をほぼ引き継いだもので、
        // 「行が横並びレイアウト(左ラベル/右コントロール)に収まる確率を上げて、
        // 画面内で縦積みの行と横並びの行が混在してガタつくのを防ぐ」ために決めた幅
        // (SettingsControls.swift の SettingRow 参照)。2ペインになっても根拠は変わらない。
        //
        // 最小高さ440ptは、最も縦に長い「キーとマウス」画面に合わせたものではない。
        // 長い画面は右ペインが自前でスクロールするので、全画面が一度に収まる必要はなく、
        // 「サイドバーの8項目とグループ見出しが省略されずに全部見える高さ」を下限にしてある。
        // なお実際に縮められる下限はこの値ちょうどではなく、これとサイドバーの中身が必要とする
        // 高さの大きいほうになる(実測で約470pt)。ここを下げてもそれ以上は縮まない。
        .frame(
            minWidth: 760, maxWidth: .infinity,
            minHeight: 440, maxHeight: .infinity
        )
        // `Settings` シーンのウインドウはリサイズ不可の状態で作られるため、AppKit側で
        // `.resizable` を足す(理由と根拠は SettingsWindowResizabilityAccessor を参照)。
        // 上のframeの上下限は、そのままリサイズ可能な範囲として使われる。
        .background(SettingsWindowResizabilityAccessor())
    }

    // MARK: - サイドバー

    private var sidebar: some View {
        List(selection: paneSelection) {
            ForEach(SettingsPaneGroup.populated) { group in
                Section {
                    ForEach(group.panes) { pane in
                        NavigationLink(value: pane) {
                            Label {
                                Text(pane.titleKey)
                            } icon: {
                                SettingsPaneIcon(pane: pane)
                            }
                        }
                    }
                } header: {
                    if let titleKey = group.titleKey {
                        // SwiftUIのサイドバーのSectionヘッダは既定だと小さすぎ・薄すぎて、
                        // グループの区切りとして読み取れない(ユーザーからの指摘。
                        // 一度 .subheadline(11pt)まで上げたが、それでもまだ見づらいという再指摘)。
                        //
                        // 寸法は相対指定(.subheadline など)ではなくptで直に指定している。
                        // 相対指定の各段は本文サイズを基準に決まっており、
                        // 「本文より一回り大きく、かつ太い」という**見出しに要る組み合わせ**が
                        // そのままでは作れないため(.headlineは太いが本文と同じ大きさ、
                        // .title3は大きいが見出しとしては大きすぎる)。
                        // 項目名が13ptなので、+1ptとboldで一段上に立たせている。
                        Text(titleKey)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                }
                .headerProminence(.increased)
            }
        }
        // 環境設定にサイドバーを畳むボタンは要らない(畳んだら画面を選べなくなる)。
        // ウインドウ全体のツールバーを隠す方法もあるが、それだとタイトルバーの見た目まで
        // 変わってしまうため、このボタンだけを外す。
        .toolbar(removing: .sidebarToggle)
        // 最小幅は最も長い項目名(日本語の「フォルダのアクセス権」)が省略されない幅。
        // 上限を設けているのは、広げたときにサイドバーだけが伸びて右ペインが
        // 置いていかれるのを防ぐため。
        .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
    }

    /// サイドバーの選択。`nil`(選択解除)は無視する。
    ///
    /// `List` は空白部分のクリックやCmd+クリックで選択を外そうとするが、環境設定では
    /// 「どの画面も選ばれていない」状態に意味が無く、右ペインが空になるだけなので、
    /// 直前の選択をそのまま保つ。
    private var paneSelection: Binding<SettingsPane?> {
        Binding(
            get: { selectedPane },
            set: { newValue in
                guard let newValue else { return }
                selectedPane = newValue
            }
        )
    }

    // MARK: - 右ペイン

    private var detail: some View {
        selectedPane.destination
            // ウインドウのタイトルバーに、いま開いている画面の名前を出す
            // (システム設定と同じ。TabView時代もタブ名がタイトルに出ていた)。
            .navigationTitle(Text(selectedPane.titleKey))
            .navigationSplitViewColumnWidth(min: 560, ideal: 605)
    }
}

// MARK: - サイドバーのアイコン

/// サイドバー1行分のアイコン。角丸の色付きタイルに、白抜きのSF Symbolを載せる
/// (macOSのシステム設定と同じ表現)。
///
/// ■ なぜ素の `Label` + SF Symbol にしないのか
/// 見た目の好みではなく、寸法を自分で持つため。macOS 26では、SwiftUIのサイドバーに置いた
/// シンボルが純正アプリより明らかに小さく描かれる問題があり、Apple DTS も
/// 「frame/fontで手当てするしかないが、それは望ましくない」と認めたまま解決策を出していない
/// (Apple Developer Forums thread 812205)。
/// タイルにしておけば、行の中で場所を取るのはタイルの `frame` であって
/// シンボルの自動寸法ではなくなるため、OSのバージョンによらず見た目が動かない。
///
/// ■ 色は装飾ではない
/// ユーザーは行の名前を読む前に、色と形で目的の行を見分ける。
/// 8項目それぞれに固有の色を与えてあり、特に「リセット」の赤は他のどの項目とも共有しない
/// (取り消しできない操作であることを、開く前に色だけで示すため。`SettingsPane.tint` 参照)。
private struct SettingsPaneIcon: View {
    let pane: SettingsPane

    /// システム設定のサイドバーのアイコンに合わせた寸法。
    /// タイルを大きくするとサイドバーの行間まで広がってしまうので、ここだけで調整する。
    private let side: CGFloat = 20
    private let symbolSize: CGFloat = 11

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(pane.tint.gradient)
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: pane.systemImage)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
            // タイルは名前の飾りであって、それ自体に読み上げる意味は無い
            // (行の名前はLabelのテキスト側が持っている)。
            .accessibilityHidden(true)
    }
}
