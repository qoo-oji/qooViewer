import Foundation

/// スマートライブラリの対象フォルダの中の本を探す
/// (2026-09-21)。**ブロッキングするので必ず `FileIO.perform` の上から呼ぶ**(FileIO の型コメント)。
///
/// 何を 1 冊と数えるかは qooViewer が開けるものと同じ: 書庫(zip・cbz・rar・cbr・7z・cb7)・PDF・EPUB と、
/// **直下に画像を持つフォルダ**(画像フォルダの本。その中のフォルダは同じ本の一部なので数えない)。読むのは名前と属性だけで、
/// 書庫の中は開かない。
///
/// ■ 入らない所
/// - 隠しファイル・パッケージの中(Finder と同じ)
/// - TCC の保護下の場所(`DirectoryProbe.protectedPrefixes`)。**起点がその中にあるときだけは入る**(利用者が選んだ場所)。
///   対象フォルダにホームフォルダを入れていても、デスクトップ・書類などを読みに行って確認のダイアログを次々に出さない
///   (docs/15「サンドボックスと TCC の約束」)
/// - 深さ `maxDepth` より下、見た項目の数が `maxEntries` を超えた先(ボリュームのルートを登録しても止まるように)
nonisolated enum SmartLibraryScanner {
    struct ScannedBook: Hashable, Sendable {
        let path: String
        let isFolder: Bool
        let creationDate: Date?
        let modificationDate: Date?
        let fileSize: Int64?
        /// そのフォルダへ入った日(Finder の「追加日」)。取れないボリュームでは nil。
        var addedDate: Date? = nil
    }

    struct Result: Sendable {
        var books: [ScannedBook] = []
        /// 上限で打ち切ったか(画面に「一部だけ」と出す)。
        var isTruncated = false
    }

    static let maxDepth = 12
    static let maxEntries = 400_000

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey,
        .addedToDirectoryDateKey,
    ]

    /// 起点のフォルダ(重なっていてよい。同じ本は 1 度だけ返す)を探す。
    static func scan(roots: [String], protectedPrefixes: [String] = DirectoryProbe.protectedPrefixes) -> Result {
        var result = Result()
        var seen = Set<String>()
        var visited = 0
        // 起点どうしが入れ子なら、外側だけを歩く。
        let normalizedRoots = Array(Set(roots.map(MountTable.normalized))).sorted()
        let outermost = normalizedRoots.filter { root in
            !normalizedRoots.contains { $0 != root && MountTable.path(root, isAtOrUnder: $0) }
        }
        for root in outermost {
            if Cancellation.isRequestedInCurrentScope { break }
            // 起点がすでに保護下なら、その中は許す(利用者が選んだ)。
            let skips = protectedPrefixes.filter { !MountTable.path(root, isAtOrUnder: $0) }
            scan(root: root, skipping: skips, visited: &visited, seen: &seen, into: &result)
            if result.isTruncated { break }
        }
        return result
    }

    private static func scan(root: String, skipping protectedPrefixes: [String], visited: inout Int,
                             seen: inout Set<String>, into result: inout Result) {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return }
        /// フォルダ → そのフォルダの属性(直下に画像があれば本になる)。
        var folderFacts: [String: ScannedBook] = [:]
        var imageFolders = Set<String>()
        var files: [ScannedBook] = []
        for case let url as URL in enumerator {
            if Cancellation.isRequestedInCurrentScope { return }
            visited += 1
            if visited > maxEntries {
                result.isTruncated = true
                break
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let path = MountTable.normalized(url.path)
            if values?.isDirectory == true, values?.isPackage != true {
                if enumerator.level > maxDepth || protectedPrefixes.contains(where: { MountTable.path(path, isAtOrUnder: $0) }) {
                    enumerator.skipDescendants()
                    continue
                }
                folderFacts[path] = ScannedBook(path: path, isFolder: true, creationDate: values?.creationDate,
                                                modificationDate: values?.contentModificationDate, fileSize: nil,
                                                addedDate: values?.addedToDirectoryDate)
                continue
            }
            guard values?.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent
            if isImageFile(name) {
                imageFolders.insert((path as NSString).deletingLastPathComponent)
            } else if isArchiveFile(name) || isPDFFile(name) || isEpubFile(name) {
                files.append(ScannedBook(path: path, isFolder: false, creationDate: values?.creationDate,
                                         modificationDate: values?.contentModificationDate,
                                         fileSize: values?.fileSize.map(Int64.init),
                                         addedDate: values?.addedToDirectoryDate))
            }
        }
        // 画像フォルダの本。その中のフォルダ(章ごとのフォルダなど)は同じ本の一部なので外す。起点そのものは本にしない
        // (登録したフォルダ = 本棚。フォルダ 1 つを 1 冊として登録したいなら、その親を登録する)。
        let sortedImageFolders = imageFolders.filter { $0 != MountTable.normalized(root) }.sorted()
        var bookFolders: [String] = []
        for folder in sortedImageFolders where !bookFolders.contains(where: { MountTable.path(folder, isAtOrUnder: $0) }) {
            bookFolders.append(folder)
        }
        for folder in bookFolders where seen.insert(folder).inserted {
            result.books.append(folderFacts[folder] ?? ScannedBook(path: folder, isFolder: true, creationDate: nil,
                                                                  modificationDate: nil, fileSize: nil))
        }
        for file in files where seen.insert(file.path).inserted {
            // 画像フォルダの本の中にある書庫も、1 冊として数える(フォルダの本は画像だけを読むので、重ならない)。
            result.books.append(file)
        }
    }
}
