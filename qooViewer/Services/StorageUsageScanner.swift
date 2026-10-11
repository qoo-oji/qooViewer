import Foundation

/// ファイルがディスクの上で実際に占めている大きさ(2026-10-11 のリソースモニタの点検)。
///
/// 以前はどこも `fileSizeKey`(ファイルの見かけの長さ)で数えていた。ネットワークボリューム上の本の手元の写し
/// (StagedFileSource)は最初に本の大きさまで `ftruncate` するスパースファイルなので、1 GB の本を開いた直後に、まだ数 MB しか
/// 読んでいなくても「一時ファイル 1 GB」と出ていた。小さなファイルはブロック単位で場所を取るので、見かけより大きくなる
/// (サムネイルの JPEG で数 %)。モニタの容量・ディスクキャッシュの上限・環境設定「キャッシュ」の使用量は、すべてこちらで数える ――
/// 上限(「最大サイズ」)は、利用者から見ればディスクをどれだけ使ってよいかなので。
nonisolated enum DiskFootprint {
    /// 列挙・`resourceValues` で前もって読んでおく鍵。
    static let resourceKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]

    /// 確保されている大きさ(取れなければ見かけの長さ)。
    static func bytes(_ values: URLResourceValues) -> Int {
        values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
    }

    /// 1 つのファイルの、確保されている大きさ(読めなければ nil)。
    static func bytes(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
        return bytes(values)
    }
}

/// サンドボックスのコンテナ(`~/Library/Containers/<bundle id>/Data`)がディスク上で占めている
/// 容量の内訳。サイドパネル(とホームのインスペクタ)のリソースモニタが、機能ごとにまとめて表示する
/// (2026-10-11、利用者の要望: どの機能がどれだけディスクを使っているかを見えるように)。
///
/// すべて**ディスクの上で確保されているバイト数**(`DiskFootprint`)。`nil`は「測れなかった」(ディレクトリが無い・読めない)で、
/// 0とは区別する。
nonisolated struct StorageUsage: Equatable, Sendable {
    /// コンテナ全体(下の内訳の合計+その他)。
    var containerBytes: Int?

    // MARK: 一時ファイル(この起動のもの = `TemporaryFileStore.sessionDirectory`)

    /// 入れ子の書庫の展開物(予算より大きい中の書庫。「新しい本として開く」の一時コピーもここ)。
    var nestedTemporaryBytes: Int = 0
    var nestedTemporaryFileCount: Int = 0
    /// ネットワークボリューム上の本の手元の写し(StagedFileSource の `.staged`。スパースなので読んだぶんだけ)。
    var stagedTemporaryBytes: Int = 0
    var stagedTemporaryFileCount: Int = 0
    /// 他の(もう生きていない)セッションが残した一時ファイル。起動時に掃除されるので通常0。
    var staleTemporaryBytes: Int = 0
    var staleTemporaryEntryCount: Int = 0

    // MARK: ビューア

    /// サムネイルのディスクキャッシュ(ThumbnailDiskCache)。
    var thumbnailCacheBytes: Int?
    /// ページ一覧・構造・ページ寸法のキャッシュ(BookPageListCache)。
    var pageListCacheBytes: Int?

    // MARK: ライブラリ

    /// コレクション表紙: 表示用に焼いた768pxのJPEG(CollectionCoverStore)。
    ///
    /// **キャッシュではない。** 消えると登録してある本の全冊ぶんを読み直すことになるので、
    /// Cachesではなく Application Support に置いてある(CollectionCoverStoreの型コメント)。
    var collectionCoverBytes: Int?
    /// 利用者が表紙に指定した画像の複製(CollectionCoverSourceStore)。**作り直せない**(元のファイルはもう無いかもしれない)。
    /// 以前は上の表紙と 1 つの数にまとめていたが、性格が違う(上は本から作り直せる)ので分けた(2026-10-11)。
    var collectionCoverSourceBytes: Int?
    /// 焼いたコレクションのタイル(CollectionTileImageStore)。
    ///
    /// **こちらはキャッシュ。** カバー画像から数msで作り直せるので Caches に置いてあり、
    /// 上限(CollectionTileImageStore.maxTotalBytes)を超えたら古いものから捨てる。
    var collectionTileBytes: Int?

    // MARK: ファイルブラウザ・スマートライブラリ

    /// ファイルブラウザ・スマートライブラリ・インスペクタの絵のディスクキャッシュ(FileBrowserThumbnailDiskCache)。
    var fileBrowserThumbnailCacheBytes: Int?
    /// スマートライブラリの最後の一覧(Application Support/SmartLibrary。SmartLibraryCatalog.defaultCacheURL)。
    var smartLibraryCatalogBytes: Int?

    // MARK: メタデータ

    /// qooMeta の規則(Application Support/qooMeta。MetadataRulesStore)。
    var metadataRulesBytes: Int?
    /// メタデータの対象として機能が記録した本の一覧(Application Support/MetadataCorpus。MetadataCorpusStore)。
    var metadataCorpusBytes: Int?

    // MARK: 保存データ

    /// SwiftDataのストア(`default.store` + `-wal` + `-shm`)。
    var databaseBytes: Int?
    /// UserDefaults(Library/Preferences。環境設定・履歴・フォルダの許可・ウインドウの状態など)。
    var preferencesBytes: Int?

    var scannedAt: Date

    /// この起動の一時ファイルの合計。
    var sessionTemporaryBytes: Int { nestedTemporaryBytes + stagedTemporaryBytes }
    /// この起動の一時ファイルの個数。
    var sessionTemporaryFileCount: Int { nestedTemporaryFileCount + stagedTemporaryFileCount }

    /// 内訳として名前の付いているものの合計。
    var namedBytes: Int {
        let parts: [Int?] = [
            thumbnailCacheBytes, pageListCacheBytes, collectionCoverBytes, collectionCoverSourceBytes, collectionTileBytes,
            fileBrowserThumbnailCacheBytes, smartLibraryCatalogBytes, metadataRulesBytes, metadataCorpusBytes,
            databaseBytes, preferencesBytes,
        ]
        return sessionTemporaryBytes + staleTemporaryBytes + parts.reduce(0) { $0 + ($1 ?? 0) }
    }

    /// コンテナ全体から、内訳として名前の付いているものを除いた残り。
    var otherBytes: Int? {
        guard let containerBytes else { return nil }
        return max(containerBytes - namedBytes, 0)
    }
}

