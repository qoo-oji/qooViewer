import SwiftUI

/// 区切り線の上の、隣のペインの幅を変える掴みどころ(ファイルブラウザの左のツリー・ホームのインスペクタ。2026-09-30 に
/// FileBrowserPane から共通の部品へ出した)。
///
/// **座標は外側の座標空間で読む**(`coordinateSpace`)―― 掴みどころ自身は幅に合わせて動くので、自分の座標で読むとドラッグの出力が
/// 自分の位置を動かし、震える(SidePanelView.widthDragHitAreaで実際に起きた自己参照ループ)。
/// ドラッグ中の幅は呼び出し側の `liveWidth` に置き、**離したときだけ** `onCommit` で保存させる(毎フレーム保存しない)。
struct PaneWidthDragHandle: View {
    /// 広げる向き。左のペイン(ツリー)は右へ引くと広がり、右のペイン(インスペクタ)は左へ引くと広がる。
    enum GrowthDirection {
        case trailing, leading
    }

    let currentWidth: CGFloat
    let range: ClosedRange<CGFloat>
    let growth: GrowthDirection
    let coordinateSpace: String
    @Binding var liveWidth: CGFloat?
    let onCommit: (CGFloat) -> Void

    @State private var dragStartWidth: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            // 左右矢印のカーソルは hoverCursor で(2026-09-27、監査 38。以前は onHover で直に push / pop していて、掴んだまま
            // ペインが消えると pop されずにカーソルが残りえた ―― HoverCursor.swift の決まり)。
            .hoverCursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
                    .onChanged { value in
                        if liveWidth == nil { dragStartWidth = currentWidth }
                        let delta = value.location.x - value.startLocation.x
                        let proposed = dragStartWidth + (growth == .trailing ? delta : -delta)
                        liveWidth = min(range.upperBound, max(range.lowerBound, proposed))
                    }
                    .onEnded { _ in
                        if let liveWidth { onCommit(liveWidth) }
                        liveWidth = nil
                    }
            )
    }
}
