import AppKit
import Combine
import SwiftUI

/// 余白から帯(ラバーバンド)を引いて、コレクション/本をまとめて選ぶための一式
/// (ユーザー要望 2026-09-10)。コレクションの一覧(CollectionGridView)とコレクションの中
/// (CollectionDetailView)の2画面が、編集モードのあいだだけ使う。
///
/// ■ 引き始められるのはセルの外だけ
/// 帯を掴む場所はグリッドの**背景**に置いてある(MarqueeSelectable)。セルの上で押し始めた
/// ドラッグはセル側のもの(クリックで選ぶ/開く)のままで、余白 ―― タイルの隙間・外周・
/// 最後の行より下 ―― からだけ帯が出る(Finderと同じ約束。ユーザーの選択 2026-09-10)。
/// 札の上からも引けるようにするにはCollectionTileのButtonを外し、閾値を超えたクリックを
/// 捨てる仕掛けが要る ―― セルの中へジェスチャーを足すのはこのアプリで何度も痛い目を見て
/// いる(BookmarkListViewの「ここには絶対にジェスチャーを付けないこと」)ので、そちらへは
/// 踏み込んでいない。
///
/// ■ 帯は選択を「足す」
/// 編集モードのクリックはトグル(押すたびに選ぶ/外す)なので、帯も**足す**側へ揃える ――
/// 余白を引くたびに既存の選択が消えると、クリックの規則と食い違う。⌘を押しながら引いたぶんは
/// 逆に**外す**。引き始めた時点の選択(`base`)を控えてあるので、行きすぎた帯を縮めれば
/// そのぶんは元へ戻る。
///
/// ■ 画面外の行は「通りながら」拾う
/// LazyVGridは見えているぶんしかセルを作らないため、一度も表示していない行の矩形は手元に
/// 無い。帯の先が上端/下端に近づいたら自動でスクロールし(`tick`)、そこで作られた行の矩形を
/// 拾いながら数え直す。当たり判定は毎フレーム`base`から組み直しているので、矩形が1フレーム
/// 遅れて届いても次のフレームで正しい結果に収束する。
///
/// スクロールは裏のNSScrollViewを直に動かす(ScrollViewBounds)。SwiftUIの`ScrollPosition`
/// だと位置を持つ`@State`がドラッグ中ずっと書き換わり、一覧全体のbodyが毎フレーム走る。
///
/// ■ publishするのは帯だけ
/// 矩形の控えは`@Published`にしない ―― スクロールのたびに何十件も書き換わる値で、publishすると
/// 一覧のbodyが毎フレーム評価される(PanelListScrollTrackerが実測値を参照型に控えるのと同じ
/// 判断)。帯そのものも、購読するのは帯を描く小さなビュー(MarqueeBandView)だけにしてある。
/// 一覧側はこのオブジェクトを`@State`で持つだけで購読しない。
///
/// ■ 選ぶものの鍵は`AnyHashable`(改善要望7 段階3、2026-09-13)
/// 本棚の2画面は`UUID`、ファイルブラウザのアイコン表示はパス(`String`)で選ぶ。鍵の型の出し入れは
/// ビュー側の修飾(`marqueeCell` / `marqueeSelectable`、どちらも型引数付き)が受け持つ。
/// **このクラス自体を型引数付きにしてはいけない** ―― `MarqueeSelection<ID>`にしたところ、Release(-O)の
/// ビルドでコンパイラが`deinit`の最適化(EarlyPerfInliner)中に落ちた(Swift 6.3.3、2026-09-13 実測)。
/// Debug では通るので、CI の Release ジョブで初めて見つかる種類の壊れ方。
@MainActor
final class MarqueeSelection: ObservableObject {
    typealias ID = AnyHashable

    /// 帯の意味。
    enum Mode {
        /// 帯は選択を**足す**(⌘で外す)。本棚の編集モード ―― クリックがトグルなのに揃える。
        case additive
        /// Finderと同じ: 修飾キーなしの帯は選択を**置き換え**、⇧/⌘を押しながらなら足す。
        /// ファイルブラウザ ―― クリックが「その1件だけを選ぶ」なのに揃える。
        case replacing
    }

    /// いま引いている帯(`coordinateSpace`の座標)。nilなら引いていない。
    @Published private(set) var band: CGRect?

