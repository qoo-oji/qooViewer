import AppKit
import SwiftUI

extension View {
    /// カーソルがこのビューの上にある間だけ、指定したカーソル(リサイズ矢印など)にする。
    ///
    /// `NSCursor.push()`/`pop()`はスタックで対応が取れていなければならない。以前は各ビューの
    /// `.onHover`で直接push/popしていたが、カーソルを乗せたままそのビューが消えると
    /// (サイドパネルのモード切り替え・ウインドウを閉じる等)、`hovering == false`が届かず
    /// popされないまま残り、リサイズ矢印のカーソルがアプリ全体で戻らなくなることがあった
    /// (監査で指摘)。ここでは「pushしたかどうか」を覚えておき、ビューが消えるときにも
    /// 必ずpopする。二重push・二重popも起こさない。
    func hoverCursor(_ cursor: NSCursor) -> some View {
        modifier(HoverCursorModifier(cursor: cursor))
    }
}

private struct HoverCursorModifier: ViewModifier {
    let cursor: NSCursor
    /// いま自分がpushしたカーソルがスタックに載っているか。
    @State private var isPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                if isHovering {
                    guard !isPushed else { return }
                    cursor.push()
                    isPushed = true
                } else {
                    popIfPushed()
                }
            }
            .onDisappear {
                popIfPushed()
            }
    }

    private func popIfPushed() {
        guard isPushed else { return }
        NSCursor.pop()
        isPushed = false
    }
}
