import AppKit
import SwiftUI

/// カーソルがウインドウの外へ出たことを検知して、コールバックを1回だけ呼ぶ透明なビュー。
/// 「カーソルがウインドウの外に出たら、自動表示中のサイドパネル/ツールバー/プログレスバーを
/// 閉じる」機能(ContentView.dismissAutoRevealedChromeIfCursorLeftWindow)のために使う。
///
/// 【なぜNSEventのモニタだけでは足りないのか】
/// ContentViewは同じ目的で、マウス移動のローカルモニタ(このアプリ宛て)とグローバルモニタ
/// (他のアプリ宛て)の2本を持っている。しかしカーソルがメニューバーの上へ抜けた場合、その
/// 領域のマウス移動はどちらのモニタにも届かない(実機で確認済み。他のアプリのウインドウや
/// デスクトップの上へ出た場合はグローバルモニタで検知できるため、抜けていたのはこの経路だけ)。
/// メニューバーへカーソルを動かすのは「ウインドウの外に出る」典型的な操作のため、AppKit本来の
/// 仕組みであるNSTrackingAreaによる`mouseExited`で確実に補う。
///
/// 【誤検知について】
/// NSTrackingAreaの`mouseExited`は、ポップオーバーやメニューがカーソルの上に重なった場合など、
/// 実際にはウインドウの外へ出ていない場面でも発生しうる。そのため呼び出し側は、通知を受けた
/// 時点でカーソルが本当にウインドウのフレームの外にあるかを必ず確認する
/// (dismissAutoRevealedChromeIfCursorLeftWindowが行う)。このビュー自身は「確認すべき
/// タイミング」を知らせるだけで、判断はしない。
struct WindowMouseExitAccessor: NSViewRepresentable {
    let onExit: () -> Void

    func makeNSView(context: Context) -> MouseExitTrackingView {
        let view = MouseExitTrackingView()
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: MouseExitTrackingView, context: Context) {
        // ContentViewが再評価されるたびに、最新の状態を捉えたクロージャへ差し替える。
        nsView.onExit = onExit
    }
}

/// 上記の実体。`.background`として敷かれ、ウインドウの内容領域いっぱいに広がる。
final class MouseExitTrackingView: NSView {
    var onExit: (() -> Void)?

    /// `.inVisibleRect`を指定しているため、追跡範囲は常にこのビューの可視範囲へ自動的に
    /// 追随する(ウインドウのリサイズやフルスクリーンの切替でも指定し直す必要が無い)。
    /// `.activeAlways`は、このアプリがアクティブでないときにも検知するため。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }

    /// このビューはカーソルの出入りを知るためだけのものなので、クリックなどの操作は一切
    /// 受け取らない(nilを返してもNSTrackingAreaによる検知には影響しない)。背景として
    /// 敷いている都合上、前面のSwiftUIコンテンツに覆われていない隙間でクリックを横取り
    /// してしまうことを確実に防ぐため。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
