import SwiftUI

/// インスペクタ(ホームの右ペイン)の出し入れのボタン(2026-09-30)。帯の右端に置き、帯の無いホーム(ファイルブラウザだけ)では
/// ファイルブラウザの操作列の右端(検索の右)に置く(利用者の指定)。
///
/// 見た目は表示切替のボタン(`PanelViewModeButton`)と同じ ―― 出している間は選択中の地(アクセント色。後ろのウインドウでは灰色)。
/// 輪郭の掛け方もあちらが持つ(地の無いときだけ `.panelOutlinedContent()`、選択中は `.panelOutlinedAccent(in:)`)。
struct HomeInspectorToggleButton: View {
    @ObservedObject var state: WelcomeLibraryState

    var body: some View {
        PanelViewModeButton(
            systemImage: "sidebar.right",
            helpKey: state.isInspectorShown ? "Hide Inspector" : "Show Inspector",
            isSelected: state.isInspectorShown
        ) {
            state.isInspectorShown.toggle()
        }
        .accessibilityLabel(Text("Inspector"))
        .accessibilityAddTraits(state.isInspectorShown ? .isSelected : [])
    }
}
