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
        /// 表紙のディスクキャッシュの鍵(FileBrowserThumbnailKey。探したときの lstat から)。保存した一覧と一緒に持ち、
        /// 表紙を引くときに項目を読みに行かないために使う(SmartLibraryCatalog の型コメント「速さ」)。
        var thumbnailKey: FileBrowserThumbnailKey? = nil
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

    /// 列挙が返したパスを、起点の綴りへ戻す閉包。
    ///
    /// **macOS 27 の `FileManager.enumerator` は、起点の途中にあるシンボリックリンクを解決したパスを返す**(2026-09-23 に実測。
    /// `/var/folders/…` を起点にすると `/private/var/folders/…` が返る)。そのままでは起点との「配下か」の比べ方がすべて外れ、章ごとの
    /// フォルダの本が章ごとの別の本になった(CI のサンドボックス無しのテストホストで落ちて分かった。手元はコンテナの `tmp/` で素通り)。
    /// 本の id は利用者が登録した綴りのほうに揃える(保存データ・ほかの画面のパスと一致させる)。起点が解決できなければ何もしない。
    static func pathRespeller(root: String) -> (String) -> String {
        let spelled = MountTable.normalized(root)
        guard let resolved = realpath(spelled, nil) else { return { $0 } }
        let enumerated = MountTable.normalized(String(cString: resolved))
        free(resolved)
        guard enumerated != spelled else { return { $0 } }
        return { path in
            guard MountTable.path(path, isAtOrUnder: enumerated) else { return path }
            return spelled + path.dropFirst(enumerated.count)
        }
    }

    /// 起点のフォルダ(重なっていてよい。同じ本は 1 度だけ返す)を探す。
    static func scan(roots: [String], protectedPrefixes: [String] = DirectoryProbe.protectedPrefixes) -> Result {
        var result = Result()
        var seen = Set<String>()
        var visited = 0
        let mountTable = MountTable.current()
        // 起点どうしが入れ子なら、外側だけを歩く。
        let normalizedRoots = Array(Set(roots.map(MountTable.normalized))).sorted()
        let outermost = normalizedRoots.filter { root in
            !normalizedRoots.contains { $0 != root && MountTable.path(root, isAtOrUnder: $0) }
        }
        for root in outermost {
            if Cancellation.isRequestedInCurrentScope { break }
            // 起点がすでに保護下なら、その中は許す(利用者が選んだ)。
            let skips = protectedPrefixes.filter { !MountTable.path(root, isAtOrUnder: $0) }
            scan(root: root, skipping: skips, mountTable: mountTable, visited: &visited, seen: &seen, into: &result)
            if result.isTruncated { break }
        }
        return result
    }

    private static func scan(root: String, skipping protectedPrefixes: [String], mountTable: MountTable, visited: inout Int,
                             seen: inout Set<String>, into result: inout Result) {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return }
        /// フォルダ → そのフォルダの属性(直下に画像があれば本になる)。
        var folderFacts: [String: ScannedBook] = [:]
        var imageFolders = Set<String>()
        /// 書庫・PDF・EPUB を直下に持つフォルダ(規則 2 の「本のファイルが無い」を確かめる)。
        var bookFileFolders = Set<String>()
        var files: [ScannedBook] = []
        let respell = pathRespeller(root: root)
        for case let url as URL in enumerator {
            if Cancellation.isRequestedInCurrentScope { return }
            visited += 1
            if visited > maxEntries {
                result.isTruncated = true
                break
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let path = respell(MountTable.normalized(url.path))
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
                bookFileFolders.insert((path as NSString).deletingLastPathComponent)
                files.append(ScannedBook(path: path, isFolder: false, creationDate: values?.creationDate,
                                         modificationDate: values?.contentModificationDate,
                                         fileSize: values?.fileSize.map(Int64.init),
                                         addedDate: values?.addedToDirectoryDate))
            }
        }
        // 画像フォルダの本。その中のフォルダ(章ごとのフォルダなど)は同じ本の一部なので外す。起点そのものは本にしない
        // (登録したフォルダ = 本棚。フォルダ 1 つを 1 冊として登録したいなら、その親を登録する)。
        //
        // 本のフォルダの決まりはアプリのほかの所と同じ(ShelfFolderResolver の規則 1・2。2026-09-22 の監査 ―― 以前は直下に画像のある
        // フォルダだけを本にし、章ごとに画像フォルダを分けた本を章ごとの別の本として並べていた): 直下に画像がある(規則 1)か、
        // 直下に画像も本のファイルも無く、直下に画像フォルダがある(規則 2)。いちばん外側のものが本。
        let normalizedRoot = MountTable.normalized(root)
        var candidates = imageFolders
        for folder in imageFolders {
            let parent = MountTable.normalized((folder as NSString).deletingLastPathComponent)
            guard parent != normalizedRoot, MountTable.path(parent, isAtOrUnder: normalizedRoot),
                  !imageFolders.contains(parent), !bookFileFolders.contains(parent) else { continue }
            candidates.insert(parent)
        }
        let sortedImageFolders = candidates.filter { $0 != normalizedRoot }.sorted()
        // 祖先は子より先に並ぶ(並べ替え済み)ので、先に本にしたフォルダの配下なら外す。祖先を辿って確かめる(本のフォルダを
        // 1 つずつ比べると 2 乗になる。2026-09-23 の 3 回目の監査の低 ―― 下の書庫の除外も同じ)。
        var bookFolders: [String] = []
        var bookFolderSet = Set<String>()
        for folder in sortedImageFolders where !MountTable.path(folder, isAtOrUnderAnyOf: bookFolderSet) {
            if Cancellation.isRequestedInCurrentScope { return }
            bookFolders.append(folder)
            bookFolderSet.insert(MountTable.normalized(folder))
        }
        // 本にしたものだけ、表紙の鍵を作る(1 冊に 1 回の lstat。ネットワークでもフォルダを列挙した直後は属性のキャッシュに載っている)。
        for folder in bookFolders where seen.insert(folder).inserted {
            var book = folderFacts[folder] ?? ScannedBook(path: folder, isFolder: true, creationDate: nil,
                                                         modificationDate: nil, fileSize: nil)
            book.thumbnailKey = FileBrowserThumbnailKey.of(URL(fileURLWithPath: folder, isDirectory: true), mountTable: mountTable)
            result.books.append(book)
        }
        // 本のフォルダの中にある書庫・PDF・EPUB は、そのフォルダの本のページ(BookLoader はフォルダの本の中の書庫も読み込む)なので、
        // 別の本として重ねて並べない(2026-09-22 の監査。以前は「フォルダの本は画像だけを読む」として 1 冊ずつ数えていたが、誤り)。
        for var file in files where !MountTable.path(file.path, isAtOrUnderAnyOf: bookFolderSet)
            && seen.insert(file.path).inserted {
            file.thumbnailKey = FileBrowserThumbnailKey.of(URL(fileURLWithPath: file.path), mountTable: mountTable)
            result.books.append(file)
        }
    }
}
