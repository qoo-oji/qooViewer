import Foundation
import Testing
import ZIPFoundation

@testable import qooViewer

/// 展開で書く場所の決め方(Services/FileOperations/ArchiveExtractionPlan.swift)。純粋関数なのでファイルに触らない。
struct ArchiveExtractionPlanTests {
    private func file(_ path: String, size: UInt64 = 1) -> ArchiveEntryDescriptor {
        ArchiveEntryDescriptor(path: path, kind: .file, uncompressedSize: size, modified: nil)
    }

    private func directory(_ path: String) -> ArchiveEntryDescriptor {
        ArchiveEntryDescriptor(path: path, kind: .directory, uncompressedSize: 0, modified: nil)
    }

    @Test(
        "外へ出るパス・絶対パス・制御文字・長すぎる名前は捨てる(区切りは / と \\ の両方で見る)",
        arguments: [
            ("../evil.txt", ArchiveEntryRejection.unsafePath),
            ("a/../../b.txt", .unsafePath),
            ("a/..", .unsafePath),
            ("/etc/passwd", .unsafePath),
            ("\\\\server\\x", .unsafePath),
            ("c\\..\\..\\d.txt", .unsafePath),
            ("C:\\Windows\\x.txt", .unsafePath),
            ("d:/x.txt", .unsafePath),
            ("", .unsafePath),
            ("./", .unsafePath),
            ("nul\u{0}.txt", .invalidCharacters),
            ("tab\t.txt", .invalidCharacters),
            (String(repeating: "あ", count: 86) + ".txt", .nameTooLong),
        ]
    )
    func rejectsUnsafePaths(path: String, reason: ArchiveEntryRejection) {
        #expect(ArchiveExtractionPlan.components(of: path) == .failure(reason))
    }

    @Test("使える名前: 空の要素と . は落とす、.. を含むだけの名前は通す、Windows の区切りは名前の一部")
    func acceptsOrdinaryPaths() {
        #expect(ArchiveExtractionPlan.components(of: "./a//b/c.txt") == .success(["a", "b", "c.txt"]))
        #expect(ArchiveExtractionPlan.components(of: "a..b/..c") == .success(["a..b", "..c"]))
        #expect(ArchiveExtractionPlan.components(of: "dir\\file.jpg") == .success(["dir\\file.jpg"]))
        #expect(ArchiveExtractionPlan.components(of: "vol1/") == .success(["vol1"]))
    }

    @Test("__MACOSX と ._ は黙って外し、記号リンクは理由付きで捨てる")
    func skipsAppleDoubleAndSymbolicLinks() {
        let plan = ArchiveExtractionPlan(entries: [
            file("B/001.jpg"), file("__MACOSX/B/._001.jpg"), file("B/._002.jpg"),
            ArchiveEntryDescriptor(path: "B/link", kind: .symbolicLink, uncompressedSize: 5, modified: nil),
        ])
        #expect(plan.items.map(\.relativePath) == ["B/001.jpg"])
        #expect(plan.rejections == [.init(path: "B/link", reason: .symbolicLink)])
        #expect(plan.fileCount == 1)
    }

    @Test("名前の衝突: ファイルは name 2、大文字小文字だけ違うフォルダはまとめる、ファイルと同じ名前のフォルダは name 2")
    func avoidsCollisions() {
        let plan = ArchiveExtractionPlan(entries: [
            file("A.txt"), file("a.txt"), file("Dir/1.txt"), directory("dir/"), file("dir/2.txt"),
            file("x"), file("x/y.txt"), file("Dir/1.txt"), file("e\u{301}.txt"), file("\u{e9}.txt"),
        ])
        // Swift の文字列は正規化違いを同じ値として比べる(reader の索引も同じ鍵になる)ので、NFD と NFC の 2 つ目は「同じパス」として外れる。
        #expect(plan.items.map(\.relativePath) == [
            "A.txt", "a 2.txt", "Dir/1.txt", "Dir", "Dir/2.txt", "x", "x 2/y.txt", "e\u{301}.txt",
        ])
        #expect(plan.fileCount == 7, "まったく同じパスの 2 つ目は数えない")
    }

    @Test("宣言サイズの合計は飽和加算(細工された索引でトラップしない)")
    func declaredTotalSaturates() {
        let plan = ArchiveExtractionPlan(entries: [file("a", size: .max - 1), file("b", size: 10), file("c", size: .max)])
        #expect(plan.declaredTotalBytes == .max)
    }

    @Test("限度: 件数・合計・圧縮比(小さな合計には圧縮比を問わない)")
    func limits() throws {
        let archive = URL(fileURLWithPath: "/tmp/x.zip")
        let plan = ArchiveExtractionPlan(entries: [file("a", size: 600), file("b", size: 600)])
        var limits = ArchiveExtractionLimits(maxTotalBytes: 10_000, maxEntries: 2, maxCompressionRatio: 10, ratioFloorBytes: 1_000)
        try plan.checkLimits(limits, archiveSize: 200, archive: archive)
        #expect(throws: ArchiveOperationError.suspiciousCompressionRatio(archive: archive)) {
            try plan.checkLimits(limits, archiveSize: 100, archive: archive)
        }
        limits.ratioFloorBytes = 2_000
        try plan.checkLimits(limits, archiveSize: 1, archive: archive)
        limits.maxEntries = 1
        #expect(throws: ArchiveOperationError.tooManyEntries(archive: archive, count: 2, limit: 1)) {
            try plan.checkLimits(limits, archiveSize: 1, archive: archive)
        }
        limits.maxEntries = 2
        limits.maxTotalBytes = 1_000
        #expect(throws: ArchiveOperationError.tooLarge(archive: archive, limit: 1_000)) {
            try plan.checkLimits(limits, archiveSize: 1, archive: archive)
        }
    }
}

