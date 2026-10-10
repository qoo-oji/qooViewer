import Foundation
import Testing

@testable import qooViewer

/// コンテナの容量の走査(Services/StorageUsageScanner.swift)。
///
/// 実物のコンテナは**共有の保存先**なので触らない ―― 作業フォルダの中に同じ形の木を作り、
/// `Locations` でそこを指す。見たいのは内訳の切り分け方そのもの:
/// 「無い」と「空」を区別すること、シンボリックリンクを数えないこと、
/// 名前の付いた内訳を引いた残りが「その他」になること。
///
/// 容量はディスクの上で確保された量(DiskFootprint)で数えるので、ファイルの大きさはブロック(`block` = 4096 バイト)の倍数にする
/// (100 バイトのファイルも 1 ブロックを占める)。
struct StorageUsageScannerTests {
    private static let block = 4096
    private let block = StorageUsageScannerTests.block

    /// コンテナに見立てた木。バイト数はファイルの中身の長さそのもの(ブロックの倍数)。
    private struct Container {
        let temporary: TemporaryDirectory
        let root: URL
        let sessionTemporary: URL
        let temporaryRoot: URL
        let thumbnailCache: URL
        let pageListCache: URL
        let collectionCovers: URL
        let collectionCoverSources: URL
        let collectionTiles: URL
        let fileBrowserThumbnails: URL
        let smartLibrary: URL
        let metadataRules: URL
        let metadataCorpus: URL
        let preferences: URL
        let databaseStore: URL

