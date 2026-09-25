import Foundation

/// サンドボックスのコンテナ(`~/Library/Containers/<bundle id>/Data`)がディスク上で占めている
/// 容量の内訳。サイドパネルのリソースモニタが表示する。
///
/// すべてバイト数。`nil`は「測れなかった」(ディレクトリが無い・読めない)で、0とは区別する。
nonisolated struct StorageUsage: Equatable, Sendable {
    /// コンテナ全体(下の内訳の合計+その他)。
    var containerBytes: Int?
    /// この起動が作った一時ファイル(入れ子の書庫の展開物。`TemporaryFileStore.sessionDirectory`)。
    var sessionTemporaryBytes: Int
    /// この起動の一時ファイルの個数(「本を開いていないのに残っている」の判定用)。
    var sessionTemporaryFileCount: Int
    /// 他の(もう生きていない)セッションが残した一時ファイル。起動時に掃除されるので通常0。
    /// 0でないこと自体が異常なので、内訳としては表示せず異常判定にだけ使う。
    var staleTemporaryBytes: Int
    var staleTemporaryEntryCount: Int
    /// サムネイルのディスクキャッシュ(ThumbnailDiskCache)。
    var thumbnailCacheBytes: Int?
    /// ページ一覧・構造・ページ寸法のキャッシュ(BookPageListCache)。
    var pageListCacheBytes: Int?
    /// コレクション表紙(ユーザー要望 2026-09-09)。表示用に焼いた768pxのJPEG
    /// (CollectionCoverStore)と、利用者が指定した画像の複製(CollectionCoverSourceStore)の
    /// 合計。利用者から見れば同じ「コレクション表紙」なので1つの数にまとめる。
    ///
    /// **キャッシュではない。** 消えると登録してある本の全冊ぶんを読み直すことになるので、
    /// Cachesではなく Application Support に置いてある(CollectionCoverStoreの型コメント)。
    /// しかも複製のほうは作り直せない(利用者が元ファイルを既に捨てているかもしれない)。
    /// だからこそ、上限も自動削除も無いまま増えていく側の容量として内訳に出す。
    var collectionCoverBytes: Int?
    /// 焼いたコレクションのタイル(CollectionTileImageStore)。
    ///
    /// **こちらはキャッシュ。** カバー画像から数msで作り直せるので Caches に置いてあり、
    /// 上限(CollectionTileImageStore.maxTotalBytes)を超えたら古いものから捨てる。
    var collectionTileBytes: Int?
    /// ファイルブラウザの絵のディスクキャッシュ(FileBrowserThumbnailDiskCache。改善要望7 段階 7a)。
    var fileBrowserThumbnailCacheBytes: Int? = nil
    /// SwiftDataのストア(`default.store` + `-wal` + `-shm`)。
    var databaseBytes: Int?
    var scannedAt: Date

    /// コンテナ全体から、内訳として名前の付いているものを除いた残り。
    var otherBytes: Int? {
        guard let containerBytes else { return nil }
        let known = sessionTemporaryBytes + staleTemporaryBytes + (thumbnailCacheBytes ?? 0)
            + (pageListCacheBytes ?? 0) + (collectionCoverBytes ?? 0) + (collectionTileBytes ?? 0)
            + (fileBrowserThumbnailCacheBytes ?? 0) + (databaseBytes ?? 0)
        return max(containerBytes - known, 0)
    }
}