    /// 自動スクロールに使う、裏のNSScrollViewの入れ物(ScrollViewAccessor参照)。
    let scrollBox = ScrollGeometryBox()

    /// セルの矩形(`coordinateSpace`の座標)。型コメントの理由でpublishしない。
    private var frames: [ID: CGRect] = [:]
    /// 帯の起点。押した場所で、スクロールしても動かない(コンテンツ側の座標なので)。
    private var anchor: CGPoint = .zero
    /// 帯のいまの角。自動スクロールで中身が動いたぶんもここへ足し込む。
    private var corner: CGPoint = .zero
    /// 引き始めた時点の選択。
    private var base: Set<ID> = []
    /// いま画面に出ているものだけを相手にするための絞り(型コメント「足す」参照)。
    /// **見えていないものを選ばない**という決まりを、ここで最後に担保する
    /// (WelcomeLibraryState.selectedCollectionIDsのコメント)。
    private var shown: Set<ID> = []
    /// ⌘を押しながら引き始めたか(選んだぶんを外す)。
    private var isSubtracting = false
    /// 選択の書き戻し口。ドラッグのあいだだけ持つ。
    private var apply: ((Set<ID>) -> Void)?
    /// 最後に書き戻した選択。同じ値を書き戻さない(publishの空振りを避ける)ためだけに持つ。
    private var applied: Set<ID>?
    /// 自動スクロールのループ。
    private var ticker: Task<Void, Never>?

    /// 端からこの距離まで近づいたら自動スクロールを始める。
    private static let autoScrollMargin: CGFloat = 32

    // MARK: - セルの矩形

    func setFrame(_ rect: CGRect, for id: ID) {
        frames[id] = rect
    }

    /// 控えをまとめて捨てる。並ぶものが総入れ替えになる契機(ライブラリ/コレクションの
    /// 切り替え、グリッドの作り直し)で呼ぶ ―― 残しておくと、いま見えていないものの矩形が
    /// 当たり判定に混ざる。
    func forgetFrames() {
        frames.removeAll()
    }

    // MARK: - 帯

    func begin(
        at point: CGPoint, selection: Set<ID>, shown: Set<ID>, mode: Mode = .additive,
        apply: @escaping (Set<ID>) -> Void
    ) {
        anchor = point
        corner = point
        switch mode {
        case .additive:
            base = selection
        case .replacing:
            base = Self.isExtendingSelection ? selection : []
        }
        self.shown = shown
        self.apply = apply
        applied = selection
        // 修飾キーはSwiftUIのDragGestureからは読めないので、AppKit側から見る。途中で
        // 押し直しても意味は変わらない ―― 引き始めに決まった向き(足す/外す)のまま最後まで
        // 進むほうが、帯を戻したときの結果が読める。
        isSubtracting = mode == .additive && Self.isCommandDown
        band = Self.rect(from: anchor, to: corner)
        startTicking()
    }

    func drag(to point: CGPoint) {
        guard band != nil else { return }
        corner = point
        update()
    }

    /// 引き終わり。選んだ結果はそのまま残し、帯だけ消す。
    func end() {
        ticker?.cancel()
        ticker = nil
        apply = nil
        applied = nil
        band = nil
    }

    /// 引いている途中で画面の前提が変わったとき(編集モードを抜けた・画面が消えた)。
    /// `end()`と同じで、名前だけ分けてある。
    func cancel() {
        guard band != nil else { return }
        end()
    }

    /// 帯の中身を数え直して書き戻す。**毎回`base`から組み直す** ―― 差分で足し引きすると、
    /// 自動スクロール中に遅れて届いた矩形を取りこぼしたときに元へ戻せない。
    private func update() {
        let rect = Self.rect(from: anchor, to: corner)
        if band != rect { band = rect }
        var covered: Set<ID> = []
        for (id, frame) in frames where frame.intersects(rect) {
            covered.insert(id)
        }
        covered.formIntersection(shown)
        let next = isSubtracting ? base.subtracting(covered) : base.union(covered)
        guard next != applied else { return }
        applied = next
        apply?(next)
    }

