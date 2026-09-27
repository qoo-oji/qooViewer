import SwiftUI

/// ホームの一覧のスクロール位置の控え(ウインドウごと。publish しない)。
///
/// ■ なぜ要るのか(2026-09-27、利用者の報告)
/// 本を開いている間、ホームの画面は丸ごと捨てられ(`ContentView` が `WelcomeView` を `ViewerView` に差し替える)、ホームへ
/// 戻ると一覧はすべて作り直される。選択・開いているコレクションや束はウインドウの状態が持っているので戻るが、スクロールは
/// 一覧(SwiftUI の `ScrollView` / AppKit の `NSScrollView`)の中にしか無く、先頭から見せ直していた。
/// 位置を場面ごとの鍵(どのライブラリ・コレクション・棚・束か)で控え、同じ場面の一覧が作り直されたらそこから見せる。
///
/// - SwiftUI の一覧(コレクションの一覧と中身、スマートライブラリのグリッド)は、スクロールするたびに控えを書き換え
///   (`homeScrollRestoration`)、現れたときに戻す
/// - AppKit の一覧(スマートライブラリのリスト)は、捨てられるときに控え(`dismantleNSView`)、作られたときに戻す
///   (`HomeWheelScrollView.restoreScrollOrigin`)
/// - 戻したら控えは捨てる(`take`)。コレクションや束から一覧へ出るときは、出た先の控えを捨てる側が決める
///   (入り直したら先頭から、という今までの見え方を変えないため。`forget`)
@MainActor
final class HomeScrollMemory {
    private var origins: [String: CGPoint] = [:]

    func save(_ origin: CGPoint, for key: String) {
        origins[key] = origin
    }

    /// 控えを取り出して捨てる。
    func take(for key: String) -> CGPoint? {
        origins.removeValue(forKey: key)
    }

    func forget(_ key: String) {
        origins.removeValue(forKey: key)
    }
}

extension View {
    /// SwiftUI の縦の `ScrollView` に付けて、スクロール位置を `memory` に控え、作り直されたら戻す(`HomeScrollMemory`)。
    /// **`ScrollView` そのものに付けること**(`.scrollPosition` を持たせる)。すでに `.scrollPosition` を持つ一覧には使えない
    /// (スマートライブラリのグリッドは、自分の `ScrollPosition` で同じことをする)。
    func homeScrollRestoration(_ memory: HomeScrollMemory, key: String) -> some View {
        modifier(HomeScrollRestoration(memory: memory, key: key))
    }
}

/// `homeScrollRestoration` の中身。
private struct HomeScrollRestoration: ViewModifier {
    let memory: HomeScrollMemory
    let key: String

    @State private var position = ScrollPosition()
    @State private var restorer = HomeScrollRestorer()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: HomeScrollRestorer.Metrics.self) { geometry in
                HomeScrollRestorer.Metrics(geometry)
            } action: { _, metrics in
                if let y = restorer.observe(metrics, key: key, memory: memory) {
                    position.scrollTo(y: y)
                }
            }
            .onAppear {
                restorer.begin(memory.take(for: key)?.y) { y in position.scrollTo(y: y) }
            }
            // 同じ一覧のまま場面が変わった(ライブラリ・コレクションの切り替え)。新しい場面の控えがあれば戻す。
            .onChange(of: key) { _, newKey in
                restorer.begin(memory.take(for: newKey)?.y) { y in position.scrollTo(y: y) }
            }
    }
}

/// SwiftUI の一覧の位置を戻す段取り(`homeScrollRestoration` とスマートライブラリのグリッドで共有)。
///
/// 現れた直後の一覧はまだ中身の高さが決まっていない(LazyVGrid が行を並べ、GeometryReader が幅を渡すのはその後)ので、
/// **中身がその位置まで届く高さになった実測を待ってから**動かす。届かないまま(項目が減った)なら、少し待ってから届く所まで。
/// 戻し終えるまでは控えを書き換えない(作り直した直後の 0 で、控えを消してしまわないため)。
/// スクロールのたびに実測が届くので、`@State` の値ではなく参照型に持つ(`PanelListScrollTracker` と同じ理由)。
@MainActor
final class HomeScrollRestorer {
    struct Metrics: Equatable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var visibleHeight: CGFloat

        init(_ geometry: ScrollGeometry) {
            offsetY = geometry.contentOffset.y
            contentHeight = geometry.contentSize.height
            visibleHeight = geometry.containerSize.height
        }

        init(offsetY: CGFloat, contentHeight: CGFloat, visibleHeight: CGFloat) {
            self.offsetY = offsetY
            self.contentHeight = contentHeight
            self.visibleHeight = visibleHeight
        }
    }

    /// 戻す途中の位置(nil なら戻し終えた/戻すものが無い)。
    private var pendingY: CGFloat?
    private var serial = 0
    /// `begin` を呼んだか。**呼ぶまでは控えを書き換えない** ―― 作り直した一覧の最初の実測(位置 0)は `onAppear` より先に
    /// 届くことがあり、それで控えを上書きすると、戻す前に控えが 0 になっていた(2026-09-27 の実機検証)。
    private var hasBegun = false

    /// 戻し始める。`y` が nil なら何もしない。届く高さの実測が来ないまま待ち時間が過ぎたら、届く所まで動かす(`fallback`)。
    func begin(_ y: CGFloat?, fallback: @escaping (CGFloat) -> Void) {
        hasBegun = true
        serial += 1
        guard let y, y > 0.5 else {
            pendingY = nil
            return
        }
        pendingY = y
        let mine = serial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.serial == mine, let pending = self.pendingY else { return }
            self.pendingY = nil
            fallback(min(pending, self.lastReachableY ?? pending))
        }
    }

    /// 最後に測った「いちばん下まで動かしたときの位置」。
    private var lastReachableY: CGFloat?

    /// 実測が届いた。戻す途中なら、届く高さになったときの位置を返す(呼び出し側が動かす)。そうでなければ控えを書き換える。
    func observe(_ metrics: Metrics, key: String, memory: HomeScrollMemory) -> CGFloat? {
        guard metrics.contentHeight > 0, metrics.visibleHeight > 0 else { return nil }
        let reachable = max(0, metrics.contentHeight - metrics.visibleHeight)
        lastReachableY = reachable
        if let y = pendingY {
            guard reachable + 0.5 >= y else { return nil }
            pendingY = nil
            serial += 1
            return y
        }
        guard hasBegun else { return nil }
        memory.save(CGPoint(x: 0, y: metrics.offsetY), for: key)
        return nil
    }

    /// 戻す途中か(スマートライブラリのグリッドが、戻す間は選択の枠へ寄せない)。
    var isRestoring: Bool { pendingY != nil }
}