        init(label: String) throws {
            temporary = try TemporaryDirectory(label)
            root = temporary.file("Data")
            temporaryRoot = root.appendingPathComponent("tmp", isDirectory: true)
            sessionTemporary = temporaryRoot.appendingPathComponent(
                "qooViewer-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            thumbnailCache = root.appendingPathComponent("Library/Caches/thumbnails", isDirectory: true)
            pageListCache = root.appendingPathComponent("Library/Caches/pagelist", isDirectory: true)
            collectionCovers = root.appendingPathComponent(
                "Library/Application Support/CollectionCovers", isDirectory: true)
            collectionCoverSources = root.appendingPathComponent(
                "Library/Application Support/CollectionCoverSources", isDirectory: true)
            collectionTiles = root.appendingPathComponent("Library/Caches/CollectionTiles", isDirectory: true)
            fileBrowserThumbnails = root.appendingPathComponent("Library/Caches/FileBrowserThumbnails", isDirectory: true)
            smartLibrary = root.appendingPathComponent("Library/Application Support/SmartLibrary", isDirectory: true)
            metadataRules = root.appendingPathComponent("Library/Application Support/qooMeta", isDirectory: true)
            metadataCorpus = root.appendingPathComponent("Library/Application Support/MetadataCorpus", isDirectory: true)
            preferences = root.appendingPathComponent("Library/Preferences", isDirectory: true)
            databaseStore = root.appendingPathComponent("Library/Application Support/default.store")
        }

        var locations: StorageUsageScanner.Locations {
            .init(
                containerRoot: root, sessionTemporaryDirectory: sessionTemporary,
                temporaryRoot: temporaryRoot, thumbnailCacheDirectory: thumbnailCache,
                pageListCacheDirectory: pageListCache, collectionCoverDirectory: collectionCovers,
                collectionCoverSourceDirectory: collectionCoverSources, collectionTileDirectory: collectionTiles,
                fileBrowserThumbnailCacheDirectory: fileBrowserThumbnails, smartLibraryCatalogDirectory: smartLibrary,
                metadataRulesDirectory: metadataRules, metadataCorpusDirectory: metadataCorpus,
                preferencesDirectory: preferences, databaseStoreURL: databaseStore
            )
        }

        /// `bytes` バイトのファイルを置く(中間フォルダは作る)。
        func write(_ relativePath: String, bytes: Int) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: url)
        }
    }

    /// 生きていない pid。macOS の既定の上限(99998)より大きいので、再利用の心配も無い。
    private let deadPID = 999_999

    private func fullContainer(label: String) throws -> Container {
        let container = try Container(label: label)
        let session = "tmp/qooViewer-\(ProcessInfo.processInfo.processIdentifier)"
        // この起動の一時ファイル(入れ子の書庫の展開物と、ネットワークボリュームの写し)。
        try container.write("\(session)/inner.cbz", bytes: 1 * block)
        try container.write("\(session)/remote.staged", bytes: 2 * block)
        // もう生きていない起動が残したセッションフォルダ。
        try container.write("tmp/qooViewer-\(deadPID)/inner.cbz", bytes: 3 * block)
        // セッションフォルダを導入する前の版が残した `<UUID>.<書庫拡張子>`。
        try container.write("tmp/\(UUID().uuidString).cbz", bytes: 4 * block)
        try container.write("Library/Caches/thumbnails/a.bin", bytes: 5 * block)
        try container.write("Library/Caches/pagelist/a.json", bytes: 6 * block)
        try container.write("Library/Application Support/CollectionCovers/a.jpg", bytes: 7 * block)
        try container.write("Library/Application Support/CollectionCoverSources/a.jpg", bytes: 8 * block)
        try container.write("Library/Caches/CollectionTiles/a.jpg", bytes: 9 * block)
        try container.write("Library/Caches/FileBrowserThumbnails/v/a.jpg", bytes: 10 * block)
        try container.write("Library/Application Support/SmartLibrary/catalog.json", bytes: 11 * block)
        try container.write("Library/Application Support/qooMeta/settings.json", bytes: 12 * block)
        try container.write("Library/Application Support/MetadataCorpus/corpus.json", bytes: 13 * block)
        try container.write("Library/Preferences/app.plist", bytes: 14 * block)
        try container.write("Library/Application Support/default.store", bytes: 15 * block)
        try container.write("Library/Application Support/default.store-wal", bytes: 16 * block)
        try container.write("Library/Application Support/default.store-shm", bytes: 17 * block)
        // どの内訳にも属さないもの(= その他)。
        try container.write("Library/Saved Application State/state.dat", bytes: 18 * block)
        return container
    }

    @Test("内訳が切り分けられ、名前の付いたぶんを引いた残りが「その他」になる")
    func theBreakdownAddsUpToTheContainer() throws {
        let container = try fullContainer(label: "storage-full")
        let usage = try #require(StorageUsageScanner.scan(container.locations))

        #expect(usage.nestedTemporaryBytes == 1 * block)
        #expect(usage.nestedTemporaryFileCount == 1)
        #expect(usage.stagedTemporaryBytes == 2 * block)
        #expect(usage.stagedTemporaryFileCount == 1)
        #expect(usage.sessionTemporaryBytes == 3 * block)
        #expect(usage.sessionTemporaryFileCount == 2)
        #expect(usage.staleTemporaryBytes == 7 * block)     // 3(死んだセッション)+ 4(旧形式)
        #expect(usage.staleTemporaryEntryCount == 2)
        #expect(usage.thumbnailCacheBytes == 5 * block)
        #expect(usage.pageListCacheBytes == 6 * block)
        #expect(usage.collectionCoverBytes == 7 * block)
        #expect(usage.collectionCoverSourceBytes == 8 * block)
        #expect(usage.collectionTileBytes == 9 * block)
        #expect(usage.fileBrowserThumbnailCacheBytes == 10 * block)
        #expect(usage.smartLibraryCatalogBytes == 11 * block)
        #expect(usage.metadataRulesBytes == 12 * block)
        #expect(usage.metadataCorpusBytes == 13 * block)
        #expect(usage.preferencesBytes == 14 * block)
        #expect(usage.databaseBytes == 48 * block)          // 15 + wal 16 + shm 17
        #expect(usage.containerBytes == (1...18).reduce(0, +) * block)
        #expect(usage.otherBytes == 18 * block)
    }

    @Test("生きている起動のセッションフォルダは残骸ではない")
    func aLiveSessionDirectoryIsNotStale() throws {
        let container = try Container(label: "storage-live")
        try container.write("tmp/qooViewer-\(ProcessInfo.processInfo.processIdentifier)/inner.cbz", bytes: block)
        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.staleTemporaryEntryCount == 0)
        #expect(usage.staleTemporaryBytes == 0)
        #expect(usage.sessionTemporaryBytes == block)
    }

    @Test("`tmp/` 直下の無関係なファイル・フォルダは数えない(OS の置き土産を巻き込まない)")
    func unrelatedEntriesInTheTemporaryRootAreIgnored() throws {
        let container = try Container(label: "storage-unrelated")
        try container.write("tmp/TemporaryItems/whatever.dat", bytes: 1000)
        try container.write("tmp/not-a-uuid.cbz", bytes: 1000)
        try container.write("tmp/\(UUID().uuidString).txt", bytes: 1000)
        try container.write("tmp/qooViewer-notanumber/inner.cbz", bytes: 1000)
        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.staleTemporaryEntryCount == 0)
        #expect(usage.staleTemporaryBytes == 0)
    }

    @Test("「無い」と「空」を区別する ―― 無ければ nil、空なら 0")
    func aMissingDirectoryIsNilAndAnEmptyOneIsZero() throws {
        let container = try Container(label: "storage-missing")
        // コンテナのルートだけ作る(内訳のフォルダはどれも無い)。
        try FileManager.default.createDirectory(at: container.root, withIntermediateDirectories: true)
        var usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.containerBytes == 0)
        #expect(usage.thumbnailCacheBytes == nil)
        #expect(usage.pageListCacheBytes == nil)
        #expect(usage.databaseBytes == nil)
        // 無いものは 0 として足されるので、その他はコンテナ全体と同じ。
        #expect(usage.otherBytes == 0)

        try FileManager.default.createDirectory(at: container.thumbnailCache, withIntermediateDirectories: true)
        usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.thumbnailCacheBytes == 0)
    }

    @Test("コンテナのルートが無ければ、コンテナ全体もその他も nil")
    func aMissingContainerRootYieldsNil() throws {
        let container = try Container(label: "storage-noroot")
        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.containerBytes == nil)
        #expect(usage.otherBytes == nil)
        #expect(usage.sessionTemporaryBytes == 0)
        #expect(usage.sessionTemporaryFileCount == 0)
    }

    @Test("ストア本体が無ければ DB は nil(WAL/SHM だけ残っていても数えない)")
    func theDatabaseIsNilWithoutTheMainStoreFile() throws {
        let container = try Container(label: "storage-wal-only")
        try container.write("Library/Application Support/default.store-wal", bytes: block)
        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.databaseBytes == nil)
    }

    @Test("WAL/SHM が無いのは普通(あるぶんだけ足す)")
    func theDatabaseSumsOnlyTheFilesThatExist() throws {
        let container = try Container(label: "storage-store-only")
        try container.write("Library/Application Support/default.store", bytes: 5 * block)
        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.databaseBytes == 5 * block)
        try container.write("Library/Application Support/default.store-shm", bytes: block)
        #expect(StorageUsageScanner.scan(container.locations)?.databaseBytes == 6 * block)
    }

    @Test("シンボリックリンクは辿らず、リンク自身のサイズも数えない")
    func symbolicLinksAreExcluded() throws {
        let container = try Container(label: "storage-symlink")
        try container.write("Library/real.dat", bytes: block)

        // コンテナの外を指すリンク(実機では Application Support/ に OS が置く AddressBook 等)。
        let outside = container.temporary.file("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 9999).write(to: outside.appendingPathComponent("big.dat"))
        try FileManager.default.createSymbolicLink(
            at: container.root.appendingPathComponent("Library/AddressBook"), withDestinationURL: outside)

        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.containerBytes == block)
    }

    @Test("走査の結果には時刻が入る(異常判定が「同じ走査か」を見分けるため)")
    func theScanIsStamped() throws {
        let container = try fullContainer(label: "storage-stamp")
        let before = Date()
        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.scannedAt >= before)
        #expect(usage.scannedAt <= Date())
    }

    @Test("その他は負にならない(内訳の合計がコンテナ全体を上回っても 0 で止まる)")
    func theOtherBytesNeverGoNegative() {
        // 一時ファイルとキャッシュがコンテナの外(別ボリューム)にある構成を渡された場合。
        let usage = StorageUsage(containerBytes: 100, thumbnailCacheBytes: 5000, scannedAt: Date())
        #expect(usage.otherBytes == 0)
    }

    @Test("ネットワークボリュームの写し(スパースファイル)は、読んだぶんだけを数える(見かけの長さで数えない)")
    func aSparseNetworkCopyCountsOnlyWhatWasWritten() throws {
        // StagedFileSource は最初に本の大きさまで ftruncate し、読んだブロックだけを書く。以前は見かけの長さ(fileSize)で数えて
        // いたので、1 GB の本を開いた直後に「一時ファイル 1 GB」と出ていた(2026-10-11 のリソースモニタの点検)。
        let container = try Container(label: "storage-sparse")
        let url = container.root.appendingPathComponent(
            "tmp/qooViewer-\(ProcessInfo.processInfo.processIdentifier)/remote.staged")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(ftruncate(fd, off_t(64 << 20)) == 0)
        let written = Data(repeating: 0x41, count: block)
        let wrote = written.withUnsafeBytes { pwrite(fd, $0.baseAddress, block, off_t(8 << 20)) }
        #expect(wrote == block)

        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.stagedTemporaryFileCount == 1)
        #expect(usage.stagedTemporaryBytes < 1 << 20, "64 MB ではなく、書いた 1 ブロック程度")
        #expect(usage.stagedTemporaryBytes >= block)
        #expect(usage.nestedTemporaryFileCount == 0)
    }
}