    /// いま⌘が押されているか。
    ///
    /// **いま処理中のマウスイベントを先に見る。** `NSEvent.modifierFlags`はキーボードの
    /// 現在の状態を直に読む口で、実機では同じ答えになるが、合成したイベントで確かめられない
    /// (ハーネスから流したイベントの修飾キーは、この値には現れない)。処理中のイベントが
    /// マウスのものでないとき(取りこぼし)だけ、現在の状態へ落とす。
    private static var isCommandDown: Bool {
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown || event.type == .leftMouseDragged {
            return event.modifierFlags.contains(.command)
        }
        return NSEvent.modifierFlags.contains(.command)
    }

    /// ⇧か⌘が押されているか(`.replacing`の帯で「足す」に切り替える)。
    private static var isExtendingSelection: Bool {
        let flags: NSEvent.ModifierFlags
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown || event.type == .leftMouseDragged {
            flags = event.modifierFlags
        } else {
            flags = NSEvent.modifierFlags
        }
        return flags.contains(.command) || flags.contains(.shift)
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        )
    }

    // MARK: - 自動スクロール

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// 1フレームぶんの自動スクロールと数え直し。
    ///
    /// 端から離れている間も数え直しているのは、**自動スクロールで作られた行の矩形が1フレーム
    /// 遅れて届く**ため(指が止まっていてもdrag(to:)は来ない)。
    private func tick() {
        guard band != nil, let bounds = ScrollViewBounds(scrollBox.scrollView) else { return }
        let margin = Self.autoScrollMargin
        // 帯の先が、見えている範囲のどこにあるか(コンテンツ座標 - スクロール量)。
        let viewportY = corner.y - bounds.position.y
        let step: CGFloat
        if viewportY < margin {
            step = -Self.autoScrollStep(overshoot: margin - viewportY)
        } else if viewportY > bounds.visibleSize.height - margin {
            step = Self.autoScrollStep(overshoot: viewportY - (bounds.visibleSize.height - margin))
        } else {
            update()
            return
        }
        let before = bounds.position.y
        bounds.scroll(to: CGPoint(x: bounds.position.x, y: before + step))
        // 実際に動いたぶんだけ、カーソルの下にあるコンテンツ座標がずれる(指は動いていない)。
        // 端に着いて動けなかったときは0で、帯もその場に留まる。
        let after = ScrollViewBounds(scrollBox.scrollView)?.position.y ?? before
        corner.y += after - before
        update()
    }

    /// 端へ食い込んだ量に応じた、1フレームあたりのスクロール量(60fpsで約120〜1440pt/秒)。
    /// ウインドウの外までカーソルを出したときにいちばん速くなる。
    private static func autoScrollStep(overshoot: CGFloat) -> CGFloat {
        let t = min(1, max(0, overshoot) / (autoScrollMargin * 2))
        return 2 + 22 * t
    }
}

// MARK: - ビュー側

extension View {
    /// このセルの矩形を帯へ知らせる(帯の当たり判定に使う)。グリッドのセルに掛ける。
    func marqueeCell<ID: Hashable>(_ id: ID, in marquee: MarqueeSelection) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(MarqueeCoordinateSpace.name))
        } action: { rect in
            marquee.setFrame(rect, for: AnyHashable(id))
        }
    }

    /// 余白から帯を引いて選べるようにする。**ScrollViewの中身**(padding済みのグリッド)に
    /// 掛けること ―― 帯の座標空間・自動スクロールに使うNSScrollViewの取り出し・帯の描画が
    /// すべてここに乗る。
    ///
    /// - Parameters:
    ///   - minimumHeight: 中身をこの高さまで広げる(ScrollViewの見えている高さを渡す)。
    ///     並ぶものが少なくても、**最後の行より下の余白から帯を引ける**ようにするため。
    ///   - shownIDs: いま出ているもののid。見えていないものを選ばないための絞り。
    ///   - mode: 帯の意味(MarqueeSelection.Mode)。
    ///   - onBackgroundClick: 余白をクリックしたとき(帯にならなかったとき)。ファイルブラウザは
    ///     選択を外す(Finderと同じ)。
    func marqueeSelectable<ID: Hashable>(
        _ marquee: MarqueeSelection, isEnabled: Bool, minimumHeight: CGFloat,
        selection: Binding<Set<ID>>, shownIDs: Set<ID>,
        mode: MarqueeSelection.Mode = .additive,
        onBackgroundClick: (() -> Void)? = nil
    ) -> some View {
        modifier(
            MarqueeSelectable(
                marquee: marquee, isEnabled: isEnabled, minimumHeight: minimumHeight,
                selection: selection, shownIDs: shownIDs, mode: mode,
                onBackgroundClick: onBackgroundClick
            )
        )
    }
}

