import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import qooViewer

/// zipからコレクション表紙を読み込む経路
/// (Services/ImageIntegrityCheck.swift・Services/ShelfCoverArchive.swift・
/// ViewModels/ShelfCoverImportViewModel.swift)。
///
/// この経路には**外から持ち込まれたバイト列**が流れ込む。押さえるのは2つ:
/// - 細工されたファイルを取り込まないこと(終端の後ろに別データ・複数フレーム・偽の形式)
/// - 検査に通ったものは**焼き直さずに**入ること(往復で画質が落ちない)
@MainActor
struct ShelfCoverImportTests {
    private var maxPixelSize: CGFloat { CollectionCoverSourceStore.maxPixelSize }

    // MARK: - 検査

    @Test("上限内のJPEG・PNGは、そのまま持ってよいと判定される")
    func smallJPEGAndPNGPassVerbatim() {
        #expect(
            ImageIntegrityCheck.inspect(PageImageFactory.jpeg(number: 1), maxPixelSize: maxPixelSize)
                == .verbatim(fileExtension: "jpg")
        )
        #expect(
            ImageIntegrityCheck.inspect(PageImageFactory.png(number: 1), maxPixelSize: maxPixelSize)
                == .verbatim(fileExtension: "png")
        )
    }

    @Test("画像の終端より後ろにデータが続いていたら取り込まない")
    func trailingDataIsRejected() {
        // 「画像 + 後ろに別のファイル」は復号側が黙って無視するので、復号できたことだけでは
        // 気づけない ―― 終端の位置を直接見て弾く(ImageIntegrityCheckの型コメント参照)。
        var jpeg = PageImageFactory.jpeg(number: 1)
        jpeg.append(contentsOf: Array("PK\u{03}\u{04}hidden payload".utf8))
        #expect(ImageIntegrityCheck.inspect(jpeg, maxPixelSize: maxPixelSize) == .rejected(.trailingData))

        var png = PageImageFactory.png(number: 1)
        png.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        #expect(ImageIntegrityCheck.inspect(png, maxPixelSize: maxPixelSize) == .rejected(.trailingData))
    }

    @Test("画像として読めないものは取り込まない")
    func nonImagesAreRejected() {
        let notAnImage = Data("<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        #expect(ImageIntegrityCheck.inspect(notAnImage, maxPixelSize: maxPixelSize) == .rejected(.unreadable))
        #expect(ImageIntegrityCheck.inspect(Data(), maxPixelSize: maxPixelSize) == .rejected(.unreadable))
    }

    @Test("フレームが複数あるファイルは取り込まない")
    func multiFrameFilesAreRejected() throws {
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 2, nil)
        )
        CGImageDestinationAddImage(destination, PageImageFactory.cgImage(number: 1), nil)
        CGImageDestinationAddImage(destination, PageImageFactory.cgImage(number: 2), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(
            ImageIntegrityCheck.inspect(output as Data, maxPixelSize: maxPixelSize)
                == .rejected(.multipleFrames)
        )
    }

    @Test("終端を確かめられない形式と、上限より大きい画像は焼き直す")
    func unverifiableOrOversizedImagesAreReencoded() throws {
        // 単一フレームのTIFF(JPEG/PNG以外)。
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, PageImageFactory.cgImage(number: 1), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(
            ImageIntegrityCheck.inspect(output as Data, maxPixelSize: maxPixelSize)
                == .reencode(.formatNotVerifiable)
        )

        // 上限より大きいJPEG。ヘッダーの寸法だけで振り分けるので、全復号までは進まない。
        #expect(
            ImageIntegrityCheck.inspect(PageImageFactory.jpeg(number: 1), maxPixelSize: 4)
                == .reencode(.tooLarge)
        )
    }

    // MARK: - zipの読み出し

    /// 表紙を1件持つライブラリを作り、そのzipを書き出して返す。
    private func makeLibraryWithCovers(
        _ label: String, books: [String], temporary: TemporaryDirectory
    ) async throws -> (InMemoryLibrary, URL) {
        let library = try InMemoryLibrary(label: label)
        let image = temporary.file("\(label)-source.png")
        try PageImageFactory.png(number: 12).write(to: image)
        for bookID in books {
            try await library.layouts.setShelfCoverImage(
                forBookID: bookID, sourceURL: nil, fileURL: image
            )
        }
        let zipURL = temporary.file("\(label).zip")
        _ = try ShelfCoverArchive.write(
            entries: library.layouts.shelfCoverArchiveEntries(), to: zipURL
        )
        return (library, zipURL)
    }

    @Test("自分で書き出したzipは、manifestで本と結び付き、バイトのまま戻る")
    func aRoundTripKeepsTheExactBytes() async throws {
        let temporary = try TemporaryDirectory("cover-import-roundtrip")
        let (library, zipURL) = try await makeLibraryWithCovers(
            "cover-import-roundtrip", books: ["/books/第1巻.cbz"], temporary: temporary
        )
        defer { library.close() }
        // 表紙を消したあともこの本を「知っている」状態にしておく(照合の母体に残す)。
        _ = library.metadata.upsert(
            bookID: "/books/第1巻.cbz", author: "", title: "第1巻", series: "", seriesIndex: ""
        )
        let suite = PreferencesSuite(label: "cover-import-roundtrip")
        defer { withExtendedLifetime(suite) {} }

        // 書き出したバイト列を控えてから、表紙を消す(取り込みで戻ることを確かめるため)。
        let exported = try #require(
            try ShelfCoverArchive.read(zipAt: zipURL, maxPixelSize: maxPixelSize).entries.first
        )
        #expect(exported.verdict == .verbatim(fileExtension: "jpg"))
        #expect(exported.bookIDFromManifest == "/books/第1巻.cbz")
        library.layouts.clearShelfCover(forBookID: "/books/第1巻.cbz")

        let viewModel = ShelfCoverImportViewModel(
            sources: library.knownBookSources, preferences: suite.makePreferences()
        )
        await viewModel.load(zipAt: zipURL)
        #expect(viewModel.rows.count == 1)
        #expect(viewModel.rows.first?.selectedBookID == "/books/第1巻.cbz")
        #expect(viewModel.rows.first?.isFromManifest == true)
        #expect(viewModel.importableCount == 1)

        await viewModel.apply()

        let storedName = try #require(library.layouts.shelfCoverImageFileName(forBookID: "/books/第1巻.cbz"))
        let storedURL = try #require(library.layouts.coverSourceStore.url(forFileName: storedName))
        // **焼き直していない**(zipの中身とバイト単位で同じ)。
        let exportedData = try #require(
            try ShelfCoverArchive.readEntries(zipAt: zipURL, paths: [exported.path])[exported.path]
        )
        #expect(try Data(contentsOf: storedURL) == exportedData)
    }

    @Test("同じzipをもう一度読み込んでも、表紙は焼き直されない")
    func reimportingTheSameZipChangesNothing() async throws {
        let temporary = try TemporaryDirectory("cover-import-idempotent")
        let (library, zipURL) = try await makeLibraryWithCovers(
            "cover-import-idempotent", books: ["/books/第1巻.cbz"], temporary: temporary
        )
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-import-idempotent")
        defer { withExtendedLifetime(suite) {} }
        _ = library.metadata.upsert(
            bookID: "/books/第1巻.cbz", author: "", title: "第1巻", series: "", seriesIndex: ""
        )

        let before = try #require(library.layouts.shelfCoverImageFileName(forBookID: "/books/第1巻.cbz"))
        let viewModel = ShelfCoverImportViewModel(
            sources: library.knownBookSources, preferences: suite.makePreferences()
        )
        await viewModel.load(zipAt: zipURL)
        await viewModel.apply()

        // 保存名が変わらない = 入れ替えていない = 表示用の絵も焼き直されない。
        #expect(library.layouts.shelfCoverImageFileName(forBookID: "/books/第1巻.cbz") == before)
    }

    @Test("manifestに無いエントリは、ファイル名で本と結び付く")
    func entriesWithoutAManifestMatchByFileName() async throws {
        let library = try InMemoryLibrary(label: "cover-import-byname")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-import-byname")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-import-byname")

        // この本を知っている状態にする(読書位置でも履歴でもよいが、ここはメタデータで)。
        _ = library.metadata.upsert(bookID: "/books/第1巻.cbz", author: "", title: "第1巻", series: "", seriesIndex: "")

        // 手で作ったzip(manifestなし)。フォルダに入った名前も受け取れることを一緒に確かめる。
        var builder = ZipFixtureBuilder()
        builder.add("表紙/第1巻.jpg", PageImageFactory.jpeg(number: 3))
        builder.add("__MACOSX/._第1巻.jpg", Data([0, 1, 2, 3]))
        let zipURL = temporary.file("hand-made.zip")
        try builder.write(to: zipURL)

        let viewModel = ShelfCoverImportViewModel(
            sources: library.knownBookSources, preferences: suite.makePreferences()
        )
        await viewModel.load(zipAt: zipURL)

        // Finderの残骸は一覧に出さない。
        #expect(viewModel.rows.count == 1)
        let row = try #require(viewModel.rows.first)
        #expect(row.entryName == "第1巻.jpg")
        #expect(row.selectedBookID == "/books/第1巻.cbz")
        #expect(row.isFromManifest == false)

        await viewModel.apply()
        #expect(library.layouts.shelfCoverImageFileName(forBookID: "/books/第1巻.cbz") != nil)
    }

    @Test("同じ名前の本が複数あるときは、選ばれていない状態で出す")
    func ambiguousMatchesAreLeftUnselected() async throws {
        let library = try InMemoryLibrary(label: "cover-import-ambiguous")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-import-ambiguous")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-import-ambiguous")
        for bookID in ["/A/第1巻.cbz", "/B/第1巻.cbz"] {
            _ = library.metadata.upsert(bookID: bookID, author: "", title: "第1巻", series: "", seriesIndex: "")
        }

        var builder = ZipFixtureBuilder()
        builder.add("第1巻.jpg", PageImageFactory.jpeg(number: 3))
        let zipURL = temporary.file("ambiguous.zip")
        try builder.write(to: zipURL)

        let viewModel = ShelfCoverImportViewModel(
            sources: library.knownBookSources, preferences: suite.makePreferences()
        )
        await viewModel.load(zipAt: zipURL)
        let row = try #require(viewModel.rows.first)
        #expect(row.candidates.sorted() == ["/A/第1巻.cbz", "/B/第1巻.cbz"])
        #expect(row.selectedBookID == nil)
        #expect(viewModel.importableCount == 0)

        // 「すべて選択」でも、曖昧な行は勝手に選ばない。
        viewModel.setAllSelected(true)
        #expect(viewModel.rows.first?.selectedBookID == nil)

        // 利用者が選べば取り込める。
        viewModel.setSelection("/B/第1巻.cbz", for: row.id)
        #expect(viewModel.importableCount == 1)
        await viewModel.apply()
        #expect(library.layouts.shelfCoverImageFileName(forBookID: "/B/第1巻.cbz") != nil)
        #expect(library.layouts.shelfCoverImageFileName(forBookID: "/A/第1巻.cbz") == nil)
    }

    @Test("一致する本が無い画像と、細工された画像は取り込まない")
    func unmatchedAndTamperedEntriesAreNotImported() async throws {
        let library = try InMemoryLibrary(label: "cover-import-reject")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-import-reject")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-import-reject")
        _ = library.metadata.upsert(bookID: "/books/細工.cbz", author: "", title: "細工", series: "", seriesIndex: "")

        var tampered = PageImageFactory.jpeg(number: 3)
        tampered.append(contentsOf: Array("PK\u{03}\u{04}".utf8))
        var builder = ZipFixtureBuilder()
        builder.add("知らない本.jpg", PageImageFactory.jpeg(number: 3))
        builder.add("細工.jpg", tampered)
        let zipURL = temporary.file("reject.zip")
        try builder.write(to: zipURL)

        let viewModel = ShelfCoverImportViewModel(
            sources: library.knownBookSources, preferences: suite.makePreferences()
        )
        await viewModel.load(zipAt: zipURL)
        #expect(viewModel.rows.count == 2)
        #expect(viewModel.importableCount == 0)

        let unknown = try #require(viewModel.rows.first { $0.entryName == "知らない本.jpg" })
        #expect(unknown.candidates.isEmpty)

        // 細工されたほうは、本が一致していても取り込めない。
        let tamperedRow = try #require(viewModel.rows.first { $0.entryName == "細工.jpg" })
        #expect(tamperedRow.candidates == ["/books/細工.cbz"])
        #expect(tamperedRow.isImportable == false)

        await viewModel.apply()
        #expect(library.layouts.shelfCoverImageFileName(forBookID: "/books/細工.cbz") == nil)
    }

    // MARK: - 開き直し(2026-10-04 の監査 TW-22)

    @Test("読み込んだ後で本が動いていたら、その行は古いパスへ取り込まない。閉じたら読み込んだzipと一覧を捨てる")
    func staleTargetsAreSkippedAndClosingForgetsTheZip() async throws {
        let library = try InMemoryLibrary(label: "cover-import-reopen")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-import-reopen")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-import-reopen")
        _ = library.metadata.upsert(bookID: "/books/第1巻.cbz", author: "", title: "第1巻", series: "", seriesIndex: "")

        var builder = ZipFixtureBuilder()
        builder.add("第1巻.jpg", PageImageFactory.jpeg(number: 3))
        let zipURL = temporary.file("reopen.zip")
        try builder.write(to: zipURL)

        let viewModel = ShelfCoverImportViewModel(
            sources: library.knownBookSources, preferences: suite.makePreferences()
        )
        await viewModel.load(zipAt: zipURL)
        #expect(viewModel.rows.first?.selectedBookID == "/books/第1巻.cbz")

        // 読み込んだ後で本が動いた(保存データは新しいパスへ付け替わった)。
        library.metadata.delete(forBookID: "/books/第1巻.cbz")
        _ = library.metadata.upsert(bookID: "/moved/第1巻.cbz", author: "", title: "第1巻", series: "", seriesIndex: "")
        await viewModel.apply()
        // 以前は古いパスに表紙だけの行を新しく作った。
        #expect(library.layouts.bookLayoutSettings(forBookID: "/books/第1巻.cbz") == nil)
        #expect(viewModel.didSucceed == false)

        // 閉じたら捨て、開き直しても前回の一覧は出ない。
        viewModel.setPresented(false)
        #expect(viewModel.rows.isEmpty)
        #expect(viewModel.loadedFileName == nil)
        #expect(viewModel.resultMessage == nil)
        viewModel.setPresented(true)
        #expect(viewModel.rows.isEmpty)
    }

    /// シークレットフォルダの一覧の箱(閉包が捕まえた後で中身を差し替える)。
    @MainActor
    private final class SecretFolders {
        var folders: [String]
        init(_ folders: [String]) { self.folders = folders }
    }

    @Test("シークレットフォルダの本は候補に出さず、読み込んだ後でシークレットにした本にも表紙を書かない(2026-10-04 の監査 TW-13)")
    func secretFolderBooksGetNoCover() async throws {
        let library = try InMemoryLibrary(label: "cover-import-secret")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-import-secret")
        defer { withExtendedLifetime(suite) {} }
        let temporary = try TemporaryDirectory("cover-import-secret")
        _ = library.metadata.upsert(bookID: "/架空/秘密/第1巻.cbz", author: "", title: "第1巻", series: "", seriesIndex: "")
        _ = library.metadata.upsert(bookID: "/架空/棚/第2巻.cbz", author: "", title: "第2巻", series: "", seriesIndex: "")

        var builder = ZipFixtureBuilder()
        builder.add("第1巻.jpg", PageImageFactory.jpeg(number: 1))
        builder.add("第2巻.jpg", PageImageFactory.jpeg(number: 2))
        let zipURL = temporary.file("secret.zip")
        try builder.write(to: zipURL)

        // 一覧はテストが持つ(アプリの一覧 ―― 共有の状態 ―― には触れない)。
        let secret = SecretFolders(["/架空/秘密"])
        let viewModel = ShelfCoverImportViewModel(
            sources: library.knownBookSources, preferences: suite.makePreferences(),
            secretFolders: { SecretFolderStore.Matcher(secret.folders) }
        )
        await viewModel.load(zipAt: zipURL)
        #expect(viewModel.rows.first { $0.entryName == "第1巻.jpg" }?.candidates.isEmpty == true)
        #expect(viewModel.rows.first { $0.entryName == "第2巻.jpg" }?.selectedBookID == "/架空/棚/第2巻.cbz")

        // 読み込んだ後でシークレットにした。
        secret.folders.append("/架空/棚")
        await viewModel.apply()
        #expect(library.layouts.shelfCoverImageFileName(forBookID: "/架空/棚/第2巻.cbz") == nil)
        #expect(library.layouts.bookLayoutSettings(forBookID: "/架空/秘密/第1巻.cbz") == nil)
        #expect(viewModel.didSucceed == false)
    }

    @Test("表紙の書き出しを閉じて開き直すと、閉じている間に設定した表紙も一覧に入り、既定どおり全部選ばれる(2026-10-04 の監査 TW-10)")
    func reopeningTheExportListsCoversSetWhileClosed() async throws {
        let temporary = try TemporaryDirectory("cover-export-reopen")
        let (library, _) = try await makeLibraryWithCovers(
            "cover-export-reopen", books: ["/books/第1巻.cbz"], temporary: temporary
        )
        defer { library.close() }
        let suite = PreferencesSuite(label: "cover-export-reopen")
        defer { withExtendedLifetime(suite) {} }

        let viewModel = ShelfCoverExportViewModel(layoutStore: library.layouts, preferences: suite.makePreferences())
        #expect(viewModel.rows.map(\.bookID) == ["/books/第1巻.cbz"])

        viewModel.setPresented(false)
        let image = temporary.file("cover-export-reopen-source.png")
        try await library.layouts.setShelfCoverImage(forBookID: "/books/第2巻.cbz", sourceURL: nil, fileURL: image)
        viewModel.setPresented(true)

        // 以前は最初に開いたときの一覧のままで、新しい表紙は zip に入らなかった。
        #expect(viewModel.rows.map(\.bookID) == ["/books/第1巻.cbz", "/books/第2巻.cbz"])
        #expect(viewModel.selectedBookIDs == ["/books/第1巻.cbz", "/books/第2巻.cbz"])
    }
}
