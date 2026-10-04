import Foundation
import Testing

@testable import qooViewer

/// ブックマーク・レイアウトの編集ウインドウの「開く」が待つ仕事(`PendingBookOpens`。2026-10-04 のレビューの R7-3・RC-3)。
///
/// 待ちは手で開ける門(`Gate`)で書く ―― 本の場所の解決(StoredBookLocator)と同じく、待った後で `Task.isCancelled` を見て
/// 降りる形。時間では待たない。
@MainActor
struct PendingBookOpensTests {
    /// 開けるまで待たせる門。開いた後に来た待ちはすぐ通す。
    @MainActor
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    /// 開いた「開く」の名前(待った後で取り消されていなければ足す ―― 実物の「開く」と同じ降り方)。
    @MainActor
    private final class Opened {
        var names: Set<String> = []
    }

    private func body(_ name: String, gate: Gate, opened: Opened) -> @MainActor () async -> Void {
        {
            await gate.wait()
            guard !Task.isCancelled else { return }
            opened.names.insert(name)
        }
    }

    /// RC-3 の退行: 段 C の直しは置き換える「開く」と新しいタブ・ウインドウへの「開く」を 1 つの箱で持ち、続けて 2 冊を新しいタブで
    /// 開くと先の 1 冊が黙って開かれなかった(直す前は両方開いた)。
    @Test("新しいタブ・ウインドウへの「開く」を続けて頼むと両方開き、置き換える「開く」にも取り消されない")
    func opensIntoNewWindowsAreNotCancelledByLaterOpens() async {
        let pending = PendingBookOpens()
        let gate = Gate()
        let opened = Opened()

        let first = pending.startInNewWindow(body("first tab", gate: gate, opened: opened))
        let second = pending.startInNewWindow(body("second tab", gate: gate, opened: opened))
        let replacing = pending.startReplacing(body("replace", gate: gate, opened: opened))
        #expect(pending.pendingNewWindowCount == 2)
        gate.open()
        await first.value
        await second.value
        await replacing.value
        #expect(opened.names == ["first tab", "second tab", "replace"])
        // 終わった分は持ち続けない。
        #expect(pending.pendingNewWindowCount == 0)
    }

    @Test("手前の窓の本を置き換える「開く」は、後から頼んだ方だけが開く。新しいタブ・ウインドウへの分は取り消さない")
    func aLaterReplacingOpenCancelsTheEarlierOne() async {
        let pending = PendingBookOpens()
        let gate = Gate()
        let opened = Opened()

        let tab = pending.startInNewWindow(body("tab", gate: gate, opened: opened))
        let earlier = pending.startReplacing(body("earlier", gate: gate, opened: opened))
        let later = pending.startReplacing(body("later", gate: gate, opened: opened))
        gate.open()
        await tab.value
        await earlier.value
        await later.value
        #expect(opened.names == ["tab", "later"])
    }

    @Test("編集ウインドウを閉じたら、待っている「開く」はどれも開かない")
    func closingTheWindowCancelsEveryPendingOpen() async {
        let pending = PendingBookOpens()
        let gate = Gate()
        let opened = Opened()

        let tab = pending.startInNewWindow(body("tab", gate: gate, opened: opened))
        let replacing = pending.startReplacing(body("replace", gate: gate, opened: opened))
        pending.cancelAll()
        #expect(pending.pendingNewWindowCount == 0)
        gate.open()
        await tab.value
        await replacing.value
        #expect(opened.names.isEmpty)
    }
}
