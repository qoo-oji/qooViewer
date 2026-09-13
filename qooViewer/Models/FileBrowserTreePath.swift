import Foundation

/// ファイルブラウザのツリーを「現在のフォルダまで開く」ときの道筋(2026-09-14、ユーザー要望。
/// AppPreferences.fileBrowserExpandsTreeToCurrentFolder)。行を開く・待つのは FileBrowserTreeView、ここは道筋を決めるだけ。
nonisolated enum FileBrowserTreePath {
    struct Plan: Equatable {
        /// 起点にする根の、`roots` の中の位置。
        let rootIndex: Int
        /// 根の下から現在のフォルダまでの各階層のパス(根そのものは含まない。末尾が現在のフォルダ)。
        /// 空なら現在のフォルダが根そのもの。
        let steps: [String]
    }

    /// - Parameters:
    ///   - target: 現在のフォルダのパス。
    ///   - roots: ツリーの根(ボリューム・ホーム・よく使う項目)のパス。ツリーに並ぶ順。
    /// - Returns: `target` を含む根のうち**いちばん深いもの**から `target` までの道筋。深さが同じなら先に並ぶ根
    ///   (よく使う項目とホームが同じ場所なら、ホームの行を開く)。どの根にも含まれなければ nil。
    static func plan(to target: String, roots: [String]) -> Plan? {
        let target = MountTable.normalized(target)
        var best: (index: Int, depth: Int)?
        for (index, root) in roots.enumerated() {
            let root = MountTable.normalized(root)
            guard !root.isEmpty, MountTable.path(target, isAtOrUnder: root) else { continue }
            let depth = components(of: root).count
            if depth > (best?.depth ?? -1) { best = (index, depth) }
        }
        guard let best else { return nil }
        let below = components(of: target).dropFirst(best.depth)
        var path = MountTable.normalized(roots[best.index])
        let steps = below.map { component in
            path = path == "/" ? "/" + component : path + "/" + component
            return path
        }
        return Plan(rootIndex: best.index, steps: steps)
    }

    /// 同じ階層の子の中から、道筋の 1 段に当たるものを選ぶ。まずパスの完全一致、無ければ大小文字と
    /// Unicode の正規化の違いを無視して比べる(「フォルダへ移動…」で打った名前は、実際の名前と大小文字が違いうる)。
    static func index(of step: String, in childPaths: [String]) -> Int? {
        let step = MountTable.normalized(step)
        let paths = childPaths.map(MountTable.normalized)
        return paths.firstIndex(of: step)
            ?? paths.firstIndex { $0.compare(step, options: [.caseInsensitive]) == .orderedSame }
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