private struct MarqueeSelectable<ID: Hashable>: ViewModifier {
    let marquee: MarqueeSelection
    let isEnabled: Bool
    let minimumHeight: CGFloat
    @Binding var selection: Set<ID>
    let shownIDs: Set<ID>
    let mode: MarqueeSelection.Mode
    let onBackgroundClick: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .frame(minHeight: minimumHeight, alignment: .top)
            .background {
                ZStack {
                    // 自動スクロールのために裏のNSScrollViewを控える。**ScrollViewの内側**に
                    // 置くこと ―― 外側に付けると祖先をたどってもNSScrollViewに行き当たらない
                    // (ThumbnailGridViewの同じアクセサのコメント参照)。
                    ScrollViewAccessor(onResolve: { marquee.scrollBox.scrollView = $0 })
                    if isEnabled {
                        // 帯を掴む場所。セルの**後ろ**なので、セルの上で押し始めた
                        // ドラッグはここまで届かない(型コメント「セルの外だけ」参照)。
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(bandGesture)
                            .onTapGesture { onBackgroundClick?() }
                    }
                }
            }
            .overlay(alignment: .topLeading) { MarqueeBandView(marquee: marquee) }
            .coordinateSpace(.named(MarqueeCoordinateSpace.name))
            // 編集モードを抜けた/画面が消えた瞬間に引きかけの帯が残らないようにする
            // (ジェスチャーが取り付けごと消えるため、.onEndedは来ない)。
            .onChange(of: isEnabled) { marquee.cancel() }
            .onDisappear { marquee.cancel() }
    }

    private var bandGesture: some Gesture {
        // 4pt動くまでは帯にしない ―― 余白のクリックで選択が変わらないようにする
        // (余白を押しただけでは何も起きない、が編集モードの既定の振る舞い)。
        DragGesture(minimumDistance: 4, coordinateSpace: .named(MarqueeCoordinateSpace.name))
            .onChanged { value in
                if marquee.band == nil {
                    marquee.begin(
                        at: value.startLocation,
                        selection: Set(selection.map(AnyHashable.init)),
                        shown: Set(shownIDs.map(AnyHashable.init)),
                        mode: mode,
                        apply: { selection = Set($0.compactMap { $0.base as? ID }) }
                    )
                }
                marquee.drag(to: value.location)
            }
            .onEnded { _ in marquee.end() }
    }
}

/// 帯そのもの。**帯だけを描く小さなビューに切ってある** ―― ここでMarqueeSelectionを購読するのは、
/// 一覧本体にドラッグ中の毎フレームのbodyを走らせないため(MarqueeSelectionの型コメント参照)。
///
/// すりガラス面の決まりごと: 帯が持つのは薄いアクセント色の地だけで「自前の不透明な地を持つ
/// 部品」には当たらない。面をアクセント色で塗られると帯ごと溶けて**いま何を囲んでいるのかが
/// 伝わらなくなる**ので、`.panelOutlinedAccent(in:)`を掛ける。
private struct MarqueeBandView: View {
    @ObservedObject var marquee: MarqueeSelection

    var body: some View {
        if let band = marquee.band {
            let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
            shape
                .fill(Color.accentColor.opacity(0.18))
                .overlay { shape.strokeBorder(Color.accentColor, lineWidth: 1) }
                .frame(width: band.width, height: band.height)
                .panelOutlinedAccent(in: shape)
                .offset(x: band.minX, y: band.minY)
                .allowsHitTesting(false)
        }
    }
}

/// セルの矩形と帯の座標をやりとりする座標空間の名前(グリッドの中身に張る)。
/// 型引数付きの修飾(MarqueeSelectable)からも同じ名前を引くため、クラスの外に置いてある。
/// `nonisolated`にしてあるのは、`.onGeometryChange`の測る側の閉包(Sendable。
/// メインアクターの外から呼ばれうる)から名前を参照するため。
enum MarqueeCoordinateSpace {
    nonisolated static let name = "welcome.marquee"
}