/// 展開(ArchiveExtractor / FileOperationService.extract)。書庫は ZipFixtureBuilder で組むか、コミットしてあるフィクスチャ。
struct ArchiveExtractorTests {
    private let temporary: TemporaryDirectory
    private let service: FileOperationService

    init() throws {
        temporary = try TemporaryDirectory("extract")
        service = FileOperationService(environment: .pseudoTrash(at: try temporary.directory("PseudoTrash")))
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func extract(
        _ archives: [URL], into folder: URL, placement: ArchiveExtractor.Placement = .contents,
        limits: ArchiveExtractionLimits = .standard, cancellation: Cancellation = Cancellation(), progress: ProgressSink? = nil
    ) async throws -> ArchiveExtractionOutcome {
        try await service.extract(archives, into: folder, placement: placement, limits: limits, progress: progress, cancellation: cancellation)
    }

    @Test("Zip Slip: 外へ出るエントリ・絶対パス・記号リンクは書かず、理由付きで返す。一時フォルダは残らない")
    func zipSlipEntriesAreNeverWritten() async throws {
        var builder = ZipFixtureBuilder()
        builder.add("ok/1.txt", text: "one")
        builder.add("../evil.txt", text: "evil")
        builder.add("/abs.txt", text: "abs")
        builder.add("ok/../../b.txt", text: "b")
        builder.add("c\\..\\..\\d.txt", text: "d")
        builder.add("C:\\win.txt", text: "w")
        builder.add("ctrl\u{1}.txt", text: "c")
        builder.addSymbolicLink("ok/link", target: "../../..")
        builder.add("__MACOSX/ok/._1.txt", text: "meta")
        let archive = temporary.file("slip.zip")
        try builder.write(to: archive)
        let outer = try temporary.directory("outer")
        let destination = try temporary.directory("outer/dest")

        let outcome = try await extract([archive], into: destination)

        #expect(names(in: destination) == ["ok"])
        #expect(names(in: destination.appendingPathComponent("ok")) == ["1.txt"])
        #expect(names(in: outer) == ["dest"], "外に何も書いていない")
        #expect(outcome.rejections.map(\.rejection.path).sorted() == [
            "../evil.txt", "/abs.txt", "C:\\win.txt", "c\\..\\..\\d.txt", "ctrl\u{1}.txt", "ok/../../b.txt", "ok/link",
        ].sorted())
        #expect(outcome.receipts.map(\.destination.lastPathComponent) == ["ok"])
    }

    @Test(
        "コミットしてある書庫を展開すると、reader が読む中身と同じファイルが同じパスにできる(__MACOSX は出ない)",
        arguments: [
            "zip/zip-ditto.cbz", "zip/zip-cp932-noflag.zip", "7z/7z-with-dirs.cb7", "7z/7z-solid.cb7",
            "7z/7z-japanese-names.7z", "rar/rar-with-dirs.cbr", "rar/rar-solid.cbr", "rar/rar-japanese-names.cbr",
        ]
    )
    func extractsFixtures(fixture: String) async throws {
        let source = Fixtures.url(fixture)
        let archive = temporary.file(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: archive)
        let destination = try temporary.directory("dest")

        let outcome = try await extract([archive], into: destination, placement: .ownFolder)

        let folder = try #require(outcome.receipts.first?.destination)
        #expect(folder.lastPathComponent == ArchiveExtractor.folderName(for: archive))
        let reader = try makeArchiveReader(for: archive)
        let expected = try reader.listFilePaths().filter { !isAppleDoubleEntry($0) }
        #expect(!expected.isEmpty)
        for path in expected {
            let written = try Data(contentsOf: folder.appendingPathComponent(path))
            #expect(written == (try reader.data(at: path)), "\(path)")
        }
        #expect(!names(in: folder).contains("__MACOSX"))
        #expect(names(in: destination) == [folder.lastPathComponent], "一時フォルダが残っていない")
    }

    @Test("〈名前〉に展開を 2 回すると name 2、ここに展開で既存と重なった項目は name 2")
    func collisionsAtTheDestinationKeepBoth() async throws {
        var builder = ZipFixtureBuilder()
        builder.add("001.png", text: "new")
        let archive = temporary.file("book.cbz")
        try builder.write(to: archive)
        let destination = try temporary.directory("dest")
        try Data("old".utf8).write(to: destination.appendingPathComponent("001.png"))

        _ = try await extract([archive], into: destination, placement: .ownFolder)
        _ = try await extract([archive], into: destination, placement: .ownFolder)
        let here = try await extract([archive], into: destination, placement: .contents)

        #expect(names(in: destination) == ["001 2.png", "001.png", "book", "book 2"])
        #expect(here.receipts.map(\.destination.lastPathComponent) == ["001 2.png"])
        #expect(try String(contentsOf: destination.appendingPathComponent("001.png"), encoding: .utf8) == "old")
    }

    @Test("暗号化された rar は「パスワードで保護されています」で断り、何も書かない")
    func encryptedRarIsRefused() async throws {
        let archive = Fixtures.url("rar/rar-encrypted.cbr")
        let destination = try temporary.directory("dest")
        await #expect(throws: ArchiveOperationError.encrypted(archive: archive)) {
            _ = try await extract([archive], into: destination)
        }
        #expect(names(in: destination).isEmpty)
    }

    @Test("限度を超える書庫は書き始める前に断る")
    func limitsAreCheckedBeforeWriting() async throws {
        var builder = ZipFixtureBuilder()
        builder.add("zeros.bin", Data(count: 2 * 1024 * 1024))
        builder.add("b.txt", text: "b")
        let archive = temporary.file("bomb.zip")
        try builder.write(to: archive)
        let destination = try temporary.directory("dest")

        let ratio = ArchiveExtractionLimits(maxCompressionRatio: 100, ratioFloorBytes: 1024 * 1024)
        await #expect(throws: ArchiveOperationError.suspiciousCompressionRatio(archive: archive)) {
            _ = try await extract([archive], into: destination, limits: ratio)
        }
        let entries = ArchiveExtractionLimits(maxEntries: 1)
        await #expect(throws: ArchiveOperationError.tooManyEntries(archive: archive, count: 2, limit: 1)) {
            _ = try await extract([archive], into: destination, limits: entries)
        }
        #expect(names(in: destination).isEmpty)
    }

    @Test("途中で中止すると、書きかけの一時フォルダごと消える")
    func cancellingRemovesThePartialExtraction() async throws {
        var builder = ZipFixtureBuilder()
        for index in 1...4 {
            builder.add("\(index).bin", Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ index) }), stored: true)
        }
        let archive = temporary.file("four.zip")
        try builder.write(to: archive)
        let destination = try temporary.directory("dest")
        let cancellation = Cancellation()
        let sink = ProgressSink { progress in
            if progress.completedBytes > 0 { cancellation.request() }
        }

        let outcome = try await extract([archive], into: destination, cancellation: cancellation, progress: sink)

        #expect(outcome.wasCancelled)
        #expect(outcome.receipts.isEmpty)
        #expect(names(in: destination).isEmpty)
    }

    @Test("複数の書庫のうち開けないものがあっても残りは展開し、失敗を並べる")
    func continuesPastABrokenArchive() async throws {
        let good = temporary.file("good.cbz")
        var builder = ZipFixtureBuilder()
        builder.add("1.txt", text: "1")
        try builder.write(to: good)
        let broken = temporary.file("zip-not-a-zip.cbz")
        try FileManager.default.copyItem(at: Fixtures.url("zip/zip-not-a-zip.cbz"), to: broken)
        let destination = try temporary.directory("dest")

        let outcome = try await extract([broken, good], into: destination, placement: .ownFolder)

        #expect(outcome.receipts.map(\.destination.lastPathComponent) == ["good"])
        #expect(outcome.failures.map(\.name) == ["zip-not-a-zip.cbz"])
        #expect(outcome.failures.first?.reason == ArchiveOperationError.unreadable(archive: broken).localizedDescription)
    }
}

