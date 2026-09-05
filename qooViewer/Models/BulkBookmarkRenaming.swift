import Foundation

/// **ブックマークの一括リネームの命名規則**。「表紙」「最後のブックマーク」「連番」の
/// 決め方だけを取り出した型。
///
/// `BulkRenameBookmarksSheet` の中で、プレビュー(`previewNames`)と実行(`applyRenaming`)に
/// **同じ規則が二重に書かれていた** ―― プレビューと結果がずれるのは、この形が生む典型的な
/// 不具合なので、規則をここ 1 つにまとめて両方から呼ぶ。
nonisolated enum BulkBookmarkRenaming {
    /// 並べ替えの対象になるブックマーク 1 件ぶん。**ページ順に渡すこと**。
    struct Target: Equatable {
        let id: UUID
        let pageIndex: Int
        let currentName: String

        init(id: UUID, pageIndex: Int, currentName: String) {
            self.id = id
            self.pageIndex = pageIndex
            self.currentName = currentName
        }
    }

    /// 画面で選んだ設定。表示言語で解決済みの文字列を受け取る(翻訳の解決は画面側の仕事)。
    struct Options {
        /// 先頭ページのブックマークに固定の名前(「表紙」)を割り当てるか。
        var assignsFixedCover: Bool
        /// 表紙に付ける名前(解決済み)。
        var coverName: String
        /// 最後のブックマークに付ける固定の名前(解決済み)。nil なら連番の対象に含める。
        var lastBookmarkFixedName: String?
        var startNumber: Int
        var prefix: String
        var suffix: String

        init(
            assignsFixedCover: Bool = false, coverName: String = "",
            lastBookmarkFixedName: String? = nil, startNumber: Int = 1,
            prefix: String = "", suffix: String = ""
        ) {
            self.assignsFixedCover = assignsFixedCover
            self.coverName = coverName
            self.lastBookmarkFixedName = lastBookmarkFixedName
            self.startNumber = startNumber
            self.prefix = prefix
            self.suffix = suffix
        }
    }

    /// 「旧名 → 新名」1 件ぶん。
    struct Rename: Equatable {
        let id: UUID
        let currentName: String
        let newName: String
    }

    /// 名前を決める。順序は **表紙 → 最後の固定名 → 残りに連番**。
    ///
    /// 表紙に選ばれるのは「ページ番号 0 のブックマーク」で、それが最後のブックマークでもある
    /// (= 1 件しかない)場合は表紙が優先される。戻り値は**ページ順**に並べ直したもの ――
    /// プレビュー欄の並びがそのまま結果になる。
    static func renames(for targets: [Target], options: Options) -> [Rename] {
        var assignedIDs: Set<UUID> = []
        var result: [Rename] = []

        if options.assignsFixedCover, let cover = targets.first(where: { $0.pageIndex == 0 }) {
            result.append(
                Rename(id: cover.id, currentName: cover.currentName, newName: options.coverName)
            )
            assignedIDs.insert(cover.id)
        }

        if let fixedName = options.lastBookmarkFixedName, let last = targets.last,
           !assignedIDs.contains(last.id) {
            result.append(Rename(id: last.id, currentName: last.currentName, newName: fixedName))
            assignedIDs.insert(last.id)
        }

        var number = options.startNumber
        for target in targets where !assignedIDs.contains(target.id) {
            result.append(
                Rename(
                    id: target.id, currentName: target.currentName,
                    newName: "\(options.prefix)\(number)\(options.suffix)"
                )
            )
            number += 1
        }

        // 並べ替えのたびに targets を線形探索すると要素数の二乗になる(テキストフィールドを
        // 1 文字打つたびに再計算される)。辞書を 1 回だけ作って O(1) で引く。
        let pageIndexByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.pageIndex) })
        return result.sorted { (pageIndexByID[$0.id] ?? 0) < (pageIndexByID[$1.id] ?? 0) }
    }
}