/// `StorageUsage`を実際に測る。ディレクトリの全走査を伴うので、**必ずメインアクターの外**
/// (`FileIO`の上)で呼ぶこと。走査の重さはコンテナの中身に比例し、サムネイルキャッシュを
/// 上限いっぱい(2000MB、数万ファイル)まで使っていれば1秒前後かかりうる。
///
/// ■ シンボリックリンクは辿らない
/// コンテナの`Library/Application Support/`には`AddressBook`・`iCloud`など**コンテナの外を
/// 指すシンボリックリンク**がOSによって置かれている(実機で確認)。辿ると他所の容量を
/// 数えてしまうか、サンドボックスに拒否される。`FileManager.enumerator`はリンク先へ
/// 降りないが、リンク自体のサイズ(数十バイト)が乗るので、`isSymbolicLinkKey`で
/// 明示的に除外している。
///
/// nonisolated: 状態を持たない。`FileIO`の上から呼ぶため。
nonisolated enum StorageUsageScanner {
    /// 内訳の切り分けに使う場所。走査はメインアクターの外で行うが、`ThumbnailDiskCache.shared`や
    /// `QooViewerApp.modelConfiguration`の参照はメインアクターに縛られているものがあるため、
    /// 呼び出し側がメインアクター上で作って渡す。
    struct Locations: Sendable {
        var containerRoot: URL
        var sessionTemporaryDirectory: URL
        var temporaryRoot: URL
        var thumbnailCacheDirectory: URL?
        var pageListCacheDirectory: URL?
        var collectionCoverDirectory: URL?
        /// コレクション表紙に利用者が指定した画像の複製(CollectionCoverSourceStore)。
        var collectionCoverSourceDirectory: URL?
        var collectionTileDirectory: URL?
        var fileBrowserThumbnailCacheDirectory: URL? = nil
        var smartLibraryCatalogDirectory: URL? = nil
        var metadataRulesDirectory: URL? = nil
        var metadataCorpusDirectory: URL? = nil
        var preferencesDirectory: URL? = nil
        var databaseStoreURL: URL
    }

    /// 内訳 1 つ(フォルダ 1 つ)。
    private struct Bucket {
        let directory: URL?
        var size: DirectorySize?
        /// コンテナの中にあれば、1 回の走査で振り分けるための接頭辞。
        var prefix: String?
    }

    /// 呼び出し側のTaskが取り消されたら、途中で打ち切ってnilを返す(ディレクトリの列挙の
    /// 途中で`Cancellation.isRequestedInCurrentScope`を見る)。「今すぐ更新」の連打で走査が丸ごと並走しないため。
    /// 呼び出し側は`FileIO.perform`の上で走らせる(2026-10-04 の監査 §2-4。以前は`Task.detached`で、借りたスレッドの外の
    /// `Task.isCancelled`を見ていた ―― FileIO の上では`Task.isCancelled`は常に false なので、旗のほうを読む)。
    ///
    /// ■ コンテナは 1 回だけ辿る(2026-09-25 の監査)
    /// 内訳のフォルダはどれもコンテナの中にある。以前はコンテナ全体を辿った後、内訳のフォルダをもう一度 1 つずつ辿っていた
    /// (サムネイルのキャッシュの数万ファイルを 15 秒ごとに 2 度ずつ stat)。今はコンテナを辿りながら、ファイルをそれが入っている
    /// 内訳へ振り分ける。コンテナの外にある内訳(テストや、サンドボックスでない実行)だけ、今までどおり別に辿る。
    /// 「無い」(nil)と「空」(0)の区別は、内訳のフォルダがあるかどうかで決める(今までと同じ)。
    ///
    /// ■ この起動の一時ファイルは 2 つに分ける(2026-10-11)
    /// `.staged`(ネットワークボリュームの本の手元の写し。StagedFileSource)とそれ以外(入れ子の書庫の展開物)。以前は 1 つの
    /// 「一時ファイル」で、説明は入れ子の書庫のことしか書いていなかった。
    static func scan(_ locations: Locations) -> StorageUsage? {
        let rootPath = comparablePath(locations.containerRoot)
        // 内訳のフォルダがあれば 0 から数え始める。コンテナの中にあれば、下の 1 回の走査で振り分けるための接頭辞を持つ。
        // `walksOutside: false` は、コンテナの外にあっても辿らずに 0 から始める(この起動の一時ファイルは下の splitTemporary が
        // 1 回で数える。2026-10-11 のレビュー ―― 以前はここで辿った値を捨てて、もう一度辿っていた)。
        func bucket(_ directory: URL?, walksOutside: Bool = true) -> Bucket {
            guard let directory, isExistingDirectory(directory) else { return Bucket(directory: directory) }
            let path = comparablePath(directory)
            guard path.hasPrefix(rootPath + "/") else {
                return Bucket(directory: directory, size: walksOutside ? directorySize(at: directory) : DirectorySize(bytes: 0, fileCount: 0))
            }
            return Bucket(directory: directory, size: DirectorySize(bytes: 0, fileCount: 0), prefix: path)
        }
        enum Name: CaseIterable {
            case session, thumbnails, pageLists, covers, coverSources, tiles, fileBrowserThumbnails,
                 smartLibrary, metadataRules, metadataCorpus, preferences
        }
        func directory(_ name: Name) -> URL? {
            switch name {
            case .session: locations.sessionTemporaryDirectory
            case .thumbnails: locations.thumbnailCacheDirectory
            case .pageLists: locations.pageListCacheDirectory
            case .covers: locations.collectionCoverDirectory
            case .coverSources: locations.collectionCoverSourceDirectory
            case .tiles: locations.collectionTileDirectory
            case .fileBrowserThumbnails: locations.fileBrowserThumbnailCacheDirectory
            case .smartLibrary: locations.smartLibraryCatalogDirectory
            case .metadataRules: locations.metadataRulesDirectory
            case .metadataCorpus: locations.metadataCorpusDirectory
            case .preferences: locations.preferencesDirectory
            }
        }
        var buckets: [Name: Bucket] = [:]
        for name in Name.allCases { buckets[name] = bucket(directory(name), walksOutside: name != .session) }
        // この起動の一時ファイルのうち、ネットワークボリュームの写し(`.staged`)。コンテナの外なら別に辿る。
        var staged = DirectorySize(bytes: 0, fileCount: 0)
        var nested = DirectorySize(bytes: 0, fileCount: 0)
        if buckets[.session]?.prefix == nil, let session = buckets[.session], session.size != nil, let directory = session.directory {
            (nested, staged) = splitTemporary(in: directory)
            buckets[.session]?.size = DirectorySize(bytes: nested.bytes + staged.bytes, fileCount: nested.fileCount + staged.fileCount)
        }
        // 他の起動が残した一時ファイル(`tmp/` 直下の残骸)。直下の一覧で決め、中身の量は下の 1 回の走査で数える。
        var stale = staleTemporaryEntries(in: locations.temporaryRoot)
        let staleDirectories = comparablePath(locations.temporaryRoot).hasPrefix(rootPath + "/") ? stale.directories : []
        if staleDirectories.isEmpty, !stale.directories.isEmpty {
            // コンテナの外(テストや、サンドボックスでない実行)なら今までどおり別に辿る。
            stale.bytes += stale.directories.reduce(0) { $0 + (directorySize(at: URL(fileURLWithPath: $1, isDirectory: true))?.bytes ?? 0) }
        }
        let prefixed = Name.allCases.compactMap { name in buckets[name]?.prefix.map { (name, $0) } }

        var container: DirectorySize?
        if isExistingDirectory(locations.containerRoot),
           let enumerator = FileManager.default.enumerator(
               at: locations.containerRoot, includingPropertiesForKeys: Array(sizeKeys), options: []
           ) {
            var total = DirectorySize(bytes: 0, fileCount: 0)
            for case let url as URL in enumerator {
                if Cancellation.isRequestedInCurrentScope { return nil }
                guard let values = try? url.resourceValues(forKeys: sizeKeys),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true
                else { continue }
                let size = DiskFootprint.bytes(values)
                total.bytes += size
                total.fileCount += 1
                let path = comparablePath(url)
                if let (name, _) = prefixed.first(where: { path.hasPrefix($0.1 + "/") }) {
                    buckets[name]?.size?.bytes += size
                    buckets[name]?.size?.fileCount += 1
                    if name == .session {
                        if url.pathExtension == stagedFileExtension {
                            staged.bytes += size
                            staged.fileCount += 1
                        } else {
                            nested.bytes += size
                            nested.fileCount += 1
                        }
                    }
                } else if staleDirectories.contains(where: { path.hasPrefix($0 + "/") }) {
                    stale.bytes += size
                }
            }
            container = total
        }
        guard !Cancellation.isRequestedInCurrentScope else { return nil }
        func bytes(_ name: Name) -> Int? { buckets[name]?.size?.bytes }
        return StorageUsage(
            containerBytes: container.map(\.bytes),
            nestedTemporaryBytes: nested.bytes,
            nestedTemporaryFileCount: nested.fileCount,
            stagedTemporaryBytes: staged.bytes,
            stagedTemporaryFileCount: staged.fileCount,
            staleTemporaryBytes: stale.bytes,
            staleTemporaryEntryCount: stale.entryCount,
            thumbnailCacheBytes: bytes(.thumbnails),
            pageListCacheBytes: bytes(.pageLists),
            collectionCoverBytes: bytes(.covers),
            collectionCoverSourceBytes: bytes(.coverSources),
            collectionTileBytes: bytes(.tiles),
            fileBrowserThumbnailCacheBytes: bytes(.fileBrowserThumbnails),
            smartLibraryCatalogBytes: bytes(.smartLibrary),
            metadataRulesBytes: bytes(.metadataRules),
            metadataCorpusBytes: bytes(.metadataCorpus),
            databaseBytes: databaseSize(storeURL: locations.databaseStoreURL),
            preferencesBytes: bytes(.preferences),
            scannedAt: Date()
        )
    }

    /// ネットワークボリュームの写しの拡張子(StagedFileSource が `TemporaryFileStore.makeFileURL(extension:)` へ渡すもの)。
    static let stagedFileExtension = "staged"

    /// コンテナの外にある、この起動の一時ファイルのフォルダを、入れ子の書庫と写しに分けて数える。
    private static func splitTemporary(in directory: URL) -> (nested: DirectorySize, staged: DirectorySize) {
        var nested = DirectorySize(bytes: 0, fileCount: 0)
        var staged = DirectorySize(bytes: 0, fileCount: 0)
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(sizeKeys), options: []
        ) else { return (nested, staged) }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: sizeKeys),
                  values.isSymbolicLink != true, values.isRegularFile == true
            else { continue }
            let size = DiskFootprint.bytes(values)
            if url.pathExtension == stagedFileExtension {
                staged.bytes += size
                staged.fileCount += 1
            } else {
                nested.bytes += size
                nested.fileCount += 1
            }
        }
        return (nested, staged)
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

    private static let sizeKeys: Set<URLResourceKey> = DiskFootprint.resourceKeys.union([.isRegularFileKey, .isSymbolicLinkKey])

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
            if Cancellation.isRequestedInCurrentScope { return nil }
            guard let values = try? url.resourceValues(forKeys: sizeKeys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true
            else { continue }
            total += DiskFootprint.bytes(values)
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
            at: temporaryRoot, includingPropertiesForKeys: [.isDirectoryKey] + Array(DiskFootprint.resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return (0, 0, []) }
        var bytes = 0
        var count = 0
        var directories: [String] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: DiskFootprint.resourceKeys.union([.isDirectoryKey]))
            let isDirectory = values?.isDirectory ?? false
            guard TemporaryFileStore.isStaleEntry(entry, isDirectory: isDirectory) else { continue }
            count += 1
            if isDirectory {
                directories.append(comparablePath(entry))
            } else {
                bytes += values.map(DiskFootprint.bytes) ?? 0
            }
        }
        return (bytes, count, directories)
    }

    /// ストア本体が無ければnil。WAL/SHMは無いことも普通なので、あるぶんだけ足す。
    private static func databaseSize(storeURL: URL) -> Int? {
        func size(_ url: URL) -> Int? { DiskFootprint.bytes(of: url) }
        guard let base = size(storeURL) else { return nil }
        let directory = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        return base
            + (size(directory.appendingPathComponent(name + "-wal")) ?? 0)
            + (size(directory.appendingPathComponent(name + "-shm")) ?? 0)
    }
}