/// 圧縮(ZipCompressor / FileOperationService.compress)。
struct ZipCompressorTests {
    private let temporary: TemporaryDirectory
    private let service: FileOperationService

    init() throws {
        temporary = try TemporaryDirectory("compress")
        service = FileOperationService(environment: .pseudoTrash(at: try temporary.directory("PseudoTrash")))
    }

    private func compress(_ items: [URL], into folder: URL, cancellation: Cancellation = Cancellation()) async throws -> URL? {
        try await service.compress(
            items, into: folder, baseName: ZipCompressor.archiveBaseName(for: items), fileExtension: "zip",
            progress: nil, cancellation: cancellation
        )?.destination
    }

    @Test("フォルダはフォルダごと入り、隠しファイルと ._ は入らない。画像は無圧縮、テキストは deflate。展開すると元に戻る")
    func roundTrip() async throws {
        let root = try temporary.directory("root")
        let book = try temporary.directory("root/Book")
        try temporary.directory("root/Book/inner")
        try temporary.directory("root/Book/.hidden")
        let image = Data((0..<5000).map { UInt8($0 % 251) })
        let text = Data(String(repeating: "qooViewer ", count: 500).utf8)
        try image.write(to: book.appendingPathComponent("001.jpg"))
        try text.write(to: book.appendingPathComponent("note.txt"))
        try Data("x".utf8).write(to: book.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: book.appendingPathComponent("._001.jpg"))
        try Data("x".utf8).write(to: book.appendingPathComponent(".hidden/secret.txt"))
        try image.write(to: book.appendingPathComponent("inner/002.png"))

        let zip = try #require(try await compress([book], into: root))

        #expect(zip.lastPathComponent == "Book.zip")
        let archive = try Archive(url: zip, accessMode: .read)
        let entries = Dictionary(uniqueKeysWithValues: archive.map { ($0.path, $0) })
        #expect(Set(entries.keys) == ["Book/", "Book/001.jpg", "Book/note.txt", "Book/inner/", "Book/inner/002.png"])
        #expect(entries["Book/001.jpg"]?.isCompressed == false)
        #expect(entries["Book/note.txt"]?.isCompressed == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted() == ["Book", "Book.zip"])

        let out = try temporary.directory("out")
        _ = try await service.extract([zip], into: out, placement: .contents, progress: nil, cancellation: Cancellation())
        #expect(try Data(contentsOf: out.appendingPathComponent("Book/001.jpg")) == image)
        #expect(try Data(contentsOf: out.appendingPathComponent("Book/note.txt")) == text)
        #expect(try Data(contentsOf: out.appendingPathComponent("Book/inner/002.png")) == image)
    }

