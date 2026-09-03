import SwiftUI

/// ビューアの画像表示エリアの外側にある「パネル」のうちの1つ。
/// 帯や枠の空きスペースを右クリックしたときのメニュー(`panelPartContextMenu(for:)`)を
/// 組み立てるためだけの区別なので、それ以外からは使わない。
enum ViewerPanelPart {
    case toolbar
    case progressBar
    case sidePanel
    /// ページ一覧(サムネイルグリッド)パネル。**この面だけ「隠す」設定を持たない**
    /// ―― 開いている間だけ浮かぶ一時的なパネルで、閉じ方が別にある(パネルの外側や
    /// 余白のクリック、同じ操作の再実行)ため。メニューは「調整…」だけになる。
    case pageList

    /// 「この部品を隠す」項目の文言。持たない部品(ページ一覧パネル)ではnil。
    /// 文言はメニューバー「表示」メニューの対応する項目
    /// (QooViewerApp.swiftのCommandGroup(after: .toolbar))と**同じ文字列を共有する**。
    /// 同じ設定を2か所から切り替えるのに呼び名が違うと、別々の機能に見えてしまうため。
    var hideTitleKey: LocalizedStringKey? {
        switch self {
        case .toolbar: return "Hide Toolbar"
        case .progressBar: return "Hide Progress Bar"
        case .sidePanel: return "Hide Side Panel"
        case .pageList: return nil
        }
    }

    /// 「調整…」の飛び先。環境設定「外観」画面で、この部品の見た目を決めている面の子ページ。
    ///
    /// ページ一覧の子ページには、すりガラスの濃さ・重ね色と並んでサムネイルの大きさ・間隔・
    /// 余白・枠の色も載っている(PanelSurfaceSettingsView参照)。**ユーザーがこのパネルに
    /// ついて調整したくなるのは主に後者**だが、同じページに両方あるので飛び先は1つでよい
    /// (以前は1枚の長い画面の中でスクロール位置を選び分けていた)。
    var panelSurface: PanelSurface {
        switch self {
        case .toolbar: return .toolbar
        case .progressBar: return .progressBar
        case .sidePanel: return .sidePanel
        case .pageList: return .pageList
        }
    }
}

/// ツールバー/プログレスバー/サイドパネル/ページ一覧パネルの空きスペースを右クリックしたときに、
/// その部品自身を隠したり、見た目を調整しに行けるようにする(ユーザー要望)。
///
/// ■ なぜ独立したViewModifierなのか
/// AppKitのツールバーを右クリックすると「ツールバーを隠す」が出るのと同じ操作感を、
/// 4つの部品それぞれに付ける必要がある。中身は1〜2項目だけだが、
/// - 対象の設定(AppState.hideToolbar/hideProgressBar/hideSidePanel)
/// - 文言(メニューバーと共有する)
/// - 「調整…」の飛び先(環境設定「外観」画面のどの面の子ページか)
/// - 空きスペースにも当たり判定を作る(.contentShape)
/// の4点セットを手で書き写すと、片方だけ直し忘れる類のズレが起きる(ツールバーと
/// プログレスバーは常時表示/自動隠しで取り付け箇所が2か所ずつあるため、実際には5か所)。
///
/// ■ AppStateを**このModifierの中で**受け取っている理由
/// サイドパネル(SidePanelView)はAppStateを一切参照しない作りになっており、そこへ
/// `@EnvironmentObject var appState: AppState` を足すと、AppStateの`@Published`が
/// 変わるたび(ページ送りのたびに変わるcurrentPageIndexなども含む)にサイドパネル本体の
/// bodyが丸ごと再評価されてしまう。ViewModifierもViewと同じく独立した更新の単位なので、
/// ここでEnvironmentObjectを受ければ、再評価されるのはこの薄いラッパーだけで済む
/// (`content`は既に組み上がったものを受け取るだけで、中身は作り直されない)。
private struct PanelPartContextMenu: ViewModifier {
    let part: ViewerPanelPart
    @EnvironmentObject private var appState: AppState
    /// 「調整…」で環境設定ウインドウを開く(macOS 14以降のSwiftUI標準の操作)。
    /// どの画面のどこを開くかは、呼ぶ直前にSettingsNavigatorへ預ける(SettingsNavigator参照)。
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            // ボタンの無い余白(ツールバーの中央、プログレスバーの上下の余白、サイドパネルの
            // 一覧の下の空き、ページ一覧のサムネイルが並んでいない部分)は、そのままでは
            // 当たり判定を持たず右クリックを拾えない。ここで矩形を明示して、パネルのどこを
            // 右クリックしても同じメニューが出るようにする。子のボタンや、行/セルごとに独自の
            // `.contextMenu`を持つ一覧は手前にあるため、そちらの当たり判定・メニューが
            // 優先される(この指定で潰されることはない)。
            .contentShape(Rectangle())
            .contextMenu {
                if let hideTitleKey = part.hideTitleKey, let hideBinding {
                    Toggle(hideTitleKey, isOn: hideBinding)

                    Divider()
                }

                // ユーザー要望: 右クリックしたその部品の見た目を、その場から調整しに行けるように
                // する。飛び先は環境設定「外観」画面の対応する面の子ページ(panelSurface参照)。
                // 行き先を先に預けてからウインドウを開く(順序の理由はprepareAppearance参照)。
                Button("Adjust…") {
                    SettingsNavigator.shared.prepareAppearance(opening: part.panelSurface)
                    openSettings()
                }
            }
    }

    /// メニューバー側(QooViewerApp.swift)と同じく、書き込み先はAppState。
    /// AppStateのdidSetがAppPreferencesへ書き戻し、UserDefaultsに残る
    /// (AppState.hideToolbarのコメント参照)ので、次回起動時にも状態が再現する。
    /// 「隠す」設定を持たない部品(ページ一覧パネル)ではnil。
    private var hideBinding: Binding<Bool>? {
        switch part {
        case .toolbar:
            return Binding(get: { appState.hideToolbar }, set: { appState.hideToolbar = $0 })
        case .progressBar:
            return Binding(get: { appState.hideProgressBar }, set: { appState.hideProgressBar = $0 })
        case .sidePanel:
            return Binding(get: { appState.hideSidePanel }, set: { appState.hideSidePanel = $0 })
        case .pageList:
            return nil
        }
    }
}

extension View {
    /// このパネルの空きスペースを右クリックしたときに、隠す/見た目を調整するメニューを出す。
    /// 詳細はPanelPartContextMenuのコメント参照。
    func panelPartContextMenu(for part: ViewerPanelPart) -> some View {
        modifier(PanelPartContextMenu(part: part))
    }
}
