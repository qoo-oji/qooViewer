import AppKit
import SwiftUI

/// ホーム画面の一覧を**物理マウスホイール**で転がしたときの、1ノッチぶんのスクロール量
/// (ユーザー要望 2026-09-23)。リストは「行数」、アイコン/グリッドは「グリッドの行数」で決める
/// (環境設定「外観」→「ホーム」→「スクロール」。`AppearanceSettings.homeListWheelScrollRows` /
/// `homeGridWheelScrollRows`)。
///
/// ■ なぜ自前で動かすのか
/// 高解像度スクロールに対応したマウス(いまどきのものはたいていそう)は、物理ホイールでも
/// `hasPreciseScrollingDeltas == true`・`scrollingDeltaY = ±13.0` で届く。AppKitはその13ptを
/// そのまま動かすので、**行の高さやセルの大きさに関わらず1ノッチ13pt**にしかならず、行や
/// カバーの大きさを変えても手応えが変わらなかった。
///
/// ■ 対象は物理ホイールだけ
/// トラックパッド(とMagic Mouseの指でなぞる操作)は1回の操作が細かいイベントの連なりとして
/// 届くため「1回ぶん」に意味が無い。判定はこのアプリの他の箇所と同じ`phase`/`momentumPhase`で、
/// 実測値と以前の誤りの経緯は`ThumbnailGridView.isWheelOriginated`のコメントにある。
///
/// ■ 横方向は素通しする
/// ⇧を押しながらのホイール・チルトホイールは`deltaX`に載って届く。こちらは縦しか面倒を見ない
/// ので、横が載っているイベントはAppKitの標準の処理へ渡す(横を取りこぼさないため)。
enum HomeWheelScroll {
    /// このスクロールイベントが、トラックパッドではなく物理マウスホイールのノッチによるものか。
    static func isWheelOriginated(_ event: NSEvent) -> Bool {
        event.phase.isEmpty && event.momentumPhase.isEmpty
    }

    /// ホイールのノッチぶんだけ`scrollView`を動かす。動かしたらtrue(呼び出し側は標準の処理へ
    /// 渡さない ―― 渡すと二重になって設定した量の何倍も動く)。
    ///
    /// - Parameter distance: 1ノッチで動かす距離(pt)。0以下なら何もしない(= 標準の挙動のまま)。
    static func apply(_ event: NSEvent, to scrollView: NSScrollView?, distancePerNotch distance: CGFloat) -> Bool {
        guard distance > 0, isWheelOriginated(event), event.deltaY != 0, event.deltaX == 0 else { return false }
        // 見出しのある一覧(NSTableView / NSOutlineView)は、クリップビューの上の余白(contentInsets)に見出しが載り、一番上の
        // 位置が y = −見出しの高さになる(実測: 見出し 28pt で origin.y = −28)。`ScrollViewBounds` は 0 から数えるので、一番上で
        // 上へ回すと 1 行目が見出しの下へ隠れ、ホイールでは一番上へ戻れなかった(2026-09-23 の 3 回目の監査の低)。余白の
        // ある上下反転の一覧は、余白ぶんを含めて動かす。
        if let scrollView, let documentView = scrollView.documentView, documentView.isFlipped {
            let clip = scrollView.contentView
            let insets = clip.contentInsets
            if insets.top != 0 || insets.bottom != 0 {
                let minY = -insets.top
                let maxY = max(documentView.frame.height - clip.bounds.height + insets.bottom, minY)
                let y = min(max(clip.bounds.origin.y - event.deltaY * distance, minY), maxY)
                clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: y))
                scrollView.reflectScrolledClipView(clip)
                return true
            }
        }
        guard let bounds = ScrollViewBounds(scrollView) else { return false }
        var position = bounds.position
        // ノッチ数は`scrollingDeltaY`ではなく`deltaY`から取る(機器によらず1ノッチ=±1に
        // 正規化されている。理由と実測値はThumbnailGridView.handleWheelのコメント)。
        // 符号: deltaYは「ナチュラルなスクロール」を反映済みで、上へ回すと正。positionは下へ
        // 進むほど増える向きなので反転させる。速く回したときにAppKitがまとめてくる複数ノッチ分
        // (実測で-3〜-6)は、そのまま掛けて加速を活かす。
        position.y -= event.deltaY * distance
        // アニメーションは付けない(「1ノッチ = N行」をそのまま目に見える動きにするため。
        // 可動範囲へのクランプはscroll(to:)が行う)。
        bounds.scroll(to: position)
        return true
    }
}

