import SwiftUI
import AppKit

/// SwiftUIの`ScrollView`を裏で描画している`NSScrollView`を掴み、現在位置と可動範囲を
/// 正確に読み書きするための一式。
///
/// 元はViewerView.swiftの中にprivateで置いてあった(ビューアのスクロール送り専用だった)。
/// ページ一覧パネルのホイールスクロール量(ユーザー要望)でも同じものが必要になったため、
/// ファイルへ切り出して共有している。**中身は切り出し前から変えていない。**

final class ScrollGeometryBox {
    /// SwiftUIのScrollViewを実際に描画しているNSScrollView(ScrollViewAccessor参照)。
    weak var scrollView: NSScrollView?
}

/// SwiftUIのScrollViewを裏で描画しているNSScrollViewを取り出して、呼び出し側へ渡すための
/// 何も描画しないヘルパービュー(PageAreaFrameAccessor/WindowMouseExitAccessorと同じ作り)。
///
/// なぜ必要か: スクロール送り(ViewerView.scrollByOneScreen)は「もう下端か」「横に動く余地が
/// あるか」を正確に知る必要がある。当初はSwiftUIのScrollGeometry(onScrollGeometryChange)で
/// 済ませようとしたが、実機で計測したところ、報告される値から可動範囲を導けなかった:
///
/// - contentOffsetは0起点ではなく、contentInsets(自動表示されるツールバーぶん、上32pt)だけ
///   ずれる
/// - visibleRect.sizeは縦スクロールバーの幅(17pt)を含んでおり、横方向の実際の可動量
///   (contentSize.width - この値)より17pt小さく出る
/// - 縦は逆に、contentSize.height - visibleRect.height よりさらにインセットぶん小さいところで
///   止まる
///
/// 結果として「下端に着いているのに、まだ下へ動けると判定し続ける」ため、横への回り込みへ
/// 永久に到達しなかった。NSScrollViewのcontentView(NSClipView)なら、現在位置も可動範囲も
/// 意味が一意に定まる(cooViewerも同じくNSScrollViewを直接扱っている)。
struct ScrollViewAccessor: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void
    /// スクロールされる中身(documentView)の大きさが実際に変わったときに呼ばれる。
    /// 位置合わせを必要としない使い方(ページ一覧パネルのホイールスクロール)では省略できる。
    /// = 新しいページの画像がレイアウトに反映され、可動範囲が確定した瞬間。
    /// ページ切り替え直後の位置合わせは、この通知を待ってから行う必要がある
    /// (ViewerView.beginPageEntryScrollのコメント参照)。
    var onDocumentFrameChange: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// documentViewのフレーム変化を購読する係。Viewは値型で作り直されるため、購読の
    /// 登録・解除を持てるのはCoordinatorだけ(deinitで確実に解除する)。
    final class Coordinator {
        var parent: ScrollViewAccessor
        private var observation: NSObjectProtocol?
        private weak var observedDocumentView: NSView?

        init(_ parent: ScrollViewAccessor) { self.parent = parent }

        func observeDocumentView(of scrollView: NSScrollView?) {
            guard let documentView = scrollView?.documentView else { return }
            // 同じdocumentViewを二重に購読しない(updateNSViewは何度でも呼ばれる)。
            guard documentView !== observedDocumentView else { return }
            stopObserving()
            observedDocumentView = documentView
            documentView.postsFrameChangedNotifications = true
            observation = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: documentView, queue: .main
            ) { [weak self] _ in
                // queue: .main で登録しているため必ずメインスレッドで呼ばれる。
                MainActor.assumeIsolated {
                    self?.parent.onDocumentFrameChange()
                }
            }
        }

        func stopObserving() {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            observedDocumentView = nil
        }

        deinit { stopObserving() }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // 取り付け直後はまだビュー階層に入っていないため、次のループで探す。
        DispatchQueue.main.async {
            let scrollView = Self.enclosingScrollView(of: view)
            onResolve(scrollView)
            context.coordinator.observeDocumentView(of: scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // onResolve/onDocumentFrameChangeはView再構築のたびに新しいクロージャになるため、
        // 古いものを握ったままにしないよう毎回差し替える(ClickZoneAreaと同じ理由)。
        context.coordinator.parent = self
        DispatchQueue.main.async {
            let scrollView = Self.enclosingScrollView(of: nsView)
            onResolve(scrollView)
            context.coordinator.observeDocumentView(of: scrollView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    /// このビューはScrollViewのコンテンツの中(background)に置くため、祖先をたどれば
    /// 目的のNSScrollViewに必ず行き当たる(ClickZoneViewのように兄弟を探す必要はない)。
    private static func enclosingScrollView(of view: NSView) -> NSScrollView? {
        var ancestor: NSView? = view.superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView { return scrollView }
            ancestor = current.superview
        }
        return nil
    }
}

/// NSScrollViewの現在位置と可動範囲を、「上が0」に正規化して扱うための小さな窓口。
///
/// SwiftUIのScrollGeometryを使わない理由はScrollViewAccessorのコメント参照(自動表示される
/// ツールバー/プログレスバーがある状態で、報告される値から可動範囲を導けなかった)。
/// NSClipViewのboundsとdocumentViewのframeなら、意味が一意に定まり自動表示の影響も受けない。
struct ScrollViewBounds {
    private let scrollView: NSScrollView
    private let clipView: NSClipView
    private let isDocumentFlipped: Bool
    let contentSize: CGSize
    /// 実際に見えている領域の大きさ。「1画面分」スクロールする量にもこれを使う。
    let visibleSize: CGSize

    init?(_ scrollView: NSScrollView?) {
        guard let scrollView, let documentView = scrollView.documentView else { return nil }
        self.scrollView = scrollView
        self.clipView = scrollView.contentView
        self.contentSize = documentView.frame.size
        self.visibleSize = scrollView.contentView.bounds.size
        self.isDocumentFlipped = documentView.isFlipped
    }

    var maxX: CGFloat { max(contentSize.width - visibleSize.width, 0) }
    var maxY: CGFloat { max(contentSize.height - visibleSize.height, 0) }

    /// 現在のスクロール位置(左上を原点とし、下へ進むほどyが増える向きに正規化した値)。
    /// AppKitのdocumentViewは上下が反転していないことがあるため、ここで吸収する。
    var position: CGPoint {
        let origin = clipView.bounds.origin
        return CGPoint(x: origin.x, y: isDocumentFlipped ? origin.y : maxY - origin.y)
    }

    /// positionと同じ向きで指定した位置へスクロールする(可動範囲へクランプする)。
    func scroll(to point: CGPoint) {
        let clampedX = min(max(point.x, 0), maxX)
        let clampedY = min(max(point.y, 0), maxY)
        let y = isDocumentFlipped ? clampedY : maxY - clampedY
        clipView.scroll(to: CGPoint(x: clampedX, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }
}

