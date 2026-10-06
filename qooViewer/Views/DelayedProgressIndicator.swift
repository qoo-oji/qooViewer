import SwiftUI

/// 読み込みを待っている一覧・ペインに、少し待ってから出す回転表示(2026-10-06 の応答性の点検 R5)。
///
/// 一覧を読み直すたびに出すとちらつく(ローカルのフォルダはほぼ一瞬で読み終わる)ので、`delay` を過ぎても画面に残っていた
/// ときだけ見せる。待ちが長くなるのは遅い・応答しない共有で、以前はその間、空の一覧(ファイルブラウザ)や前のフォルダの一覧
/// (サイドパネル)が何の印も無いまま残っていた。
///
/// **時限は `DispatchQueue`**: 協調スレッドプールが塞がると `Task.sleep` は発火しない(FileIO.swift の型コメントの実測)―― 待ちが
/// 長くなるのはまさにその場面。
///
/// - `boxed`: 不透明な地の上に載せる(サイドパネルなど、利用者が任意の色で塗れる面 `PanelSurface` の上で、回転表示が面の色に
///   溶けないように。CLAUDE.md「Anything drawn on a frosted-glass surface」―― 不透明な地を持つ部品なので輪郭は付けない)。
struct DelayedProgressIndicator: View {
    var delay: TimeInterval = 0.3
    var controlSize: ControlSize = .regular
    var boxed = false

    @State private var isShown = false
    /// 出たときの番号(前に出たときの時限が、出直した後の待ちを縮めないように)。
    @State private var appearance = 0

    var body: some View {
        indicator
            .opacity(isShown ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isShown)
            .allowsHitTesting(false)
            .onAppear {
                appearance &+= 1
                let mine = appearance
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if appearance == mine { isShown = true }
                }
            }
            .onDisappear {
                appearance &+= 1
                isShown = false
            }
    }

    @ViewBuilder
    private var indicator: some View {
        if boxed {
            ProgressView()
                .controlSize(controlSize)
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        } else {
            ProgressView()
                .controlSize(controlSize)
        }
    }
}
