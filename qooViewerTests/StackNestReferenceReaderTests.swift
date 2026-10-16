import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

@testable import qooViewer

/// 参照ファイルの本を読む reader(StackNestViewerKit の上の薄い ArchiveReading)と、`makeArchiveReader(for:)` での振り分け。
/// reader はブロックするので、試験でも必ず `FileIO.perform` の中で呼ぶ(メインスレッド・`Task` の中から呼ぶと、Debug では
/// 部品が誤りとして止める)。
struct StackNestReferenceReaderTests {
    @Test("一覧は manifest のページ数ぶんの仮の名前(画像の拡張子・名前順 = StackNest の順)")
    func listsSyntheticNames() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        // 正は manifest(参照ファイルの 3 は開いた時点の値)。
        fixture.setPageCount(12)
        let reader = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        let names = try await FileIO.perform { try reader.listFilePaths() }
        #expect(names.count == 12)
        #expect(names.first == "000000.jpg")
        #expect(names.last == "000011.jpg")
        #expect(names.allSatisfy { isImageFile($0) })
        #expect(names.sorted { compareCanonicalPageOrder($0, $1) == .orderedAscending } == names)
    }

    @Test("manifest の読み方向も読む")
    func readsManifestDirection() async throws {
        let fixture = try StackNestTestBook(pageCount: 3, direction: "ltr")
        defer { fixture.close() }
        let reader = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        let manifest = try await FileIO.perform { try reader.manifest() }
        #expect(manifest.pageCount == 3)
        #expect(manifest.direction == .leftToRight)
    }

    @Test("data(at:) は pages/{n} を、鍵と名乗り(kit= 付き)を付けて取り、名前の番号のページを返す")
    func dataFetchesThePage() async throws {
        let fixture = try StackNestTestBook(pageCount: 4)
        defer { fixture.close() }
        let reader = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        let data = try await FileIO.perform { try reader.data(at: "000002.jpg") }
        #expect(PageColorReader.matches(data, number: 3))
        #expect(fixture.pageRequestIndices == [2])
        let request = try #require(fixture.requests.first)
        #expect(request.carriesExpectedToken)
        #expect(request.viewerHeader == StackNestViewerIdentification.forMainBundle(format: 1).headerValue)
        #expect(request.viewerHeader?.contains("; kit=\(StackNestViewerKitInfo.version)") == true)
    }

    @Test("同じページを続けて読んでも、取りに行くのは 1 回(寸法の読み取りと表示で 2 度取らない)")
    func recentPagesAreReused() async throws {
        let fixture = try StackNestTestBook(pageCount: 4)
        defer { fixture.close() }
        let reader = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        let first = try await FileIO.perform { try reader.data(at: "000001.jpg") }
        let prefix = try await FileIO.perform { try reader.dataPrefix(at: "000001.jpg", maxByteCount: 64) }
        let second = try await FileIO.perform { try reader.data(at: "000001.jpg") }
        #expect(first == second)
        #expect(prefix == first)
        #expect(fixture.pageRequestIndices == [1])
    }

    @Test("同じ参照ファイルから作った reader は 1 つのセッションを使い回す(片方が取ったページを、もう片方は取りに行かない)")
    func readersOfOneReferenceShareTheSession() async throws {
        let fixture = try StackNestTestBook(pageCount: 4)
        defer { fixture.close() }
        let first = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        let second = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        #expect(first.book === second.book)
        _ = try await FileIO.perform { try first.data(at: "000003.jpg") }
        _ = try await FileIO.perform { try second.data(at: "000003.jpg") }
        #expect(fixture.pageRequestIndices == [3])
    }

    @Test("仮の名前でないものは、問い合わせずに entryNotFound")
    func unknownEntry() async throws {
        let fixture = try StackNestTestBook()
        defer { fixture.close() }
        let reader = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        await #expect(throws: ArchiveReaderError.entryNotFound) {
            try await FileIO.perform { try reader.data(at: "ComicInfo.xml") }
        }
        #expect(fixture.requests.isEmpty)
        #expect(reader.entryDates(at: "000000.jpg").created == nil)
        #expect(reader.entryUncompressedSize(at: "000000.jpg") == nil)
    }

    @Test("範囲外の番号: 最初の 1 度だけ manifest で範囲を確かめ直し、それでも外ならページは取りに行かない(entryNotFound)")
    func indexBeyondPageCountChecksTheManifestOnce() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let reader = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        await #expect(throws: ArchiveReaderError.entryNotFound) {
            try await FileIO.perform { try reader.data(at: "000003.jpg") }
        }
        #expect(fixture.manifestRequestCount == 1)
        #expect(fixture.pageRequestIndices.isEmpty)
        // 2 度目以降は確かめ直さない(manifest はもう読んだ)。
        await #expect(throws: ArchiveReaderError.entryNotFound) {
            try await FileIO.perform { try reader.data(at: "000999.jpg") }
        }
        #expect(fixture.manifestRequestCount == 1)
        #expect(fixture.pageRequestIndices.isEmpty)
        // 最後のページ(2)は取れる。
        _ = try await FileIO.perform { try reader.data(at: "000002.jpg") }
        #expect(fixture.pageRequestIndices == [2])
    }

    @Test("参照ファイルより後に増えたページは、範囲外の確かめ直しで届く(履歴・Finder から開き直した本)")
    func pagesAddedSinceTheFileWasWrittenAreReached() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        fixture.setPageCount(12)
        let reader = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        let data = try await FileIO.perform { try reader.data(at: "000009.jpg") }
        #expect(PageColorReader.matches(data, number: 10))
        #expect(fixture.manifestRequestCount == 1)
        #expect(fixture.pageRequestIndices == [9])
        // 範囲の外(12)は、確かめ直し済みなので問い合わせない。
        await #expect(throws: ArchiveReaderError.entryNotFound) {
            try await FileIO.perform { try reader.data(at: "000012.jpg") }
        }
        #expect(fixture.manifestRequestCount == 1)
        #expect(fixture.pageRequestIndices == [9])
    }

    @Test("拡張子の判定は大文字小文字を区別しない")
    func recognizesTheExtension() {
        #expect(isStackNestReferenceFile("Book.stacknestbook"))
        #expect(isStackNestReferenceFile("/a/b/Book.STACKNESTBOOK"))
        #expect(!isStackNestReferenceFile("Book.json"))
        #expect(!isStackNestReferenceFile("stacknestbook"))
    }

    @Test("makeArchiveReader(for:) は参照ファイルに StackNestReferenceReader を返す(作るだけでは通信しない)")
    func dispatch() throws {
        let fixture = try StackNestTestBook()
        defer { fixture.close() }
        let reader = try makeArchiveReader(for: fixture.referenceURL)
        #expect(reader is StackNestReferenceReader)
        #expect(reader is any RemoteArchiveReading)
        #expect(fixture.requests.isEmpty)
    }

    @Test("壊れた参照ファイルは、reader を作る時点で失敗する")
    func brokenReferenceFailsToOpen() throws {
        let folder = try TemporaryDirectory("stacknest-broken")
        let url = folder.file("Broken.stacknestbook")
        try Data("{}".utf8).write(to: url)
        #expect(throws: StackNestViewerError(.invalidReference)) { _ = try makeArchiveReader(for: url) }
    }

    @Test("参照ファイルは書庫ではない: 書庫の分類・書庫の拡張子・展開のどれにも入らない")
    func notALocalArchive() {
        #expect(archiveKind(forFileName: "Book.stacknestbook") == nil)
        #expect(!isArchiveFile("Book.stacknestbook"))
        func entry(_ name: String) -> FileBrowserEntry {
            FileBrowserEntry(
                url: URL(fileURLWithPath: "/tmp/\(name)"), displayName: name, isDirectory: false, isPackage: false,
                isSymbolicLink: false, isVolume: false, fileSize: 300, typeDescription: nil, creationDate: nil,
                modificationDate: nil
            )
        }
        #expect(!entry("Book.stacknestbook").isExtractableArchive)
        #expect(entry("Book.cbz").isExtractableArchive)
    }

    @Test("書庫の中の参照ファイルは、ページにも入れ子の書庫にもならない(中の鍵で要求を出さない)")
    func referenceInsideAnArchiveIsIgnored() async throws {
        let fixture = try StackNestTestBook()
        defer { fixture.close() }
        var zip = ZipFixtureBuilder()
        zip.add("001.png", PageImageFactory.png(number: 1))
        zip.add("inner.stacknestbook", try Data(contentsOf: fixture.referenceURL))
        let zipURL = fixture.temporary.file("with-reference.cbz")
        try zip.write(to: zipURL)

        let book = try await FixtureBook.load(zipURL)
        #expect(book.pages.map(\.sortKey) == ["001.png"])

        let resolver = NestedArchiveResolver(limits: .standard(inMemoryBytes: 64 * 1024 * 1024))
        #expect(throws: ArchiveReaderError.cannotOpen) {
            _ = try resolver.open(ArchiveLocator(rootURL: zipURL, nestedPath: ["inner.stacknestbook"]))
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test("取り消しは FileIO の旗として部品の読み出しへ届く(応答の止まったページを待っていても、取り消すと数秒以内に CancellationError)")
    func cancellationReachesThePageRead() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let reader = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        let gate = fixture.holdPage(0)
        // 取り消しが届かなくても、試験自体は止まらないよう、最後に必ず流す。
        defer { gate.open() }
        let read = Task { try await FileIO.perform { try reader.data(at: "000000.jpg") } }
        // 要求が見立てに届いた(= 読み出しが応答待ちに入った)まで待つ。
        #expect(await FileIO.perform { gate.waitForArrival() })
        read.cancel()
        var cancelled = false
        do {
            // 応答は止めたまま。取り消しが読み出しに届いていれば、ここで CancellationError になる。
            _ = try await FileIO.withDeadline(.seconds(2)) { try await read.value }
        } catch is CancellationError {
            cancelled = true
        } catch {
            Issue.record("CancellationError ではなく \(error)")
        }
        #expect(cancelled, "取り消しが部品の読み出しへ届かず、応答を待ち続けた")
    }
}
