import Testing

@testable import qooViewer

/// 「ウインドウ」メニューの一覧をタブのグループごとにまとめる並べ方(`WindowsMenuGrouper.groupedOrder`)。
/// 元の並びは AppKit の字順、グループはタブのグループ、グループの中の順位はタブの並び順にあたる。
struct WindowsMenuGroupingTests {
    private struct Row: Equatable {
        let name: String
        let group: Int
        let tab: Int
    }

    private func order(_ rows: [Row]) -> [String] {
        WindowsMenuGrouper.groupedOrder(rows, groupKey: \.group, rankInGroup: \.tab).map(\.name)
    }

    @Test("同じグループのタブは、グループの中でいちばん前の項目の位置へタブの順に寄る")
    func tabsOfOneGroupGatherAtItsFirstItem() {
        let rows = [
            Row(name: "apple", group: 2, tab: 0),
            Row(name: "Banana", group: 1, tab: 2),
            Row(name: "Kiwi", group: 3, tab: 0),
            Row(name: "Mango", group: 1, tab: 0),
            Row(name: "Zeta", group: 1, tab: 1),
        ]
        #expect(order(rows) == ["apple", "Mango", "Zeta", "Banana", "Kiwi"])
    }

    @Test("タブの無いウインドウだけなら並びは変わらない")
    func singleWindowsKeepTheirOrder() {
        let rows = (0..<4).map { Row(name: "w\($0)", group: $0, tab: 0) }
        #expect(order(rows) == ["w0", "w1", "w2", "w3"])
    }

    @Test("既にまとまっていれば並びは変わらない(寄せ直しで項目を差し替えない)")
    func alreadyGroupedIsUnchanged() {
        let rows = [
            Row(name: "a", group: 1, tab: 0),
            Row(name: "b", group: 1, tab: 1),
            Row(name: "c", group: 2, tab: 0),
        ]
        #expect(order(rows) == ["a", "b", "c"])
    }
}
