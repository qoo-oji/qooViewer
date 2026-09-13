import Foundation

/// グリッド(ファイルブラウザのアイコン表示)の矢印キーで、次にどのセルへ移るか
/// (改善要望7 段階3、2026-09-13)。
///
/// 純粋な関数にしてあるのは、列数と端の扱いをテストで固定するため(LazyVGridは矢印キーの移動を
/// 持たないので、Finderと同じ動きを自前で書くことになる)。
///
/// Finderのアイコン表示と同じ規則:
/// - 何も選んでいなければ、どの矢印でも先頭(↑←は先頭、↓→も先頭)
/// - ←→は行をまたいで前後の項目へ進む(行末の→は次の行の先頭)。両端では動かない
/// - ↑↓は同じ列の上下へ。上の行が無ければ動かない。下の行にその列が無い(最終行が短い)ときは
///   最後の項目へ ―― ただし既に最終行にいるなら動かない
nonisolated enum GridKeyboardNavigation {
    enum Direction: Sendable {
        case up, down, left, right
    }

    /// - Parameters:
    ///   - current: いまの位置(選択の起点)。nil は未選択。
    ///   - count: 項目の数。
    ///   - columns: 1行の列数(1以上。レイアウトと同じ式で求めた値を渡す)。
    /// - Returns: 移動先。項目が無ければ nil。
    static func target(from current: Int?, count: Int, columns: Int, direction: Direction) -> Int? {
        guard count > 0 else { return nil }
        let columns = max(1, columns)
        guard let current, (0..<count).contains(current) else { return 0 }
        switch direction {
        case .left:
            return max(0, current - 1)
        case .right:
            return min(count - 1, current + 1)
        case .up:
            let above = current - columns
            return above >= 0 ? above : current
        case .down:
            let below = current + columns
            if below < count { return below }
            // 下の行はあるが、その列まで届いていない(最終行が短い)。
            let currentRow = current / columns
            let lastRow = (count - 1) / columns
            return currentRow < lastRow ? count - 1 : current
        }
    }
}