    @Test("エントリ名は NFC、汎用フラグ bit 11(UTF-8)が立つ")
    func entryNamesAreNFCWithTheUTF8Flag() async throws {
        let root = try temporary.directory("root")
        let decomposed = "か\u{3099}.txt"
        try Data("a".utf8).write(to: root.appendingPathComponent(decomposed))
        let item = try #require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)

        let zip = try #require(try await compress([item], into: root))

        let archive = try Archive(url: zip, accessMode: .read)
        #expect(archive.map(\.path) == ["\u{304C}.txt"])
        let bytes = try Data(contentsOf: zip)
        let flags = UInt16(bytes[6]) | UInt16(bytes[7]) << 8
        #expect(flags & (1 << 11) != 0)
    }

    @Test("名前: 1 件ならその名前(拡張子ごと)、複数ならフォルダの名前、塞がっていれば name 2")
    func outputNames() async throws {
        let root = try temporary.directory("Shelf")
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        #expect(try await compress([a], into: root)?.lastPathComponent == "a.txt.zip")
        #expect(try await compress([a, b], into: root)?.lastPathComponent == "Shelf.zip")
        #expect(try await compress([a, b], into: root)?.lastPathComponent == "Shelf 2.zip")
    }

    @Test("中止すると一時ファイルは残らない")
    func cancellingLeavesNothing() async throws {
        let root = try temporary.directory("root")
        let file = root.appendingPathComponent("a.bin")
        try Data(count: 1024).write(to: file)
        let cancellation = Cancellation()
        cancellation.request()

        await #expect(throws: CancellationError.self) {
            _ = try await compress([file], into: root, cancellation: cancellation)
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["a.bin"])
    }
}
