import Foundation

/// **アプリ自身が**移した・名前を変えた本の保存データを、新しいパスへ付け替える段取り(2026-09-19 の監査の H1。
/// docs/plans/fs-ui-consistency-audit.md)。
///
/// ■ なぜ要るか
/// 保存データ(ブックマーク・レイアウト・メタデータ・棚の本・お気に入り)は `bookID`(パス)で引き、外れたときは本を開いた時点で
/// `FileNodeIdentifier`(inode + ボリューム)から追従する(各ストアの `reconcileBookIDIfMoved`)。それは「移すのはアプリの外」
/// だった頃の作りで、**別ボリュームへの移動は inode が変わるので追えない**(docs/06「移動・リネームへの追従」)。いまは
/// ファイルブラウザ自身が移すので、新旧のパスが分かっている(`FileSystemChange.relocations`)。それを使えば別ボリュームでも、
/// 本を開くのを待たずに、フォルダごと移した中の本もまとめて付け替えられる。
///
/// ■ 決まり
/// - 付け替えるのは `bookID` が移った項目自身か、その配下にある行。
/// - **移った先のパスにすでに行があるストアでは付け替えない**(`reconcileBookIDIfMoved` と同じ。置き換えで上書きした本の行を黙って
///   混ぜない)。
/// - 別ボリュームへ移した本は inode もブックマークも変わるので、新しい場所で取り直す(`locators`)。同じボリュームの中なら
///   どちらもそのまま使える(ブックマークは移動に付いていく)。
/// - 取り消しで戻したときも、同じ仕組みで元のパスへ戻る(取り消しも `FileOperationService` を通る)。
nonisolated struct BookRelocationPlan: Sendable {
    /// 別ボリュームへ移した本の、新しい場所の手がかり。
    struct Locator: Sendable {
        let identifier: FileNodeIdentifier?
        let bookmarkData: Data?
    }

    /// 古い `bookID` → 新しい `bookID`。
    let bookIDs: [String: String]
    /// 新しい `bookID` → 取り直した手がかり(別ボリュームへ移したものだけ)。
    let locators: [String: Locator]
    /// 新しい `bookID` のうちフォルダの本(棚のキャプションの付け替えに使う。`derivedTitle`)。
    let directoryBookIDs: Set<String>

    var isEmpty: Bool { bookIDs.isEmpty }

    /// `knownBookIDs`(どれかのストアに行のある本)のうち、`change` で移ったものの付け替えを組む。
    /// 手がかりの取り直しはファイルに触るので、**メインアクターの外で呼ぶ**。
    static func make(knownBookIDs: Set<String>, change: FileSystemChange, mounts: MountTable = .current()) -> BookRelocationPlan {
        var bookIDs: [String: String] = [:]
        var locators: [String: Locator] = [:]
        var directories: Set<String> = []
        for old in knownBookIDs {
            guard let new = change.relocatedPath(for: old), new != old else { continue }
            bookIDs[old] = new
            let oldURL = URL(fileURLWithPath: old), newURL = URL(fileURLWithPath: new)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: new, isDirectory: &isDirectory), isDirectory.boolValue { directories.insert(new) }
            guard !mounts.areOnSameVolume(oldURL, newURL) else { continue }
            locators[new] = Locator(
                identifier: FileNodeIdentifier.current(for: newURL),
                bookmarkData: try? newURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            )
        }
        return BookRelocationPlan(bookIDs: bookIDs, locators: locators, directoryBookIDs: directories)
    }

    /// 本のファイル名から決まる題(`BookLoader` が `MangaBook.title` に入れるのと同じ: フォルダは名前そのまま、ファイルは拡張子を除く)。
    static func derivedTitle(forBookID bookID: String, isDirectory: Bool) -> String {
        let url = URL(fileURLWithPath: bookID)
        return isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}

/// **フォルダの本のページの鍵は絶対パス**(`PageRef.sortKey`。BookLoader.collectPages ―― 中の書庫・PDF のページも、その書庫の絶対パスが頭に付く)。
/// 本が移る・名前が変わると `bookID` だけでなく鍵の頭も変わるので、鍵で持っている保存データ(`PageLayoutOverride.pageKey`・
/// `BookLayoutSettings.coverPageKey` / `shelfCoverPageKey`・`Bookmark.pageKey`・`BookReadingState.lastPageKey`)も一緒に付け替える。
///
/// 2026-09-21 まで付け替えていたのは `bookID` だけで、フォルダの本を移すと、ページ単位のレイアウト・「本の中のページ」で選んだ表紙が
/// 黙って外れ、ブックマークは番号へ落ちた(鍵が合わないので、並びが変わると別のページを指す)。feature-toggle-audit.md §7 で見つけた件。
/// 書庫・PDF・EPUB の本の鍵は本の中で閉じている(`/` で始まらない)ので、ここでは何も変わらない。
nonisolated enum PageKeyRelocation {
    /// `old` の本の鍵を `new` の本の鍵にする。付け替えが要らない鍵(本の中で閉じた鍵・その本の配下でない鍵)は nil。
    static func relocated(_ pageKey: String, fromBookID old: String, toBookID new: String) -> String? {
        guard old != new, old.hasPrefix("/"), pageKey.hasPrefix(old + "/") else { return nil }
        return new + pageKey.dropFirst(old.count)
    }

    /// 付け替え漏れの鍵(2026-09-21 より前に移した本の行)を、いまの本のページから求め直す。
    ///
    /// 漏れた鍵は「昔の本のパス + 本の中の相対パス」。昔のパスは分からないので、**いまの本のページの相対パスで終わる鍵**を探し、
    /// 残りを昔のパスの候補とする。漏れた鍵の全部(対応するページがもう無い鍵は除く)に共通する候補が**ちょうど 1 つ**のときだけ直す ――
    /// 2 つ以上あり得るとき(昔のフォルダ名と同じ名前のサブフォルダに、同じ名前の画像があるような場合)は、推測せず何もしない。
    /// - Parameters:
    ///   - keys: その本の行が持っている鍵。
    ///   - currentPageKeys: いま開いた本のページの鍵(`PageRef.sortKey`)。
    /// - Returns: 直す鍵 → 新しい鍵。
    static func repairs(forStaleKeys keys: [String], bookID: String, currentPageKeys: [String]) -> [String: String] {
        guard bookID.hasPrefix("/") else { return [:] }
        let prefix = bookID + "/"
        let current = Set(currentPageKeys)
        let relatives = Set(currentPageKeys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(bookID.count)) })
        guard !relatives.isEmpty else { return [:] }
        let stale = Set(keys.filter { $0.hasPrefix("/") && !$0.hasPrefix(prefix) && !current.contains($0) })
        guard !stale.isEmpty else { return [:] }
        var rootsByKey: [String: Set<String>] = [:]
        for key in stale {
            let roots = Set(relatives.filter { key.hasSuffix($0) && key.count > $0.count }.map { String(key.dropLast($0.count)) })
            if !roots.isEmpty { rootsByKey[key] = roots }
        }
        guard var common = rootsByKey.values.first else { return [:] }
        for roots in rootsByKey.values { common.formIntersection(roots) }
        guard common.count == 1, let root = common.first else { return [:] }
        var result: [String: String] = [:]
        for key in rootsByKey.keys { result[key] = bookID + key.dropFirst(root.count) }
        return result
    }
}
