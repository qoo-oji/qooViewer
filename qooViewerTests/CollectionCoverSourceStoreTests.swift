import Foundation
import Testing

@testable import qooViewer

/// コレクション表紙の元画像の保管庫(Services/CollectionCoverSourceStore.swift)の掃除。
///
/// ここにあるのは作り直せない絵なので、**参照が無いだけでは消さない**(2026-09-13)。DBの記録の
/// ほうが間違って消えたとき(2026-09-11の事故)に、掃除が最後の1枚まで消していた。
struct CollectionCoverSourceStoreTests {
    private func makeStore(_ label: String) throws -> (CollectionCoverSourceStore, TemporaryDirectory) {
        let temporary = try TemporaryDirectory(label)
        return (CollectionCoverSourceStore(directory: temporary.file("sources")), temporary)
    }

    /// 書いてから時間が経ったことにする(掃除は書いたばかりのファイルを見送る。`recentFileGrace`)。
    private func age(_ fileName: String, in store: CollectionCoverSourceStore) throws {
        let url = try #require(store.url(forFileName: fileName))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * CollectionCoverSourceStore.recentFileGrace)], ofItemAtPath: url.path
        )
    }

    @Test("参照の無い元画像は、消さずに隔離する")
    func orphansAreQuarantinedNotDeleted() throws {
        let (store, temporary) = try makeStore("sources-quarantine")
        defer { withExtendedLifetime(temporary) {} }
        let kept = try store.store(imageData: PageImageFactory.jpeg(number: 1))
        let orphan = try store.store(imageData: PageImageFactory.jpeg(number: 2))
        try age(kept, in: store)
        try age(orphan, in: store)

        store.sweepOrphans(keeping: [kept])

        #expect(store.url(forFileName: kept).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(store.url(forFileName: orphan).map { FileManager.default.fileExists(atPath: $0.path) } == false)
        let quarantined = store.directory
            .appendingPathComponent(CollectionCoverSourceStore.quarantineFolderName)
            .appendingPathComponent(orphan)
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
    }

    @Test("参照が戻れば、隔離から戻す(DBを戻した・修復した)")
    func quarantinedFilesComeBackWhenReferencedAgain() throws {
        let (store, temporary) = try makeStore("sources-restore")
        defer { withExtendedLifetime(temporary) {} }
        let name = try store.store(imageData: PageImageFactory.jpeg(number: 3))
        let original = try Data(contentsOf: try #require(store.url(forFileName: name)))
        try age(name, in: store)

        store.sweepOrphans(keeping: [])
        let quarantined = store.directory
            .appendingPathComponent(CollectionCoverSourceStore.quarantineFolderName)
            .appendingPathComponent(name)
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        store.sweepOrphans(keeping: [name])

        let restored = try #require(store.url(forFileName: name))
        #expect(try Data(contentsOf: restored) == original)
    }

    /// 2026-09-21 の監査の L3。表紙の画像の指定は「保管庫へ書く → 行に名前を書く」の順なので、その間に走った掃除が書いたばかりの
    /// 画像を隔離していた(掃除が起動時だけでなく、ライブラリ機能を初めて ON にした時点でも走るようになってから)。
    @Test("書いたばかりの元画像は、参照がまだ無くても隔離しない")
    func freshlyWrittenFilesAreLeftAlone() throws {
        let (store, temporary) = try makeStore("sources-fresh")
        defer { withExtendedLifetime(temporary) {} }
        let name = try store.store(imageData: PageImageFactory.jpeg(number: 5))

        store.sweepOrphans(keeping: [])

        #expect(store.url(forFileName: name).map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test("隔離から猶予を過ぎたものだけを消す")
    func quarantineIsPurgedAfterTheRetention() throws {
        let (store, temporary) = try makeStore("sources-purge")
        defer { withExtendedLifetime(temporary) {} }
        let name = try store.store(imageData: PageImageFactory.jpeg(number: 4))
        let movedAt = Date(timeIntervalSince1970: 1_000_000)
        let quarantined = store.directory
            .appendingPathComponent(CollectionCoverSourceStore.quarantineFolderName)
            .appendingPathComponent(name)

        store.sweepOrphans(keeping: [], now: movedAt)
        store.sweepOrphans(keeping: [], now: movedAt.addingTimeInterval(CollectionCoverSourceStore.orphanRetention - 60))
        #expect(FileManager.default.fileExists(atPath: quarantined.path))

        store.sweepOrphans(keeping: [], now: movedAt.addingTimeInterval(CollectionCoverSourceStore.orphanRetention + 60))
        #expect(!FileManager.default.fileExists(atPath: quarantined.path))
    }
}
