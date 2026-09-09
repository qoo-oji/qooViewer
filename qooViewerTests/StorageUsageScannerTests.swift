import Foundation
import Testing

@testable import qooViewer

/// コンテナの容量の走査(Services/StorageUsageScanner.swift)。
///
/// 実物のコンテナは**共有の保存先**なので触らない ―― 作業フォルダの中に同じ形の木を作り、
/// `Locations` でそこを指す。見たいのは内訳の切り分け方そのもの:
/// 「無い」と「空」を区別すること、シンボリックリンクを数えないこと、
/// 名前の付いた内訳を引いた残りが「その他」になること。
struct StorageUsageScannerTests {
    /// コンテナに見立てた木。バイト数はファイルの中身の長さそのもの。
    private struct Container {
        let temporary: TemporaryDirectory
        let root: URL
        let sessionTemporary: URL
        let temporaryRoot: URL
        let thumbnailCache: URL
        let pageListCache: URL
        let collectionCovers: URL
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
            databaseStore = root.appendingPathComponent("Library/Application Support/default.store")
        }

        var locations: StorageUsageScanner.Locations {
            .init(
                containerRoot: root, sessionTemporaryDirectory: sessionTemporary,
                temporaryRoot: temporaryRoot, thumbnailCacheDirectory: thumbnailCache,
                pageListCacheDirectory: pageListCache, collectionCoverDirectory: collectionCovers,
                databaseStoreURL: databaseStore
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
        // この起動の一時ファイル(入れ子の書庫の展開物)。
        try container.write("tmp/qooViewer-\(ProcessInfo.processInfo.processIdentifier)/inner.cbz", bytes: 100)
        // もう生きていない起動が残したセッションフォルダ。
        try container.write("tmp/qooViewer-\(deadPID)/inner.cbz", bytes: 50)
        // セッションフォルダを導入する前の版が残した `<UUID>.<書庫拡張子>`。
        try container.write("tmp/\(UUID().uuidString).cbz", bytes: 30)
        try container.write("Library/Caches/thumbnails/a.bin", bytes: 200)
        try container.write("Library/Caches/pagelist/a.json", bytes: 40)
        try container.write("Library/Application Support/CollectionCovers/a.jpg", bytes: 90)
        try container.write("Library/Application Support/default.store", bytes: 500)
        try container.write("Library/Application Support/default.store-wal", bytes: 60)
        try container.write("Library/Application Support/default.store-shm", bytes: 20)
        // どの内訳にも属さないもの(= その他)。
        try container.write("Library/Preferences/plist.dat", bytes: 7)
        return container
    }

    @Test("内訳が切り分けられ、名前の付いたぶんを引いた残りが「その他」になる")
    func theBreakdownAddsUpToTheContainer() throws {
        let container = try fullContainer(label: "storage-full")
        let usage = try #require(StorageUsageScanner.scan(container.locations))

        #expect(usage.sessionTemporaryBytes == 100)
        #expect(usage.sessionTemporaryFileCount == 1)
        #expect(usage.staleTemporaryBytes == 80)     // 50(死んだセッション)+ 30(旧形式)
        #expect(usage.staleTemporaryEntryCount == 2)
        #expect(usage.thumbnailCacheBytes == 200)
        #expect(usage.pageListCacheBytes == 40)
        #expect(usage.collectionCoverBytes == 90)
        #expect(usage.databaseBytes == 580)          // 500 + wal 60 + shm 20
        #expect(usage.containerBytes == 1097)
        #expect(usage.otherBytes == 7)
    }

    @Test("生きている起動のセッションフォルダは残骸ではない")
    func aLiveSessionDirectoryIsNotStale() throws {
        let container = try Container(label: "storage-live")
        try container.write("tmp/qooViewer-\(ProcessInfo.processInfo.processIdentifier)/inner.cbz", bytes: 10)
        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.staleTemporaryEntryCount == 0)
        #expect(usage.staleTemporaryBytes == 0)
        #expect(usage.sessionTemporaryBytes == 10)
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
        try container.write("Library/Application Support/default.store-wal", bytes: 60)
        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.databaseBytes == nil)
    }

    @Test("WAL/SHM が無いのは普通(あるぶんだけ足す)")
    func theDatabaseSumsOnlyTheFilesThatExist() throws {
        let container = try Container(label: "storage-store-only")
        try container.write("Library/Application Support/default.store", bytes: 500)
        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.databaseBytes == 500)
        try container.write("Library/Application Support/default.store-shm", bytes: 20)
        #expect(StorageUsageScanner.scan(container.locations)?.databaseBytes == 520)
    }

    @Test("シンボリックリンクは辿らず、リンク自身のサイズも数えない")
    func symbolicLinksAreExcluded() throws {
        let container = try Container(label: "storage-symlink")
        try container.write("Library/real.dat", bytes: 100)

        // コンテナの外を指すリンク(実機では Application Support/ に OS が置く AddressBook 等)。
        let outside = container.temporary.file("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 9999).write(to: outside.appendingPathComponent("big.dat"))
        try FileManager.default.createSymbolicLink(
            at: container.root.appendingPathComponent("Library/AddressBook"), withDestinationURL: outside)

        let usage = try #require(StorageUsageScanner.scan(container.locations))
        #expect(usage.containerBytes == 100)
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
        let usage = StorageUsage(
            containerBytes: 100, sessionTemporaryBytes: 0, sessionTemporaryFileCount: 0,
            staleTemporaryBytes: 0, staleTemporaryEntryCount: 0, thumbnailCacheBytes: 5000,
            pageListCacheBytes: nil, collectionCoverBytes: nil, databaseBytes: nil,
            scannedAt: Date())
        #expect(usage.otherBytes == 0)
    }
}
