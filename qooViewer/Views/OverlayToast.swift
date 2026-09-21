import SwiftUI

/// 操作の結果を短い間だけ浮かべる 1〜2 行の知らせ(トースト)。面は `PanelSurface.overlays`。
///
/// ビューアのお気に入り・ブックマークの追加/削除(ViewerView.showToast)と、ファイルブラウザの
/// 「コレクションに登録」(FileBrowserState.showToast、ユーザー要望 2026-09-14)が同じ見た目で使う。
/// 消す時間・位置・出入りのアニメーションは置く側が決める。
///
/// ■ すりガラス面の決まりごと
/// 地は環境設定「外観」のオーバーレイの面で塗られるので、文字には `.panelOutlinedContent()` を掛ける
/// (`panelSurfaceBackground` が配る太さを、その内側の文字が読む)。
struct OverlayToast: View {
    @EnvironmentObject private var preferences: AppPreferences
    /// 外観タブの設定。本のウインドウではそのウインドウの揃い(ノーマル/シークレット。ContentView が渡す)。
    @EnvironmentObject private var appearance: AppearanceSettings

    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .panelOutlinedContent()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .panelSurfaceBackground(
                appearance.overlaySurfaceStyle, material: .ultraThinMaterial, in: Capsule()
            )
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}