/// `StorageUsage`を実際に測る。ディレクトリの全走査を伴うので、**必ずメインアクターの外**
/// (`Task.detached`)で呼ぶこと。走査の重さはコンテナの中身に比例し、サムネイルキャッシュを
/// 上限いっぱい(2000MB、数万ファイル)まで使っていれば1秒前後かかりうる。
///
/// ■ シンボリックリンクは辿らない
/// コンテナの`Library/Application Support/`には`AddressBook`・`iCloud`など**コンテナの外を
/// 指すシンボリックリンク**がOSによって置かれている(実機で確認)。辿ると他所の容量を
/// 数えてしまうか、サンドボックスに拒否される。`FileManager.enumerator`はリンク先へ
/// 降りないが、リンク自体のサイズ(数十バイト)が`fileSize`に乗るので、`isSymbolicLinkKey`で
/// 明示的に除外している。
///
/// nonisolated: 状態を持たない。`Task.detached`の中から呼ぶため。
nonisolated enum StorageUsageScanner {
    /// 内訳の切り分けに使う場所。走査は`Task.detached`で行うが、`ThumbnailDiskCache.shared`や
    /// `QooViewerApp.modelConfiguration`の参照はメインアクターに縛られているものがあるため、
    /// 呼び出し側がメインアクター上で作って渡す。
    struct Locations: Sendable {
        var containerRoot: URL
        var sessionTemporaryDirectory: URL
        var temporaryRoot: URL
        var thumbnailCacheDirectory: URL?
        var pageListCacheDirectory: URL?
        var collectionCoverDirectory: URL?
        /// コレクション表紙の元画像(CollectionCoverSourceStore)。上と足して1つの数にする。
        var collectionCoverSourceDirectory: URL?
        var collectionTileDirectory: URL?
        var fileBrowserThumbnailCacheDirectory: URL? = nil
        var databaseStoreURL: URL
    }

    /// 呼び出し側のTaskが取り消されたら、途中で打ち切ってnilを返す(ディレクトリの列挙の
    /// 途中でTask.isCancelledを見る)。「今すぐ更新」の連打で走査が丸ごと並走しないため。
    ///
    /// ■ コンテナは 1 回だけ辿る(2026-09-25 の監査)
    /// 内訳のフォルダはどれもコンテナの中にある。以前はコンテナ全体を辿った後、内訳のフォルダをもう一度 1 つずつ辿っていた
    /// (サムネイルのキャッシュの数万ファイルを 15 秒ごとに 2 度ずつ stat)。今はコンテナを辿りながら、ファイルをそれが入っている
    /// 内訳へ振り分ける。コンテナの外にある内訳(テストや、サンドボックスでない実行)だけ、今までどおり別に辿る。
    /// 「無い」(nil)と「空」(0)の区別は、内訳のフォルダがあるかどうかで決める(今までと同じ)。
    static func scan(_ locations: Locations) -> StorageUsage? {
        let rootPath = comparablePath(locations.containerRoot)
        var session: DirectorySize?
        var thumbnails: DirectorySize?
        var pageLists: DirectorySize?
        var covers: DirectorySize?
        var coverSources: DirectorySize?
        var tiles: DirectorySize?
        var fileBrowserThumbnails: DirectorySize?
        // 内訳のフォルダがあれば 0 から数え始める。コンテナの中にあれば、下の 1 回の走査で振り分けるための接頭辞を返す。
        func bucket(_ directory: URL?, into total: inout DirectorySize?) -> String? {
            guard let directory, isExistingDirectory(directory) else { return nil }
            let path = comparablePath(directory)
            guard path.hasPrefix(rootPath + "/") else {
                total = directorySize(at: directory)
                return nil
            }
            total = DirectorySize(bytes: 0, fileCount: 0)
            return path
        }
        let sessionPath = bucket(locations.sessionTemporaryDirectory, into: &session)
        let thumbnailPath = bucket(locations.thumbnailCacheDirectory, into: &thumbnails)
        let pageListPath = bucket(locations.pageListCacheDirectory, into: &pageLists)
        let coverPath = bucket(locations.collectionCoverDirectory, into: &covers)
        let coverSourcePath = bucket(locations.collectionCoverSourceDirectory, into: &coverSources)
        let tilePath = bucket(locations.collectionTileDirectory, into: &tiles)
        let fileBrowserThumbnailPath = bucket(locations.fileBrowserThumbnailCacheDirectory, into: &fileBrowserThumbnails)
        // 他の起動が残した一時ファイル(`tmp/` 直下の残骸)。直下の一覧で決め、中身の量は下の 1 回の走査で数える。
        var stale = staleTemporaryEntries(in: locations.temporaryRoot)
        let staleDirectories = comparablePath(locations.temporaryRoot).hasPrefix(rootPath + "/") ? stale.directories : []
        if staleDirectories.isEmpty, !stale.directories.isEmpty {
            // コンテナの外(テストや、サンドボックスでない実行)なら今までどおり別に辿る。
            stale.bytes += stale.directories.reduce(0) { $0 + (directorySize(at: URL(fileURLWithPath: $1, isDirectory: true))?.bytes ?? 0) }
        }

        var container: DirectorySize?
        if isExistingDirectory(locations.containerRoot),
           let enumerator = FileManager.default.enumerator(
               at: locations.containerRoot, includingPropertiesForKeys: Array(sizeKeys), options: []
           ) {
            var total = DirectorySize(bytes: 0, fileCount: 0)
            for case let url as URL in enumerator {
                if Task.isCancelled { return nil }
                guard let values = try? url.resourceValues(forKeys: sizeKeys),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true
                else { continue }
                let size = values.fileSize ?? 0
                total.bytes += size
                total.fileCount += 1
                let path = comparablePath(url)
                func isIn(_ prefix: String?) -> Bool { prefix.map { path.hasPrefix($0 + "/") } ?? false }
                if isIn(sessionPath) {
                    session?.bytes += size
                    session?.fileCount += 1
                } else if isIn(thumbnailPath) {
                    thumbnails?.bytes += size
                } else if isIn(pageListPath) {
                    pageLists?.bytes += size
                } else if isIn(coverPath) {
                    covers?.bytes += size
                } else if isIn(coverSourcePath) {
                    coverSources?.bytes += size
                } else if isIn(tilePath) {
                    tiles?.bytes += size
                } else if isIn(fileBrowserThumbnailPath) {
                    fileBrowserThumbnails?.bytes += size
                } else if staleDirectories.contains(where: { path.hasPrefix($0 + "/") }) {
                    stale.bytes += size
                }
            }
            container = total
        }
        guard !Task.isCancelled else { return nil }
        let coverTotal: Int? = covers == nil && coverSources == nil ? nil : (covers?.bytes ?? 0) + (coverSources?.bytes ?? 0)
        return StorageUsage(
            containerBytes: container.map(\.bytes),
            sessionTemporaryBytes: session?.bytes ?? 0,
            sessionTemporaryFileCount: session?.fileCount ?? 0,
            staleTemporaryBytes: stale.bytes,
            staleTemporaryEntryCount: stale.entryCount,
            thumbnailCacheBytes: thumbnails?.bytes,
            pageListCacheBytes: pageLists?.bytes,
            collectionCoverBytes: coverTotal,
            collectionTileBytes: tiles?.bytes,
            fileBrowserThumbnailCacheBytes: fileBrowserThumbnails?.bytes,
            databaseBytes: databaseSize(storeURL: locations.databaseStoreURL),
            scannedAt: Date()
        )
    }

    /// 前方一致で比べるためのパス(`/private` の有無を揃え、末尾の `/` を落とす)。
    private static func comparablePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        if path.hasPrefix("/private/var/") || path.hasPrefix("/private/tmp/") { path = String(path.dropFirst("/private".count)) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private struct DirectorySize {
        var bytes: Int
        var fileCount: Int
    }

    private static let sizeKeys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]

    /// ディレクトリが存在しなければnil(「無い」と「空」を区別する)。
    private static func directorySize(at directory: URL) -> DirectorySize? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: Array(sizeKeys), options: []
              )
        else { return nil }
        var total = 0
        var count = 0
        for case let url as URL in enumerator {
            if Task.isCancelled { return nil }
            guard let values = try? url.resourceValues(forKeys: sizeKeys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true
            else { continue }
            total += values.fileSize ?? 0
            count += 1
        }
        return DirectorySize(bytes: total, fileCount: count)
    }

    /// `tmp/`直下で、他セッションの残骸と判定されるエントリ。判定は起動時の掃除と同じ`TemporaryFileStore.isStaleEntry`。
    /// ファイルの残骸はその大きさを `bytes` に足し、フォルダの残骸は中身を数えずにパス(`comparablePath`)を返す
    /// (中身はコンテナの 1 回の走査で数える。`scan`)。
    private static func staleTemporaryEntries(
        in temporaryRoot: URL
    ) -> (bytes: Int, entryCount: Int, directories: [String]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporaryRoot, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return (0, 0, []) }
        var bytes = 0
        var count = 0
        var directories: [String] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = values?.isDirectory ?? false
            guard TemporaryFileStore.isStaleEntry(entry, isDirectory: isDirectory) else { continue }
            count += 1
            if isDirectory {
                directories.append(comparablePath(entry))
            } else {
                bytes += values?.fileSize ?? 0
            }
        }
        return (bytes, count, directories)
    }

    /// ストア本体が無ければnil。WAL/SHMは無いことも普通なので、あるぶんだけ足す。
    private static func databaseSize(storeURL: URL) -> Int? {
        func size(_ url: URL) -> Int? {
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
        guard let base = size(storeURL) else { return nil }
        let directory = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        return base
            + (size(directory.appendingPathComponent(name + "-wal")) ?? 0)
            + (size(directory.appendingPathComponent(name + "-shm")) ?? 0)
    }
}