/// `scrollWheel`を自前で扱う`NSScrollView`。ホーム画面のAppKitの一覧
/// (ファイルブラウザのリスト・フォルダツリー・アイコン表示、スマートライブラリのリスト)が使う。
///
/// 1ノッチぶんの距離は値で持つ(閉包にしない)。`NSViewRepresentable`の`updateNSView`が毎回
/// 入れ直すので、設定を動かせばその場で効き、**閉包がビューを捕まえてリークする心配も無い**
/// (CLAUDE.mdの「閉包は`dismantleNSView`で切る」)。
final class HomeWheelScrollView: NSScrollView {
    /// ホイール1ノッチで動かす距離(pt)。0以下ならAppKitの標準の挙動。
    var wheelStepDistance: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        if HomeWheelScroll.apply(event, to: self, distancePerNotch: wheelStepDistance) { return }
        super.scrollWheel(with: event)
    }
}

extension View {
    /// SwiftUIのグリッド(ライブラリのコレクション一覧・コレクションの中・スマートライブラリ)で、
    /// 物理マウスホイール1ノッチぶんのスクロール量を設定に従わせる。
    ///
    /// `NSScrollView`を自分で作れないので、`welcomeGridPinch`と同じくNSEventのローカルモニタで
    /// 受ける(ポインタの下にあるのがこのグリッドかをヒットテストで見る理由も、あちらと同じ)。
    ///
    /// - Parameters:
    ///   - scrollBox: グリッドの`NSScrollView`の入れ物(`ScrollViewAccessor`が入れる)。
    ///   - distancePerNotch: 1ノッチで動かす距離(pt)。0以下なら標準の挙動のまま。
    ///     **閉包ではなく値で渡す** ―― モニタは最初に現れたときの1回だけ取り付けるので、閉包にすると
    ///     グリッドの大きさや設定が変わっても古い値のままになる。また、閉包が`View`の値(= その先の
    ///     `SwiftData`のモデルや状態)を捕まえると、モニタの取り外しに一度でも失敗しただけで
    ///     プロセスの生存期間ずっと解放されない(`ThumbnailGridView.makeGridEventMonitor`のコメント)。
    ///     値なら、`body`が組み直されるたびに小さな箱へ入れ直すだけで済む。
    func homeGridWheelScroll(scrollBox: ScrollGeometryBox, distancePerNotch: CGFloat) -> some View {
        modifier(HomeGridWheelScroll(scrollBox: scrollBox, distancePerNotch: distancePerNotch))
    }
}

/// `homeGridWheelScroll`の実体(`WelcomeGridPinch`と同じ作り)。
private struct HomeGridWheelScroll: ViewModifier {
    let scrollBox: ScrollGeometryBox
    let distancePerNotch: CGFloat

    @State private var monitor = WheelMonitor()

    func body(content: Content) -> some View {
        // 値の入れ直しは`body`のたび(モニタの取り付けは最初の1回だけ)。`@State`を書くわけではないので
        // 「更新の最中に状態を変えた」警告にはならない。
        monitor.distance = distancePerNotch
        return content
            .onAppear { monitor.install(scrollBox: scrollBox) }
            .onDisappear { monitor.remove() }
    }
}

/// NSEventモニタの持ち主(`WelcomeGridPinch`の`MagnifyMonitor`と同じ理由で、モディファイアとは
/// 別の小さな箱に分けてある)。**`View`の値は一切持たない**。
@MainActor
private final class WheelMonitor {
    /// ホイール1ノッチで動かす距離(pt)。モディファイアの`body`が毎回入れ直す。
    var distance: CGFloat = 0
    /// deinitから外すためにnonisolated(unsafe)。触るのはメインスレッドだけ。
    nonisolated(unsafe) private var token: Any?

    func install(scrollBox: ScrollGeometryBox) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak scrollBox] event in
            // トラックパッドの細かい出来事や横のホイールは、ヒットテストの前に素通しする(アプリ中のスクロールの出来事ごとに
            // hitTest を走らせない。2026-09-23 の 3 回目の監査の低)。
            guard let self, self.distance > 0, HomeWheelScroll.isWheelOriginated(event), event.deltaY != 0, event.deltaX == 0,
                  let scrollView = scrollBox?.scrollView,
                  let window = scrollView.window, event.window === window,
                  let contentView = window.contentView,
                  // 矩形の内外ではなくヒットテストで見る(上に重なっているものを横取りしない。
                  // ThumbnailGridView.makeGridEventMonitorのコメント)。
                  let hitView = contentView.hitTest(event.locationInWindow),
                  hitView.isDescendant(of: scrollView)
            else { return event }
            // 自前で動かしたらイベントは流さない(流すとAppKitの標準の処理と二重になり、
            // 設定した量の何倍も動く)。
            return HomeWheelScroll.apply(event, to: scrollView, distancePerNotch: distance) ? nil : event
        }
    }

    func remove() {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
    }

    // `.onDisappear`はウインドウを閉じたときに必ず来るとは限らない(WelcomeGridPinchと同じ)。
    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }
}
