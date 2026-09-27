import Foundation

/// スマートライブラリのグリッドの選択(2026-09-22、利用者の指示。StackNest / ShelfRow の調査から)。
///
/// 並びの識別子(`SmartGridItem.id`。本も束も同じ扱い)の集合と、2 つの位置を持つ:
/// - `anchor`: ⇧ で範囲を伸ばす起点(最後に単独で選んだ・⌘ で足したもの)
/// - `cursor`: 矢印キーが動かす位置(⇧ で伸ばした側の端)
///
/// 規則は Finder のアイコン表示と同じ(ファイルブラウザのアイコン表示とも揃う):
/// - クリックは 1 つだけ選ぶ、⌘ で足す/外す、⇧ で起点からの範囲(それまでの範囲は置き換える)
/// - 矢印キーの移動先は `GridKeyboardNavigation`(何も選んでいなければ先頭)。⇧ を足すと起点からの範囲
/// - Home / End / PageUp / PageDown は先頭・末尾・1 画面ぶん(StackNest と同じく選び直す。Finder はスクロールだけ)
///
/// 画面の都合(列数・1 画面の件数・スクロール)は持たない純粋な値にしてあるのは、端の扱いをテストで固定するため。
///
/// 2026-09-27 に識別子の型を引数にした(`GridSelection`)。本棚のコレクションの一覧とコレクションの中も同じ規則で選ぶ
/// (ホームの操作の統一。docs/plans/home-interaction-design.md)。スマートライブラリは文字列の識別子のまま(`SmartGridSelection`)。
nonisolated struct GridSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    typealias Click = GridSelectionClick
    typealias Jump = GridSelectionJump

    private(set) var ids: Set<ID> = []
    private(set) var anchor: ID?
    private(set) var cursor: ID?

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: ID) -> Bool { ids.contains(id) }

    /// それだけを選ぶ(起点と位置もそこへ)。
    mutating func select(_ id: ID) {
        ids = [id]
        anchor = id
        cursor = id
    }

    /// 選択をそのまま置き換える(リスト表示の `NSOutlineView` が選んだもの。起点と位置は `cursor`、無ければどれか 1 つ)。
    mutating func set(_ ids: Set<ID>, cursor: ID?) {
        self.ids = ids
        let cursor = cursor.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        self.cursor = cursor
        anchor = cursor
    }

    mutating func clear() {
        ids = []
        anchor = nil
        cursor = nil
    }

    mutating func click(_ id: ID, _ click: Click, order: [ID]) {
        switch click {
        case .plain:
            select(id)
        case .toggle:
            if ids.remove(id) != nil {
                if anchor == id { anchor = nil }
                if cursor == id { cursor = nil }
            } else {
                ids.insert(id)
                anchor = id
                cursor = id
            }
        case .extend:
            guard let anchor, ids.contains(anchor), let from = order.firstIndex(of: anchor),
                  let to = order.firstIndex(of: id)
            else {
                select(id)
                return
            }
            ids = Set(order[min(from, to)...max(from, to)])
            cursor = id
        }
    }

    /// 矢印キー。動いた先(見える位置へスクロールさせる相手)を返す。並びが空なら nil。
    @discardableResult
    mutating func move(
        _ direction: GridKeyboardNavigation.Direction, extending: Bool, order: [ID], columns: Int
    ) -> ID? {
        guard let target = GridKeyboardNavigation.target(
            from: currentIndex(in: order), count: order.count, columns: columns, direction: direction
        ) else { return nil }
        return moveCursor(to: target, extending: extending, order: order)
    }

    /// Home / End / PageUp / PageDown。動いた先を返す。並びが空なら nil。
    @discardableResult
    mutating func jump(_ jump: Jump, extending: Bool, order: [ID]) -> ID? {
        guard !order.isEmpty else { return nil }
        let current = currentIndex(in: order)
        let target: Int
        switch jump {
        case .first:
            target = 0
        case .last:
            target = order.count - 1
        case .pageUp(let step):
            target = max(0, (current ?? 0) - max(1, step))
        case .pageDown(let step):
            // 何も選んでいなければ先頭から(矢印キーと同じ)。
            target = current.map { min(order.count - 1, $0 + max(1, step)) } ?? 0
        }
        return moveCursor(to: target, extending: extending, order: order)
    }

    mutating func selectAll(order: [ID]) {
        ids = Set(order)
        if anchor.map({ !ids.contains($0) }) ?? true { anchor = order.first }
        if cursor.map({ !ids.contains($0) }) ?? true { cursor = anchor }
    }

    /// 並びが変わった(絞り込み・束の出入り・集め直し)。並びから消えたものを外す。
    mutating func prune(to order: [ID]) {
        guard !ids.isEmpty || anchor != nil || cursor != nil else { return }
        let present = Set(order)
        ids.formIntersection(present)
        if let anchor, !present.contains(anchor) { self.anchor = nil }
        if let cursor, !present.contains(cursor) { self.cursor = nil }
    }

    /// 矢印キーの起点: 位置が選ばれたまま並びにあればそこ、無ければ並びで最初に選ばれているもの。
    private func currentIndex(in order: [ID]) -> Int? {
        if let cursor, ids.contains(cursor), let index = order.firstIndex(of: cursor) { return index }
        return order.firstIndex(where: ids.contains)
    }

    private mutating func moveCursor(to index: Int, extending: Bool, order: [ID]) -> ID {
        let id = order[index]
        if extending, let anchor, ids.contains(anchor), let from = order.firstIndex(of: anchor) {
            ids = Set(order[min(from, index)...max(from, index)])
            cursor = id
        } else {
            select(id)
        }
        return id
    }
}

/// スマートライブラリのグリッドの選択(識別子は `SmartGridItem.id`)。
typealias SmartGridSelection = GridSelection<String>

/// クリックの種類(`GridSelection.click`)。
nonisolated enum GridSelectionClick: Sendable {
    /// ふつうのクリック: それだけを選ぶ。
    case plain
    /// ⌘: 足す / 外す。
    case toggle
    /// ⇧: 起点からの範囲。
    case extend
}

/// Home / End / PageUp / PageDown(`GridSelection.jump`)。
nonisolated enum GridSelectionJump: Sendable {
    case first, last
    /// 1 画面ぶん(件数)上 / 下へ。
    case pageUp(Int), pageDown(Int)
}
