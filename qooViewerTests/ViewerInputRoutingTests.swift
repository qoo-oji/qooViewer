import AppKit
import Foundation
import Testing

@testable import qooViewer

/// ビューアへ届いた入力の振り分け・ホイールの間引き・1 画面ぶんの送り(Models/ViewerInputRouting.swift)。
///
/// 2026-10-11 まではビューア(ViewerView)のイベントモニタの中にあり、テストから通せなかった。どの判定も、ユーザー報告で
/// 直してきた振る舞い(ページ一覧を同じキーで閉じる、サイドパネルの上のホイールでページを送らない、拡大中は 2 本指で送らない …)
/// なので、ここで 1 つずつ固定する。
@MainActor
struct ViewerInputRoutingTests {
    private func key(_ keyCode: UInt16, _ characters: String = "", modifiers: NSEvent.ModifierFlags = [],
                     action: ViewerAction? = nil) -> ViewerInputEvent {
        ViewerInputEvent(kind: .keyDown, keyCode: keyCode, charactersIgnoringModifiers: characters,
                         modifierFlags: modifiers, resolvedKeyAction: action)
    }

    private func wheelEvent(phase: NSEvent.Phase = [], modifiers: NSEvent.ModifierFlags = [],
                            inSidePanel: Bool = false) -> ViewerInputEvent {
        ViewerInputEvent(kind: .scrollWheel, modifierFlags: modifiers, phase: phase, isPointerInDockedSidePanel: inSidePanel)
    }

    // MARK: - 振り分け: ページ一覧・サイドパネル・情報パネル

    @Test("マウス移動は、ページ一覧を出していても必ずカーソルとクロームの処理へ回る")
    func mouseMovesAlwaysReachTheCursorHandling() {
        let event = ViewerInputEvent(kind: .mouseMoved)
        #expect(ViewerInputRouter.route(event, in: .init()) == .mouseMoved)
        #expect(ViewerInputRouter.route(event, in: .init(isThumbnailGridShown: true)) == .mouseMoved)
        #expect(ViewerInputRouter.route(event, in: .init(isSidePanelFloatingOverlay: true)) == .mouseMoved)
    }

    @Test("ページ一覧を出している間: 開いたのと同じキーで閉じる。Esc・Return・Enter で閉じ、矢印で動かす。ほかは背後の本へ届かない")
    func thumbnailGridTakesItsOwnKeys() {
        let grid = ViewerInputContext(isThumbnailGridShown: true)
        #expect(ViewerInputRouter.route(key(17, "t", action: .showThumbnailGrid), in: grid) == .perform(.showThumbnailGrid))
        for code: UInt16 in [53, 36, 76] {
            #expect(ViewerInputRouter.route(key(code), in: grid) == .closeThumbnailGrid)
        }
        for code: UInt16 in [123, 124, 125, 126] {
            #expect(ViewerInputRouter.route(key(code), in: grid) == .moveThumbnailGridCursor(keyCode: code))
        }
        // 修飾キー付きはメニューへ。割り当てのあるほかのキー・ホイールは背後の本を送らない。
        #expect(ViewerInputRouter.route(key(124, modifiers: .command), in: grid) == .pass)
        #expect(ViewerInputRouter.route(key(49, " ", action: .moveNext), in: grid) == .pass)
        #expect(ViewerInputRouter.route(wheelEvent(), in: grid) == .pass)
        // 欄を編集している間は、閉じるキーも欄のもの。
        var editing = grid
        editing.isEditingText = true
        #expect(ViewerInputRouter.route(key(53), in: editing) == .pass)
    }

    @Test("浮かせたサイドパネルを出している間は、キーもホイールも背後の本へ届かない")
    func floatingSidePanelBlocksTheBook() {
        let floating = ViewerInputContext(isSidePanelFloatingOverlay: true)
        #expect(ViewerInputRouter.route(key(49, " ", action: .moveNext), in: floating) == .pass)
        #expect(ViewerInputRouter.route(wheelEvent(), in: floating) == .pass)
        // ページ一覧と重なっていても、ページ一覧のキーは働かせない(パネルが前)。
        #expect(ViewerInputRouter.route(key(53), in: .init(isThumbnailGridShown: true, isSidePanelFloatingOverlay: true)) == .pass)
    }

