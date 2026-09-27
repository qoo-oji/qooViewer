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
/// - **戻し終えるまで一覧を見せない**(2026-09-27、表示の切り替えの監査)。以前は先頭(位置 0)で描いてから控えの位置へ
///   跳んでいた ―― SwiftUI の一覧は中身の高さの実測(`onScrollGeometryChange`)か 0.4 秒の待ちの後にしか動かせず、AppKit の
///   一覧は次のランループで戻していたので、少なくとも 1 フレームは先頭が見えた。戻す途中は透明にしておき、控えの位置に
///   着いてから見せる(SwiftUI は `HomeScrollRestorer.conceals`、AppKit は `HomeWheelScrollView.restoreScrollOrigin`)
/// - 戻したら控えは捨てる(`take`)。コレクションや束から一覧へ出るときは、出た先の控えを捨てる側が決める
///   (入り直したら先頭から、という今までの見え方を変えないため。`forget`)
@MainActor
final class HomeScrollMemory {
    private var origins: [String: CGPoint] = [:]

    func save(_ origin: CGPoint, for key: String) {
        origins[key] = origin
    }

    /// 控えを覗く(捨てない)。作り直した一覧の最初の body が「これから戻すか」を知るためだけに使う(`HomeScrollRestorer.conceals`)。
    func peek(for key: String) -> CGPoint? {
        origins[key]
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
            // 戻し終えるまで見せない(型コメント。先頭で描いてから跳ぶのを見せない)。
            .opacity(restorer.conceals(memory: memory, key: key) ? 0 : 1)
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
                // 手元の実測は前の場面の中身のもの(begin の usesLastGeometry)。
                restorer.begin(memory.take(for: newKey)?.y, usesLastGeometry: false) { y in position.scrollTo(y: y) }
            }
    }
}

