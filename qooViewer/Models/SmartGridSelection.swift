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
nonisolated struct SmartGridSelection: Equatable, Sendable {
    enum Click: Sendable {
        /// ふつうのクリック: それだけを選ぶ。
        case plain
        /// ⌘: 足す / 外す。
        case toggle
        /// ⇧: 起点からの範囲。
        case extend
    }

    enum Jump: Sendable {
        case first, last
        /// 1 画面ぶん(件数)上 / 下へ。
        case pageUp(Int), pageDown(Int)
    }

    private(set) var ids: Set<String> = []
    private(set) var anchor: String?
    private(set) var cursor: String?

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// それだけを選ぶ(起点と位置もそこへ)。
    mutating func select(_ id: String) {
        ids = [id]
        anchor = id
        cursor = id
    }

    /// 選択をそのまま置き換える(リスト表示の `NSOutlineView` が選んだもの。起点と位置は `cursor`、無ければどれか 1 つ)。
    mutating func set(_ ids: Set<String>, cursor: String?) {
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

    mutating func click(_ id: String, _ click: Click, order: [String]) {
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
        _ direction: GridKeyboardNavigation.Direction, extending: Bool, order: [String], columns: Int
    ) -> String? {
        guard let target = GridKeyboardNavigation.target(
            from: currentIndex(in: order), count: order.count, columns: columns, direction: direction
        ) else { return nil }
        return moveCursor(to: target, extending: extending, order: order)
    }

    /// Home / End / PageUp / PageDown。動いた先を返す。並びが空なら nil。
    @discardableResult
    mutating func jump(_ jump: Jump, extending: Bool, order: [String]) -> String? {
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

    mutating func selectAll(order: [String]) {
        ids = Set(order)
        if anchor.map({ !ids.contains($0) }) ?? true { anchor = order.first }
        if cursor.map({ !ids.contains($0) }) ?? true { cursor = anchor }
    }

    /// 並びが変わった(絞り込み・束の出入り・集め直し)。並びから消えたものを外す。
    mutating func prune(to order: [String]) {
        guard !ids.isEmpty || anchor != nil || cursor != nil else { return }
        let present = Set(order)
        ids.formIntersection(present)
        if let anchor, !present.contains(anchor) { self.anchor = nil }
        if let cursor, !present.contains(cursor) { self.cursor = nil }
    }

    /// 矢印キーの起点: 位置が選ばれたまま並びにあればそこ、無ければ並びで最初に選ばれているもの。
    private func currentIndex(in order: [String]) -> Int? {
        if let cursor, ids.contains(cursor), let index = order.firstIndex(of: cursor) { return index }
        return order.firstIndex(where: ids.contains)
    }

    private mutating func moveCursor(to index: Int, extending: Bool, order: [String]) -> String {
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