    @Test("「情報を見る」の間は本を送らない: Esc・Return・Enter で閉じ、ほかのキーとホイールは消費、修飾キー付きはメニューへ")
    func pageInfoPanelHoldsTheBook() {
        let info = ViewerInputContext(isPageInfoPanelShown: true)
        #expect(ViewerInputRouter.route(key(53), in: info) == .closePageInfoPanel)
        #expect(ViewerInputRouter.route(key(36), in: info) == .closePageInfoPanel)
        #expect(ViewerInputRouter.route(key(49, " ", action: .moveNext), in: info) == .consume)
        #expect(ViewerInputRouter.route(key(0, "a", modifiers: .command, action: .moveNext), in: info) == .pass)
        #expect(ViewerInputRouter.route(wheelEvent(), in: info) == .consume)
        #expect(ViewerInputRouter.route(ViewerInputEvent(kind: .swipe), in: info) == .consume)
        #expect(ViewerInputRouter.route(ViewerInputEvent(kind: .magnify), in: info) == .pass)
    }

    @Test("常時表示のサイドパネルの上のホイールは一覧のもの(ページを送らない)。キーはカーソルの位置に関わらず効く")
    func dockedSidePanelKeepsItsScrolling() {
        #expect(ViewerInputRouter.route(wheelEvent(inSidePanel: true), in: .init()) == .pass)
        #expect(ViewerInputRouter.route(ViewerInputEvent(kind: .magnify, isPointerInDockedSidePanel: true), in: .init()) == .pass)
        var keyInPanel = key(49, " ", action: .moveNext)
        keyInPanel.isPointerInDockedSidePanel = true
        #expect(ViewerInputRouter.route(keyInPanel, in: .init()) == .perform(.moveNext))
    }

    // MARK: - 振り分け: ホイール