/// SwiftUI の一覧の位置を戻す段取り(`homeScrollRestoration` とスマートライブラリのグリッドで共有)。
///
/// 現れた直後の一覧はまだ中身の高さが決まっていない(LazyVGrid が行を並べ、GeometryReader が幅を渡すのはその後)ので、
/// **中身がその位置まで届く高さになった実測を待ってから**動かす。届かないまま(項目が減った)なら、少し待ってから届く所まで。
/// 戻し終えるまでは控えを書き換えない(作り直した直後の 0 で、控えを消してしまわないため)。
/// スクロールのたびに実測が届くので、`@State` の値ではなく参照型に持つ(`PanelListScrollTracker` と同じ理由)。
///
/// ■ 戻し終えるまで隠す(2026-09-27、表示の切り替えの監査)
/// 作り直した一覧は、実測が届く前の最初のフレームを位置 0 で描く。以前はそれがそのまま見え、控えの位置へ跳ぶのが見えていた。
/// 一覧は `conceals` が true の間は透明にする: 最初の body(`begin` の前)は控えがあるかを覗いて決め、`begin` の後は
/// 「戻す途中(`pendingY`)」か「動かしたが、実測がまだその位置を報告していない(`landingY`)」の間。`scrollTo(y:)` が効くのは
/// 次の描き直しなので、動かした直後に見せると 1 フレームだけ元の位置が見えうる ―― 位置が届いたのを実測で確かめてから見せる。
/// 見せる・隠すの切り替えを body に届けるため、この 2 つだけを観測させる(`@Observable`。実測のたびに書き換わる値は
/// `@ObservationIgnored` にして、スクロールのたびに body を組み直させない)。
@MainActor
@Observable
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
    /// 動かした位置。実測がその位置を報告するまで(= 動いたフレームが描かれるまで)一覧を隠しておく(型コメント)。
    private var landingY: CGFloat?
    @ObservationIgnored private var serial = 0
    /// `begin` を呼んだか。**呼ぶまでは控えを書き換えない** ―― 作り直した一覧の最初の実測(位置 0)は `onAppear` より先に
    /// 届くことがあり、それで控えを上書きすると、戻す前に控えが 0 になっていた(2026-09-27 の実機検証)。
    @ObservationIgnored private var hasBegun = false

    /// 一覧を隠しておくか(型コメント「戻し終えるまで隠す」)。body から呼ぶ。
    func conceals(memory: HomeScrollMemory, key: String) -> Bool {
        // 2 つは**いつも読む**(`begin` の前にも読んでおかないと、戻し終えたときに body が組み直されず、隠れたままになる)。
        let restoring = pendingY != nil || landingY != nil
        if hasBegun { return restoring }
        // `begin`(onAppear)の前の最初の body。これから戻す控えがあれば、最初のフレームから隠す(`begin` と同じ閾値)。
        return restoring || (memory.peek(for: key)?.y ?? 0) > 0.5
    }

    /// 戻し始める。`y` が nil なら何もしない。届く高さの実測が来ないまま待ち時間が過ぎたら、届く所まで動かす(`fallback`)。
    ///
    /// - Parameter usesLastGeometry: `begin` より先に届いていた実測(`lastReachableY`)で、もう届くと分かっていればその場で動かす。
    ///   作り直した一覧の実測は `onAppear` より先に 1 回だけ届き、その後は中身が変わらない限り届かない(2026-09-27 の実機のログ:
    ///   実測が begin の 3ms 前に 1 回だけ届き、以後は来ず、0.4 秒の待ちが切れてから動いていた ―― その間、以前は先頭が見え、
    ///   隠すようにしてからは空の一覧が見えていた)。同じ一覧のまま場面が替わったとき(`onChange(of: key)`)の手元の実測は
    ///   前の場面の中身のものなので使わない。
    func begin(_ y: CGFloat?, usesLastGeometry: Bool = true, fallback: @escaping (CGFloat) -> Void) {
        hasBegun = true
        serial += 1
        if landingY != nil { landingY = nil }
        guard let y, y > 0.5 else {
            if pendingY != nil { pendingY = nil }
            return
        }
        if usesLastGeometry, let reachable = lastReachableY, reachable + 0.5 >= y {
            if pendingY != nil { pendingY = nil }
            land(at: y)
            fallback(y)
            return
        }
        if !usesLastGeometry { lastReachableY = nil }
        pendingY = y
        let mine = serial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.serial == mine, let pending = self.pendingY else { return }
            self.pendingY = nil
            let target = min(pending, self.lastReachableY ?? pending)
            self.land(at: target)
            fallback(target)
        }
    }

    /// 動かした。実測がその位置を報告するまで隠しておく。報告が来ないまま(もう同じ位置にいた・中身が変わった)でも、
    /// 少し待ったら見せる(隠したままにしない)。
    private func land(at y: CGFloat) {
        landingY = y
        let mine = serial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.serial == mine, self.landingY != nil else { return }
            self.landingY = nil
        }
    }

    /// 最後に測った「いちばん下まで動かしたときの位置」。
    @ObservationIgnored private var lastReachableY: CGFloat?

    /// 実測が届いた。戻す途中なら、届く高さになったときの位置を返す(呼び出し側が動かす)。そうでなければ控えを書き換える。
    func observe(_ metrics: Metrics, key: String, memory: HomeScrollMemory) -> CGFloat? {
        guard metrics.contentHeight > 0, metrics.visibleHeight > 0 else { return nil }
        let reachable = max(0, metrics.contentHeight - metrics.visibleHeight)
        lastReachableY = reachable
        if let y = pendingY {
            guard reachable + 0.5 >= y else { return nil }
            pendingY = nil
            serial += 1
            land(at: y)
            return y
        }
        if let y = landingY {
            // 動かした位置に着いたと実測が言うまでは見せない・控えない(動く前の 0 を控えにしない)。
            guard abs(metrics.offsetY - y) < 1 else { return nil }
            landingY = nil
        }
        guard hasBegun else { return nil }
        memory.save(CGPoint(x: 0, y: metrics.offsetY), for: key)
        return nil
    }

    /// 戻す途中か(スマートライブラリのグリッドが、戻す間は選択の枠へ寄せない)。
    var isRestoring: Bool { pendingY != nil }
}

