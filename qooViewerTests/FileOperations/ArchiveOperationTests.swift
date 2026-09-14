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

    @Test("深い入れ子: PATH_MAX を超えるパスは捨て、上限いっぱいの段数でもスタックを使わずに組み立てる(2 回目の監査)")
    func deepNestingIsBoundedAndIterative() async {
        // 修正前は 3000 段のエントリ 1 つで、Namer の再帰が FileIO のスレッドのスタックを溢れさせてアプリごと落ちた。
        let tooDeep = String(repeating: "a/", count: 3000) + "x.txt"
        #expect(ArchiveExtractionPlan.components(of: tooDeep) == .failure(.nameTooLong))
        // 上限ちょうど(510 段)。FileIO と同じ、スタックの小さい GCD のスレッドの上で組み立てる。
        let depth = (ArchiveExtractionPlan.maxPathBytes - "x.txt".utf8.count) / 2
        let deepest = String(repeating: "a/", count: depth) + "x.txt"
        #expect(deepest.utf8.count <= ArchiveExtractionPlan.maxPathBytes)
        let plan = await FileIO.perform {
            ArchiveExtractionPlan(entries: [
                ArchiveEntryDescriptor(path: tooDeep, kind: .file, uncompressedSize: 1, modified: nil),
                ArchiveEntryDescriptor(path: deepest, kind: .file, uncompressedSize: 1, modified: nil),
                ArchiveEntryDescriptor(path: String(repeating: "A/", count: depth), kind: .directory, uncompressedSize: 0, modified: nil),
            ])
        }
        #expect(plan.rejections.map(\.reason) == [.nameTooLong])
        #expect(plan.items.map(\.relativePath) == [deepest, String(repeating: "a/", count: depth - 1) + "a"])
    }

    @Test("大文字小文字だけ違う名前が大量に並んでも、番号の続きから探すので 2 乗にならず、結果も 2 から数え直したときと同じ(2 回目の監査)")
    func manyCaseCollisionsStayLinear() {
        // 以前は 1 件ごとに 2 から数え直し、4000 件で 2.9 秒(件数の上限を確かめる前)。
        let letters = Array("abcdefghijklmno")
        let entries = (0..<20_000).map { index in
            file(String(letters.enumerated().map { offset, letter in index & (1 << offset) != 0 ? Character(letter.uppercased()) : letter }) + ".txt")
        }
        let started = ContinuousClock.now
        let plan = ArchiveExtractionPlan(entries: entries)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(Set(plan.items.map { FileNameValidation.foldedForComparison($0.relativePath) }).count == entries.count)

        let small = ArchiveExtractionPlan(entries: [file("a.txt"), file("A.txt"), file("a 2.txt"), file("A.TXT")])
        #expect(small.items.map(\.relativePath) == ["a.txt", "A 2.txt", "a 2 2.txt", "A 3.TXT"])
    }

    @Test("書き出さないが読み飛ばすエントリ(__MACOSX・捨てたもの・同じパスの 2 つ目)の宣言サイズも限度に数える(2 回目の監査 21)")
    func skippedEntriesCountTowardLimits() {
        // ソリッドの 7z / rar では、読み飛ばすエントリも伸長される。以前は限度に数えなかったので、捨てられるエントリに伸長爆弾を隠せた。
        let plan = ArchiveExtractionPlan(entries: [
            file("page.jpg", size: 10), file("__MACOSX/._page.jpg", size: 600), file("../evil", size: 300),
            ArchiveEntryDescriptor(path: "link", kind: .symbolicLink, uncompressedSize: 50, modified: nil), file("page.jpg", size: 40),
        ])
        #expect(plan.declaredTotalBytes == 10)
        #expect(plan.skippedDeclaredBytes == 990)
        var limits = ArchiveExtractionLimits()
        limits.maxTotalBytes = 500
        #expect(throws: ArchiveOperationError.self) {
            try plan.checkLimits(limits, archiveSize: 1_000, archive: URL(fileURLWithPath: "/tmp/x.7z"))
        }
        limits.maxTotalBytes = 1_000
        #expect(throws: Never.self) { try plan.checkLimits(limits, archiveSize: 1_000, archive: URL(fileURLWithPath: "/tmp/x.7z")) }
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

    @Test("日時は現地時刻の MS-DOS 形式で書き、読むときも現地時刻に戻す(ZIPFoundation は UTC として扱う)。中の並びは名前順")
    func timestampsAreLocalAndOrderIsStable() async throws {
        let root = try temporary.directory("root")
        let book = try temporary.directory("root/Book")
        for name in ["c.txt", "a.txt", "b.txt"] {
            try Data(name.utf8).write(to: book.appendingPathComponent(name))
        }
        var components = DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 6)
        components.timeZone = .current
        let local = try #require(Calendar(identifier: .gregorian).date(from: components))
        try FileManager.default.setAttributes([.modificationDate: local], ofItemAtPath: book.appendingPathComponent("a.txt").path)

        let zip = try #require(try await compress([book], into: root))

        let archive = try Archive(url: zip, accessMode: .read)
        #expect(archive.map(\.path) == ["Book/", "Book/a.txt", "Book/b.txt", "Book/c.txt"])
        let entry = try #require(archive["Book/a.txt"])
        let reader = try ZipArchiveReader(url: zip)
        #expect(reader.entryDates(at: "Book/a.txt").modified == local)
        #expect(ZipDOSTime.localDate(fromZIPFoundation: entry.fileAttributes[.modificationDate] as? Date) == local)
        // 他のツールと同じ解釈: 書庫に入っている年月日時分秒が現地時刻のものと一致する。
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let raw = try #require(entry.fileAttributes[.modificationDate] as? Date)
        #expect(utc.dateComponents([.hour, .minute], from: raw) == DateComponents(hour: 3, minute: 4))
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

    @Test("中の読めないサブフォルダは黙って飛ばさず、失敗させて一時ファイルも残さない(2 回目の監査)")
    func unreadableSubfolderFailsInsteadOfSkipping() async throws {
        // 以前は FileManager.enumerator(atPath:) が読めないサブフォルダを黙って飛ばし、中身の欠けた zip を成功として作った。
        let root = try temporary.directory("root")
        let book = try temporary.directory("root/Book")
        let closed = try temporary.directory("root/Book/closed")
        try Data("a".utf8).write(to: book.appendingPathComponent("001.jpg"))
        try Data("b".utf8).write(to: closed.appendingPathComponent("002.jpg"))
        #expect(chmod(closed.path, 0o000) == 0)
        defer { chmod(closed.path, 0o755) }

        await #expect {
            _ = try await compress([book], into: root)
        } throws: { error in
            guard case let .posixFailure(item, code) = error as? FileOperationError else { return false }
            return item.lastPathComponent == "closed" && code == EACCES
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["Book"])
    }

    @Test("書き終えた zip の末尾が欠けていたら(ZIPFoundation が握り潰すディスクフル)置く前に失敗にする")
    func verificationRejectsATruncatedArchive() async throws {
        let root = try temporary.directory("root")
        let book = try temporary.directory("root/Book")
        try Data(String(repeating: "qooViewer ", count: 200).utf8).write(to: book.appendingPathComponent("note.txt"))
        let zip = try #require(try await compress([book], into: root))
        let reported = root.appendingPathComponent("Book.zip")
        try ZipCompressor.verifyWrittenArchive(at: zip, expectedEntryCount: 2, reportingAs: reported)
        #expect(hasEndRecord(zip))
        #expect(throws: FileOperationError.posixFailure(item: reported, errnoCode: EIO)) {
            try ZipCompressor.verifyWrittenArchive(at: zip, expectedEntryCount: 3, reportingAs: reported)
        }
        // 最後のセントラルディレクトリと EOCD が書けなかった形(8MB のボリュームで実測した壊れ方)。
        let bytes = try Data(contentsOf: zip)
        try bytes.prefix(bytes.count - 30).write(to: zip)
        // 3 回目の監査: EOCD が無ければ ZIPFoundation に遡らせずに断る(末尾の窓だけを見る)。
        #expect(!hasEndRecord(zip))
        #expect(throws: FileOperationError.posixFailure(item: reported, errnoCode: EIO)) {
            try ZipCompressor.verifyWrittenArchive(at: zip, expectedEntryCount: 2, reportingAs: reported)
        }
    }

    private func hasEndRecord(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        return descriptor >= 0 && ZipCompressor.endOfCentralDirectoryIsPresent(descriptor: descriptor)
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
