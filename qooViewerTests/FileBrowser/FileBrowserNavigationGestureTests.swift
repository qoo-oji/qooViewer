import AppKit
import Testing

@testable import qooViewer

/// トラックパッドの左右フリック・マウスのサイドボタンから「戻る」「進む」を引く決まり
/// (Views/FileBrowser/FileBrowserNavigationGesture.swift)の、画面に依らない部分。
struct FileBrowserNavigationGestureTests {
    private typealias Room = (towardLeft: Bool, towardRight: Bool)
    private static let noRoom: Room = (false, false)

    /// 1 回のフリック(began → changed… → ended)を流して、最後に返った操作を得る。
    private func flick(
        _ deltas: [(x: CGFloat, y: CGFloat)], room: Room = noRoom, tracker: inout FileBrowserSwipeTracker
    ) -> FileBrowserEditCommand? {
        var result: FileBrowserEditCommand?
        for (index, delta) in deltas.enumerated() {
            let phase: NSEvent.Phase = index == 0 ? .began : .changed
            result = tracker.feed(phase: phase, deltaX: delta.x, deltaY: delta.y, horizontalRoom: { room })
            #expect(result == nil)
        }
        return tracker.feed(phase: .ended, deltaX: 0, deltaY: 0, horizontalRoom: { room })
    }

    @Test("マウスのサイドボタン: 3 は戻る、4 は進む、ほかは何もしない")
    func mouseButtons() {
        #expect(FileBrowserNavigationGesture.command(forMouseButton: 3) == .goBack)
        #expect(FileBrowserNavigationGesture.command(forMouseButton: 4) == .goForward)
        #expect(FileBrowserNavigationGesture.command(forMouseButton: 2) == nil)
        #expect(FileBrowserNavigationGesture.command(forMouseButton: 5) == nil)
    }

    @Test("3本指のスワイプ: deltaX が正なら戻る、負なら進む")
    func swipeEvent() {
        #expect(FileBrowserNavigationGesture.command(forSwipeDeltaX: 1) == .goBack)
        #expect(FileBrowserNavigationGesture.command(forSwipeDeltaX: -1) == .goForward)
        #expect(FileBrowserNavigationGesture.command(forSwipeDeltaX: 0) == nil)
    }

    @Test("2本指の左右フリック: 指が離れたときに 1 回だけ、向きで戻る・進むを返す")
    func horizontalFlick() {
        var tracker = FileBrowserSwipeTracker()
        #expect(flick([(30, 1), (40, -2), (20, 0)], tracker: &tracker) == .goBack)
        #expect(flick([(-30, 1), (-40, -2)], tracker: &tracker) == .goForward)
    }

    @Test("縦スクロール・斜めのぶれ・触れただけでは移動しない")
    func ignoresNonFlicks() {
        var tracker = FileBrowserSwipeTracker()
        #expect(flick([(2, 60), (3, 80)], tracker: &tracker) == nil)
        // 横が縦の 2 倍に届かない。
        #expect(flick([(60, 40)], tracker: &tracker) == nil)
        #expect(flick([(5, 0), (5, 0)], tracker: &tracker) == nil)
    }

    @Test("横にスクロールできる一覧の上では、その向きの端にいるときだけ移動する")
    func respectsHorizontalScrolling() {
        var tracker = FileBrowserSwipeTracker()
        #expect(flick([(90, 0)], room: (towardLeft: true, towardRight: false), tracker: &tracker) == nil)
        #expect(flick([(-90, 0)], room: (towardLeft: true, towardRight: false), tracker: &tracker) == .goForward)
        #expect(flick([(-90, 0)], room: (towardLeft: false, towardRight: true), tracker: &tracker) == nil)
        #expect(flick([(90, 0)], room: (towardLeft: false, towardRight: true), tracker: &tracker) == .goBack)
    }

    @Test("began を見ていない並び・慣性・取り消されたフリックは数えない")
    func ignoresStraySequences() {
        var tracker = FileBrowserSwipeTracker()
        let room = { Self.noRoom }
        // ほかのウインドウの上で始まった(began が届いていない)。
        #expect(tracker.feed(phase: .changed, deltaX: 90, deltaY: 0, horizontalRoom: room) == nil)
        #expect(tracker.feed(phase: .ended, deltaX: 0, deltaY: 0, horizontalRoom: room) == nil)
        // 慣性(phase が空)は積算に入らない。
        #expect(tracker.feed(phase: .began, deltaX: 5, deltaY: 0, horizontalRoom: room) == nil)
        #expect(tracker.feed(phase: [], deltaX: 500, deltaY: 0, horizontalRoom: room) == nil)
        #expect(tracker.feed(phase: .ended, deltaX: 0, deltaY: 0, horizontalRoom: room) == nil)
        // 取り消し。
        #expect(tracker.feed(phase: .began, deltaX: 90, deltaY: 0, horizontalRoom: room) == nil)
        #expect(tracker.feed(phase: .cancelled, deltaX: 0, deltaY: 0, horizontalRoom: room) == nil)
        #expect(tracker.feed(phase: .ended, deltaX: 0, deltaY: 0, horizontalRoom: room) == nil)
    }
}
