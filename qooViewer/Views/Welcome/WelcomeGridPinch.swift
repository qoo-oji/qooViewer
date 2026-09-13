import AppKit
import SwiftUI

extension View {
    /// トラックパッドのピンチでグリッドの大きさを変える(ユーザー要望 2026-09-13: ページ一覧パネルと
    /// 同じ操作)。コレクションの一覧・コレクションの中の2つのグリッドが使う。
    ///
    /// - Parameters:
    ///   - scrollBox: グリッドのNSScrollView(マーキーが控えているもの)。**ポインタがこのグリッドの
    ///     上にあるか**をヒットテストで判定するために使う(下記)。
    ///   - onMagnify: 1イベントぶんの`magnification`(変化量)を受け取る。呼び出し側は現在の大きさに
    ///     `(1 + magnification)`を掛けて範囲へ収める(ThumbnailGridView.handleMagnifyと同じ扱い ――
    ///     足し込みではなく掛け算にする理由と、刻みへ丸めない理由もあちら)。**Viewの値(self)を
    ///     捕まえないこと**(状態の入れ物をweakで捕まえる)。取り付けは最初に現れたときの1回だけで、
    ///     モニタはその閉包を持ち続ける。
    func welcomeGridPinch(
        scrollBox: ScrollGeometryBox, onMagnify: @escaping (CGFloat) -> Void
    ) -> some View {
        modifier(WelcomeGridPinch(scrollBox: scrollBox, onMagnify: onMagnify))
    }
}

/// `welcomeGridPinch`の実体。
///
/// ■ 判定は「ポインタの下にあるのがこのグリッドか」(矩形の内外ではない)
/// ThumbnailGridView.makeGridEventMonitorと同じ理由 ―― 矩形だけで見ると、上に重なっている
/// もの(ホバーで浮かせたサイドパネル)の上でのピンチまで横取りする。ウインドウのcontentViewで
/// ヒットテストし、当たったビューがグリッドのNSScrollViewの子孫のときだけ受け取る。
///
/// ■ 既定の処理へは渡さない
/// SwiftUIのScrollViewは既定でmagnificationを受け付けないが、将来にわたって二重に処理されない
/// ことを保証するため(ThumbnailGridViewと同じ)。
private struct WelcomeGridPinch: ViewModifier {
    let scrollBox: ScrollGeometryBox
    let onMagnify: (CGFloat) -> Void

    @State private var monitor = MagnifyMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.install(scrollBox: scrollBox, onMagnify: onMagnify) }
            .onDisappear { monitor.remove() }
    }
}

/// NSEventモニタの持ち主。モディファイア(struct)にモニタを持たせると、閉包がモディファイアの
/// 写しごと状態を掴んでしまうので、小さな箱に分けてある(FocusReleasingFieldのFieldAnchorと同じ)。
@MainActor
private final class MagnifyMonitor {
    /// deinitから外すためにnonisolated(unsafe)。触るのはメインスレッド(取り付け・取り外し・
    /// SwiftUIが@Stateを手放すとき)だけ。
    nonisolated(unsafe) private var token: Any?

    func install(scrollBox: ScrollGeometryBox, onMagnify: @escaping (CGFloat) -> Void) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak scrollBox] event in
            guard event.magnification != 0,
                  let scrollView = scrollBox?.scrollView,
                  let window = scrollView.window, event.window === window,
                  let contentView = window.contentView,
                  let hitView = contentView.hitTest(event.locationInWindow),
                  hitView.isDescendant(of: scrollView)
            else { return event }
            onMagnify(event.magnification)
            return nil
        }
    }

    func remove() {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
    }

    // `.onDisappear`はウインドウを閉じたときに必ず来るとは限らない(ThumbnailGridViewの
    // 同じ箇所のコメント)。取り外し損ねても、箱が解放されれば外れる。
    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }
}