    @Test("物理ホイールはホイールへ。ホイールの割り当ての修飾キーは option と無印だけ(control・command・shift は対象外)")
    func mouseWheelGoesToTheWheel() {
        #expect(ViewerInputRouter.route(wheelEvent(), in: .init()) == .wheel(isInverted: false, modifiers: [], invertsScroll: false))
        #expect(ViewerInputRouter.route(wheelEvent(modifiers: .option), in: .init())
            == .wheel(isInverted: false, modifiers: .option, invertsScroll: false))
        for flags: NSEvent.ModifierFlags in [.control, .command, .shift] {
            #expect(ViewerInputRouter.route(wheelEvent(modifiers: flags), in: .init())
                == .wheel(isInverted: false, modifiers: nil, invertsScroll: false))
        }
        // 反転は phase を伴うスクロールだけ(物理ホイールのノッチは対象外)。
        #expect(ViewerInputRouter.route(wheelEvent(), in: .init(isPageAreaScrollable: true, invertsTwoFingerScrolling: true))
            == .wheel(isInverted: false, modifiers: [], invertsScroll: false))
    }

    @Test("2本指のスワイプでページ送りが ON なら、トラックパッドのスクロールはジェスチャーへ。拡大中は送らずにスクロールへ")
    func trackpadScrollGoesToTheGestureUnlessZoomed() {
        let flick = ViewerInputContext(isPageAreaScrollable: true, treatsTrackpadFlickAsWheel: true)
        #expect(ViewerInputRouter.route(wheelEvent(phase: .changed), in: flick) == .trackpadGesture(invertsScroll: false))
        var inverted = flick
        inverted.invertsTwoFingerScrolling = true
        #expect(ViewerInputRouter.route(wheelEvent(phase: .changed), in: inverted) == .trackpadGesture(invertsScroll: true))

        var zoomed = inverted
        zoomed.pinchZoomFactor = 2
        #expect(ViewerInputRouter.route(wheelEvent(phase: .changed), in: zoomed)
            == .wheel(isInverted: true, modifiers: [], invertsScroll: true))
        // 慣性(momentumPhase だけ)もトラックパッド由来。
        let momentum = ViewerInputEvent(kind: .scrollWheel, momentumPhase: .changed)
        #expect(ViewerInputRouter.route(momentum, in: flick) == .trackpadGesture(invertsScroll: false))
        // 設定が OFF ならホイールの扱い(反転だけが効く)。
        #expect(ViewerInputRouter.route(wheelEvent(phase: .changed), in: .init(isPageAreaScrollable: true))
            == .wheel(isInverted: false, modifiers: [], invertsScroll: false))
    }

    // MARK: - 振り分け: キー

    @Test("キー: 欄の編集中は横取りしない。割り当てのあるキーは実行し、無いキーは通す")
    func keysRunTheirAssignmentsUnlessEditing() {
        #expect(ViewerInputRouter.route(key(49, " ", action: .moveNext), in: .init()) == .perform(.moveNext))
        #expect(ViewerInputRouter.route(key(0, "a"), in: .init()) == .pass)
        #expect(ViewerInputRouter.route(key(49, " ", action: .moveNext), in: .init(isEditingText: true)) == .pass)
    }

    @Test("⌘= は拡大(上限ではビープ。ルーペの間は上限に関わらず拡大の段へ)")
    func commandEqualsZoomsIn() {
        let commandEquals = key(24, "=", modifiers: .command)
        #expect(ViewerInputRouter.route(commandEquals, in: .init(pinchZoomFactor: 1, maxPinchZoomFactor: 4)) == .zoomIn)
        #expect(ViewerInputRouter.route(commandEquals, in: .init(pinchZoomFactor: 4, maxPinchZoomFactor: 4)) == .beep)
        #expect(ViewerInputRouter.route(commandEquals, in: .init(isLoupeActive: true, pinchZoomFactor: 4, maxPinchZoomFactor: 4))
            == .zoomIn)
        // JIS 配列の ⇧⌘- も "=" なので Shift は問わない。⌥⌘= は拡大にしない(メニューへ)。
        #expect(ViewerInputRouter.route(key(27, "=", modifiers: [.command, .shift]), in: .init()) == .zoomIn)
        #expect(ViewerInputRouter.route(key(24, "=", modifiers: [.command, .option]), in: .init()) == .pass)
    }

    @Test("Esc はルーペ → ピンチ拡大の順に閉じ、どちらも無ければ割り当て・標準の Esc に任せる")
    func escapeClosesLoupeThenZoom() {
        #expect(ViewerInputRouter.route(key(53), in: .init(isLoupeActive: true, pinchZoomFactor: 2)) == .closeLoupe)
        #expect(ViewerInputRouter.route(key(53), in: .init(pinchZoomFactor: 2)) == .resetPinchZoom)
        #expect(ViewerInputRouter.route(key(53), in: .init()) == .pass)
    }

    @Test("実物のキーイベントから組み立てた入力も同じ振り分けになる")
    func eventFromNSEventRoutesTheSame() throws {
        let nsEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
            characters: "=", charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24
        ))
        let event = ViewerInputEvent(nsEvent, resolvedKeyAction: nil, isPointerInDockedSidePanel: false)
        #expect(event.kind == .keyDown)
        #expect(event.keyCode == 24)
        #expect(event.isTrackpadOriginated == false)
        #expect(ViewerInputRouter.route(event, in: .init()) == .zoomIn)
    }

    // MARK: - ホイールの間引き

    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func actions(_ direction: MouseTrigger.WheelDirection, _ modifiers: MouseTrigger.Modifiers) -> ViewerAction? {
        switch (direction, modifiers) {
        case (.up, []): .movePrevious
        case (.down, []): .moveNext
        case (.up, .option): .firstPage
        case (.down, .option): .lastPage
        default: nil
        }
    }

    private func wheel(
        _ input: inout ViewerWheelInput, deltaY: CGFloat, at seconds: TimeInterval = 0, isInverted: Bool = false,
        modifiers: MouseTrigger.Modifiers? = [], scrollable: Bool = false, pinch: CGFloat = 1,
        behavior: WheelScrollBehavior = .scrollAndTurnPage, metrics: ViewerScrollMetrics? = nil
    ) -> ViewerWheelInput.WheelOutcome {
        input.wheel(
            deltaY: deltaY, isInverted: isInverted, modifiers: modifiers, isPageAreaScrollable: scrollable,
            pinchZoomFactor: pinch, configuredBehavior: behavior, metrics: metrics,
            now: start.addingTimeInterval(seconds), action: actions
        )
    }

    private func metrics(y: CGFloat, maxY: CGFloat = 1000, x: CGFloat = 0, maxX: CGFloat = 0) -> ViewerScrollMetrics {
        ViewerScrollMetrics(position: CGPoint(x: x, y: y), maxX: maxX, maxY: maxY, visibleSize: CGSize(width: 800, height: 600))
    }

    @Test("画面内に収める: ホイールの割り当てを実行する。上へ回すと「上」、ごく小さい動きと 0.04 秒以内の連続は数えない")
    func fitToScreenWheelRunsAssignmentsWithCooldown() {
        var input = ViewerWheelInput()
        #expect(wheel(&input, deltaY: 1) == .unhandled)
        #expect(wheel(&input, deltaY: 5) == .perform(.movePrevious))
        #expect(wheel(&input, deltaY: -5, at: 0.02) == .unhandled)
        #expect(wheel(&input, deltaY: -5, at: 0.05) == .perform(.moveNext))
        #expect(wheel(&input, deltaY: 5, at: 1, modifiers: .option) == .perform(.firstPage))
        #expect(wheel(&input, deltaY: 5, at: 2, modifiers: nil) == .unhandled)
    }

    @Test("スクロールできるとき: 修飾キー付きは割り当てがあれば実行、無ければ ScrollView に任せる")
    func scrollableModifiedWheelNeedsAnAssignment() {
        var input = ViewerWheelInput()
        #expect(wheel(&input, deltaY: -5, modifiers: .option, scrollable: true) == .perform(.lastPage))
        #expect(wheel(&input, deltaY: -5, at: 1, modifiers: .shift, scrollable: true) == .unhandled)
        #expect(wheel(&input, deltaY: -5, at: 2, modifiers: nil, scrollable: true) == .unhandled)
    }

    @Test("スクロールできるとき: 「スクロールのみ」と拡大中は任せる。「ページを送る」は反転の影響を受けずに割り当てを実行する")
    func scrollableBehaviors() {
        var input = ViewerWheelInput()
        #expect(wheel(&input, deltaY: -5, scrollable: true, behavior: .scrollOnly) == .unhandled)
        #expect(wheel(&input, deltaY: -5, scrollable: true, pinch: 2, behavior: .turnPage) == .unhandled)
        #expect(wheel(&input, deltaY: -5, scrollable: true, behavior: .turnPage) == .perform(.moveNext))
        // 反転は画像が動く向きだけ。割り当ての上下は入れ替えない。
        #expect(wheel(&input, deltaY: -5, at: 1, isInverted: true, scrollable: true, behavior: .turnPage) == .perform(.moveNext))
    }

    @Test("スクロールできるとき: 端に着くまでは任せ、端でもう一度回したら 1 画面送り(「回り込み」はページをめくらない)")
    func scrollableWheelTakesOverAtTheEdge() {
        var input = ViewerWheelInput()
        #expect(wheel(&input, deltaY: -5, scrollable: true, metrics: metrics(y: 500)) == .unhandled)
        #expect(wheel(&input, deltaY: -5, scrollable: true, metrics: nil) == .unhandled)
        #expect(wheel(&input, deltaY: -5, scrollable: true, metrics: metrics(y: 1000))
            == .scrollByOneScreen(forward: true, allowPageChange: true))
        #expect(wheel(&input, deltaY: 5, at: 1, scrollable: true, metrics: metrics(y: 0))
            == .scrollByOneScreen(forward: false, allowPageChange: true))
        #expect(wheel(&input, deltaY: -5, at: 2, scrollable: true, behavior: .scrollAndWrap, metrics: metrics(y: 1000))
            == .scrollByOneScreen(forward: true, allowPageChange: false))
        // 反転では、内容が進む向きが逆になる(上へ動かす指で下端から先へ)。
        #expect(wheel(&input, deltaY: 5, at: 3, isInverted: true, scrollable: true, metrics: metrics(y: 1000))
            == .scrollByOneScreen(forward: true, allowPageChange: true))
        // 端の 1px 未満のずれは端とみなす。
        #expect(wheel(&input, deltaY: -5, at: 4, scrollable: true, metrics: metrics(y: 999.5))
            == .scrollByOneScreen(forward: true, allowPageChange: true))
    }

    @Test("3本指/4本指のスワイプ: 設定が ON のときだけ、右へ払えば「上」の割り当て。0.3 秒以内の連続は数えない")
    func swipeCooldown() {
        var input = ViewerWheelInput()
        #expect(input.swipe(deltaX: 1, isEnabled: false, now: start) == nil)
        #expect(input.swipe(deltaX: 1, isEnabled: true, now: start) == .up)
        #expect(input.swipe(deltaX: -1, isEnabled: true, now: start.addingTimeInterval(0.2)) == nil)
        #expect(input.swipe(deltaX: -1, isEnabled: true, now: start.addingTimeInterval(0.4)) == .down)
    }

    @Test("2本指のジェスチャー: 指を離した時点で 1 回だけ。横方向優位で 10 以上動いたときだけ送り、慣性は数えない")
    func trackpadGestureFiresOnceAtTheEnd() {
        var input = ViewerWheelInput()
        #expect(input.trackpadGesture(phase: .began, deltaX: 8, deltaY: 1) == nil)
        #expect(input.trackpadGesture(phase: .changed, deltaX: 8, deltaY: 1) == nil)
        #expect(input.trackpadGesture(phase: [], deltaX: 100, deltaY: 0) == nil)  // 慣性
        #expect(input.trackpadGesture(phase: .ended, deltaX: 0, deltaY: 0) == .up)
        #expect(input.trackpadGestureDeltaX == 0)

        // 縦方向優位(2本指の縦スクロール)は無視。
        _ = input.trackpadGesture(phase: .began, deltaX: -20, deltaY: 30)
        #expect(input.trackpadGesture(phase: .ended, deltaX: 0, deltaY: 0) == nil)
        // 触れただけ。
        _ = input.trackpadGesture(phase: .began, deltaX: -5, deltaY: 0)
        #expect(input.trackpadGesture(phase: .ended, deltaX: 0, deltaY: 0) == nil)
        // 左へ払えば「下」。
        _ = input.trackpadGesture(phase: .began, deltaX: -30, deltaY: 2)
        #expect(input.trackpadGesture(phase: .ended, deltaX: 0, deltaY: 0) == .down)
    }

    // MARK: - 1 画面ぶんの送り

    @Test("1画面送り: 縦に余地があれば縦へ、端なら読み方向へ横へ回り込み、どちらも無ければページを送る(戻るときは読み終わりの隅から)")
    func oneScreenStepsThroughThreeStages() {
        let ltr = ReadingDirection.leftToRight
        #expect(ViewerScrollPlanner.oneScreen(forward: true, allowPageChange: true, metrics: metrics(y: 100), readingDirection: ltr)
            == .scroll(to: CGPoint(x: 0, y: 700)))
        #expect(ViewerScrollPlanner.oneScreen(
            forward: true, allowPageChange: true, metrics: metrics(y: 1000, x: 0, maxX: 800), readingDirection: ltr
        ) == .scroll(to: CGPoint(x: 800, y: 0)))
        // 右開きでは、進むと左へ(x が減る)。戻るときは縦の下端へ。
        #expect(ViewerScrollPlanner.oneScreen(
            forward: true, allowPageChange: true, metrics: metrics(y: 1000, x: 800, maxX: 800), readingDirection: .rightToLeft
        ) == .scroll(to: CGPoint(x: 0, y: 0)))
        #expect(ViewerScrollPlanner.oneScreen(
            forward: false, allowPageChange: true, metrics: metrics(y: 0, x: 800, maxX: 800), readingDirection: ltr
        ) == .scroll(to: CGPoint(x: 0, y: 1000)))
        #expect(ViewerScrollPlanner.oneScreen(forward: true, allowPageChange: true, metrics: metrics(y: 1000), readingDirection: ltr)
            == .advance(forward: true, entersAtEnd: false))
        #expect(ViewerScrollPlanner.oneScreen(forward: false, allowPageChange: true, metrics: metrics(y: 0), readingDirection: ltr)
            == .advance(forward: false, entersAtEnd: true))
        #expect(ViewerScrollPlanner.oneScreen(forward: true, allowPageChange: false, metrics: metrics(y: 1000), readingDirection: ltr)
            == .none)
    }

    @Test("1画面送り: スクロールできない(画面内に収める)ならページ送りへ縮退し、回り込みだけのときは止まる")
    func oneScreenWithoutScrollingTurnsThePage() {
        #expect(ViewerScrollPlanner.oneScreen(forward: true, allowPageChange: true, metrics: nil, readingDirection: .leftToRight)
            == .turnPage(forward: true))
        #expect(ViewerScrollPlanner.oneScreen(forward: true, allowPageChange: false, metrics: nil, readingDirection: .leftToRight)
            == .none)
    }

    @Test("ページの入りの隅: 右開きは右上から、左開きは左上から。読み終わりの隅はその対角")
    func pageCornersFollowTheReadingDirection() {
        let wide = metrics(y: 0, maxY: 500, x: 0, maxX: 300)
        #expect(ViewerScrollPlanner.pageCorner(atEnd: false, readingDirection: .rightToLeft, metrics: wide) == CGPoint(x: 300, y: 0))
        #expect(ViewerScrollPlanner.pageCorner(atEnd: true, readingDirection: .rightToLeft, metrics: wide) == CGPoint(x: 0, y: 500))
        #expect(ViewerScrollPlanner.pageCorner(atEnd: false, readingDirection: .leftToRight, metrics: wide) == CGPoint(x: 0, y: 0))
        #expect(ViewerScrollPlanner.pageCorner(atEnd: true, readingDirection: .leftToRight, metrics: wide) == CGPoint(x: 300, y: 500))
    }
}
