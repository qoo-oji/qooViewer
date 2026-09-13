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

    /// 閉包を切る(ViewerView.swiftのClickZoneArea.dismantleNSViewのコメント参照)。
    static func dismantleNSView(_ nsView: MouseExitTrackingView, coordinator: ()) {
        nsView.onExit = nil
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
        // ウインドウに載っていない間は張らない(viewDidMoveToWindowのコメント参照)。
        guard window != nil else { return }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    /// **ウインドウから外れたら、トラッキング領域と閉包を手放す**(実測 2026-09-13。閉じた
    /// ウインドウの`AppState`が残る件)。
    ///
    /// `NSTrackingArea`は`owner`を強参照し、このビューは`trackingAreas`で領域を強参照するので、
    /// `owner: self`で張った瞬間に「ビュー → 領域 → ビュー」の輪ができる。ウインドウが閉じても
    /// この輪は自然には切れず、`onExit`が掴んでいるContentViewの写し(→ `AppState`)ごと
    /// アプリ終了まで残っていた(leaks --traceTreeで NSTrackingArea._owner →
    /// MouseExitTrackingView.onExit.context → AppState の経路を実測)。SwiftUIの
    /// `dismantleNSView`はウインドウを閉じた経路では呼ばれなかったので、AppKitの側の合図で切る。
    /// ウインドウへ戻れば(タブを別のウインドウへ移した等)`updateTrackingAreas`が張り直し、
    /// 閉包は次の`updateNSView`で入り直す。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        onExit = nil
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
