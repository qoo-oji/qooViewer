import Foundation
import Testing

@testable import qooViewer

/// 本を開いたときにメインの外で求めた事実(`MangaBook.sourceFacts`)が、書き込み側まで届くこと(2026-10-11 の規約監査)。
///
/// 事実には**本物と取り違えようのない値**(番兵)を入れる。書き込み側がその場で元ファイルへ問い合わせ直していれば、行には
/// 本物の iノード・ブックマークが入り、番兵は残らない ―― 「メインで問い合わせていない」ことを値で確かめる。
@MainActor
struct BookSourceFactsTests {
    private static let sentinelIdentifier = FileNodeIdentifier(inodeNumber: 424_242, volumeDeviceNumber: 7, volumeUUID: "SENTINEL")
    private static let sentinelBookmark = Data("sentinel-bookmark".utf8)
    private static let sentinelDate = Date(timeIntervalSinceReferenceDate: 12_345)

    private static func withSentinelFacts(_ book: MangaBook) -> MangaBook {
        var book = book
        book.sourceFacts = BookSourceFacts(
            fileNodeIdentifier: sentinelIdentifier, isDirectory: true,
            modificationDate: sentinelDate, fileSize: nil, bookmarkData: sentinelBookmark
        )
        return book
    }

    @Test("ビューアの本は事実を持ったまま(並べ替え・除外を当てて本を組み直しても落とさない)")
    func theViewerKeepsTheFacts() async throws {
        let harness = try ViewerHarness(label: "source-facts-viewer")
        defer { harness.close() }
        let book = Self.withSentinelFacts(try await harness.makeBook(pageCount: 3))
        // レイアウトの行がある本にする(ビューアは本を組み直す ―― ViewerViewModel.prepareBook)。
        harness.library.layouts.setPageLayoutState(for: book, pageKey: book.pages[1].sortKey, state: .excluded)

        let viewer = await harness.open(book)

        #expect(viewer.book.sourceFacts?.fileNodeIdentifier == Self.sentinelIdentifier)
    }

    @Test("ブックマークの行・レイアウトの行は、事実の識別子・ブックマーク・指紋で作る")
    func rowsAreBuiltFromTheFacts() async throws {
        let harness = try ViewerHarness(label: "source-facts-rows")
        defer { harness.close() }
        let book = Self.withSentinelFacts(try await harness.makeBook(pageCount: 3))
        let viewer = await harness.open(book)

        #expect(viewer.addBookmark(atIndex: 1))
        let bookmark = try #require(harness.bookmarks(for: book).first)
        #expect(bookmark.fileNodeIdentifier == Self.sentinelIdentifier)
        #expect(bookmark.bookmarkData == Self.sentinelBookmark)

        harness.library.layouts.setReadingDirectionOverride(for: viewer.book, .leftToRight)
        let settings = try #require(harness.library.layouts.bookLayoutSettings(forBookID: book.id))
        #expect(settings.fileNodeIdentifier == Self.sentinelIdentifier)
        #expect(settings.bookmarkData == Self.sentinelBookmark)
        #expect(settings.recordedSourceModificationDate == Self.sentinelDate)
    }

    @Test("指紋は事実の更新日時・大きさ・フォルダかを使う")
    func theFingerprintComesFromTheFacts() async throws {
        let harness = try ViewerHarness(label: "source-facts-fingerprint")
        defer { harness.close() }
        let book = Self.withSentinelFacts(try await harness.makeBook(pageCount: 2))

        let snapshot = ContentFingerprint.current(for: book)

        #expect(snapshot.modificationDate == Self.sentinelDate)
        #expect(snapshot.isDirectory)
        #expect(snapshot.pageCount == 2)
    }

    @Test("本を開かずに作る行(カバーの指定)は、渡した手がかりで作る")
    func bookLessRowsUseTheGivenAnchors() throws {
        let library = try InMemoryLibrary(label: "source-facts-anchors")
        defer { library.close() }
        let anchors = BookRowAnchors(fileNodeIdentifier: Self.sentinelIdentifier, bookmarkData: Self.sentinelBookmark)

        library.layouts.setCoverCropAnchor(forBookID: "/nowhere/anchored.cbz", anchors: anchors, anchor: .center)

        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: "/nowhere/anchored.cbz"))
        #expect(settings.fileNodeIdentifier == Self.sentinelIdentifier)
        #expect(settings.bookmarkData == Self.sentinelBookmark)
    }
}
