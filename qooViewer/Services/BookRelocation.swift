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
