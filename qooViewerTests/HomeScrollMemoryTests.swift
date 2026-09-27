import CoreGraphics
import Testing

@testable import qooViewer

/// ホームの一覧のスクロール位置の控えと、SwiftUI の一覧へ戻す段取り(`HomeScrollMemory` / `HomeScrollRestorer`)。
@MainActor
struct HomeScrollMemoryTests {
    private func metrics(offset: CGFloat = 0, content: CGFloat, visible: CGFloat = 400) -> HomeScrollRestorer.Metrics {
        HomeScrollRestorer.Metrics(offsetY: offset, contentHeight: content, visibleHeight: visible)
    }

    @Test("控えは一度取り出したら無くなる")
    func takeRemovesTheEntry() {
        let memory = HomeScrollMemory()
        memory.save(CGPoint(x: 0, y: 120), for: "a")
        #expect(memory.take(for: "a") == CGPoint(x: 0, y: 120))
        #expect(memory.take(for: "a") == nil)
    }

    @Test("戻す途中は、中身がその位置まで届く高さになるまで動かさず、控えも書き換えない")
    func waitsUntilTheContentReachesThePosition() {
        let memory = HomeScrollMemory()
        let restorer = HomeScrollRestorer()
        restorer.begin(300) { _ in }
        // 作り直した直後: 中身がまだ低い(いちばん下でも 100)。
        #expect(restorer.observe(metrics(content: 500), key: "k", memory: memory) == nil)
        #expect(memory.take(for: "k") == nil)
        #expect(restorer.isRestoring)
        // 中身が並んだ: 300 まで届く。
        #expect(restorer.observe(metrics(content: 1000), key: "k", memory: memory) == 300)
        #expect(!restorer.isRestoring)
    }

    @Test("戻し終えたら、スクロールのたびに控えを書き換える")
    func savesAfterRestoring() {
        let memory = HomeScrollMemory()
        let restorer = HomeScrollRestorer()
        restorer.begin(nil) { _ in }
        #expect(restorer.observe(metrics(offset: 250, content: 1000), key: "k", memory: memory) == nil)
        #expect(memory.take(for: "k") == CGPoint(x: 0, y: 250))
    }

    @Test("戻し始める前に届いた実測(作り直した直後の位置 0)では控えを書き換えない")
    func ignoresGeometryBeforeBegin() {
        let memory = HomeScrollMemory()
        memory.save(CGPoint(x: 0, y: 640), for: "k")
        let restorer = HomeScrollRestorer()
        #expect(restorer.observe(metrics(offset: 0, content: 2000), key: "k", memory: memory) == nil)
        #expect(memory.take(for: "k") == CGPoint(x: 0, y: 640))
    }

    @Test("中身の高さが 0 の実測(作り直しの途中・捨てる途中)では控えを書き換えない")
    func ignoresEmptyGeometry() {
        let memory = HomeScrollMemory()
        memory.save(CGPoint(x: 0, y: 80), for: "k")
        let restorer = HomeScrollRestorer()
        restorer.begin(nil) { _ in }
        #expect(restorer.observe(metrics(offset: 0, content: 0), key: "k", memory: memory) == nil)
        #expect(memory.take(for: "k") == CGPoint(x: 0, y: 80))
    }
}
