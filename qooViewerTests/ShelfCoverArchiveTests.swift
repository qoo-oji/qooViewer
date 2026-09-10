import CoreGraphics
import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// コレクション表紙のzip書き出し(Services/ShelfCoverArchive.swift)。
///
/// このzipは、利用者が指定した表紙の**唯一の控えになりうる**(元ファイルは失われていることが
/// ある)。なので押さえるのは「中身が本物か」と「取りこぼさないか」:
/// - 出るのは画像を指定した表紙だけ。ページ指定・既定の本は入らない
/// - **バイトが保管庫のものと一致する**(変換しない = 劣化しない)
/// - 同じ名前の本があっても両方入る(連番が付く)
/// - manifestに「どのファイルがどの本か」が入る
/// - 1件読めなくても他は書き出し、飛ばした本を報告する
@MainActor
struct ShelfCoverArchiveTests {
    private func makeImage(_ temporary: TemporaryDirectory, _ name: String, number: UInt8) throws -> URL {
        let url = temporary.file(name)
        try PageImageFactory.png(number: number).write(to: url)
        return url
    }

    /// zipの中身を「ファイル名 → バイト列」で読み戻す。
    private func contents(of zipURL: URL) throws -> [String: Data] {
        let reader = try makeArchiveReader(for: zipURL)
        var result: [String: Data] = [:]
        for path in try reader.listFilePaths() {
            result[path] = try reader.data(at: path)
        }
        return result
    }

    private func manifest(in contents: [String: Data]) throws -> ShelfCoverArchive.Manifest {
        let data = try #require(contents[ShelfCoverArchive.manifestFileName])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ShelfCoverArchive.Manifest.self, from: data)
    }

    @Test("画像を指定した表紙だけが、本の名前で、バイトのまま入る")
    func onlyChosenImagesAreExportedVerbatim() async throws {
        let library = try InMemoryLibrary(label: "cover-zip-basic")
        defer { library.close() }
        let temporary = try TemporaryDirectory("cover-zip-basic")

        // 画像を指定した本(書庫の本 = 拡張子は落ちる)。
        let chosen = try makeImage(temporary, "chosen.png", number: 21)
        try await library.layouts.setShelfCoverImage(
            forBookID: "/books/第1巻.cbz", sourceURL: nil, fileURL: chosen
        )
        // 本の中のページを指定した本(出さない)。
        library.layouts.setShelfCoverPageKey(
            forBookID: "/books/第2巻.cbz", sourceURL: nil, pageKey: "001.png", displayName: "001.png"
        )
        // 何も指定していない本(出さない)。
        library.layouts.setCoverPageKey(
            forBookID: "/books/第3巻.cbz", sourceURL: nil, pageKey: "001.png", displayName: "001.png"
        )

        let entries = library.layouts.shelfCoverArchiveEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.fileName == "第1巻.jpg")

        let zipURL = temporary.file("covers.zip")
        let result = try ShelfCoverArchive.write(entries: entries, to: zipURL)
        #expect(result.written == 1)
        #expect(result.skipped.isEmpty)

        let contents = try contents(of: zipURL)
        #expect(contents.keys.sorted() == ["qooViewer-covers.json", "第1巻.jpg"])

        // 保管庫のファイルとバイト単位で同じ = 変換していない。
        let storedName = try #require(library.layouts.shelfCoverImageFileName(forBookID: "/books/第1巻.cbz"))
        let storedURL = try #require(library.layouts.coverSourceStore.url(forFileName: storedName))
        #expect(contents["第1巻.jpg"] == (try Data(contentsOf: storedURL)))
    }

    @Test("フォルダの本は名前がそのまま、書庫の本は拡張子が落ちる")
    func fileNamesFollowTheBookName() async throws {
        let library = try InMemoryLibrary(label: "cover-zip-names")
        defer { library.close() }
        let temporary = try TemporaryDirectory("cover-zip-names")
        let image = try makeImage(temporary, "a.png", number: 1)

        for bookID in ["/books/フォルダの本", "/books/書庫の本.cbz", "/books/文書.pdf"] {
            try await library.layouts.setShelfCoverImage(
                forBookID: bookID, sourceURL: nil, fileURL: image
            )
        }
        let names = library.layouts.shelfCoverArchiveEntries().map(\.fileName).sorted()
        #expect(names == ["フォルダの本.jpg", "文書.jpg", "書庫の本.jpg"].sorted())
    }

    @Test("別のフォルダにある同じ名前の本は、両方とも入る(連番が付く)")
    func sameNamedBooksBothGetIn() async throws {
        let library = try InMemoryLibrary(label: "cover-zip-collision")
        defer { library.close() }
        let temporary = try TemporaryDirectory("cover-zip-collision")
        let image = try makeImage(temporary, "a.png", number: 1)
        for bookID in ["/A/第1巻.cbz", "/B/第1巻.cbz", "/C/第1巻.cbz"] {
            try await library.layouts.setShelfCoverImage(
                forBookID: bookID, sourceURL: nil, fileURL: image
            )
        }

        let entries = library.layouts.shelfCoverArchiveEntries()
        let zipURL = temporary.file("covers.zip")
        let result = try ShelfCoverArchive.write(entries: entries, to: zipURL)
        #expect(result.written == 3)

        let contents = try contents(of: zipURL)
        #expect(contents.keys.filter { $0 != ShelfCoverArchive.manifestFileName }.sorted()
            == ["第1巻 (2).jpg", "第1巻 (3).jpg", "第1巻.jpg"])

        // 連番はbookIDの順で決まる(書き出すたびに入れ替わらない)。
        let again = library.layouts.shelfCoverArchiveEntries()
        #expect(again.map(\.fileName) == entries.map(\.fileName))
        #expect(entries.first(where: { $0.bookID == "/A/第1巻.cbz" })?.fileName == "第1巻.jpg")
    }

    @Test("manifestに、どのファイルがどの本かが入る")
    func theManifestMapsFilesToBooks() async throws {
        let library = try InMemoryLibrary(label: "cover-zip-manifest")
        defer { library.close() }
        let temporary = try TemporaryDirectory("cover-zip-manifest")
        let image = try makeImage(temporary, "a.png", number: 1)
        try await library.layouts.setShelfCoverImage(
            forBookID: "/books/本.cbz", sourceURL: nil, fileURL: image
        )

        let zipURL = temporary.file("covers.zip")
        _ = try ShelfCoverArchive.write(
            entries: library.layouts.shelfCoverArchiveEntries(), to: zipURL
        )
        let manifest = try manifest(in: try contents(of: zipURL))
        #expect(manifest.version == 1)
        #expect(manifest.items.count == 1)
        #expect(manifest.items.first?.fileName == "本.jpg")
        #expect(manifest.items.first?.bookID == "/books/本.cbz")
    }

    @Test("実体が読めない1件があっても、残りは書き出して飛ばした本を報告する")
    func oneUnreadableEntryDoesNotStopTheRest() async throws {
        let library = try InMemoryLibrary(label: "cover-zip-skip")
        defer { library.close() }
        let temporary = try TemporaryDirectory("cover-zip-skip")
        let image = try makeImage(temporary, "a.png", number: 1)
        try await library.layouts.setShelfCoverImage(
            forBookID: "/books/生きている.cbz", sourceURL: nil, fileURL: image
        )
        try await library.layouts.setShelfCoverImage(
            forBookID: "/books/消えた.cbz", sourceURL: nil, fileURL: image
        )
        // 保管庫の実体だけを消す(行は残る)。
        let lostName = try #require(library.layouts.shelfCoverImageFileName(forBookID: "/books/消えた.cbz"))
        let lostURL = try #require(library.layouts.coverSourceStore.url(forFileName: lostName))
        try FileManager.default.removeItem(at: lostURL)

        let zipURL = temporary.file("covers.zip")
        let result = try ShelfCoverArchive.write(
            entries: library.layouts.shelfCoverArchiveEntries(), to: zipURL
        )
        #expect(result.written == 1)
        #expect(result.skipped == ["/books/消えた.cbz"])

        let contents = try contents(of: zipURL)
        #expect(contents["生きている.jpg"] != nil)
        #expect(contents["消えた.jpg"] == nil)
        // manifestにも、書けなかったぶんは載らない。
        #expect(try manifest(in: contents).items.map(\.bookID) == ["/books/生きている.cbz"])
    }

    @Test("ファイル名に使えない文字と、隠しファイルになる先頭のドットは落とす")
    func fileNamesAreSanitized() {
        var used: Set<String> = []
        #expect(
            ShelfCoverArchive.uniqueFileName(forBaseName: "..hidden", extension: "jpg", used: &used)
                == "hidden.jpg"
        )
        #expect(
            ShelfCoverArchive.uniqueFileName(forBaseName: "a/b", extension: "jpg", used: &used)
                == "ab.jpg"
        )
        // 名前がまるごと落ちても、空のファイル名は作らない。
        #expect(
            ShelfCoverArchive.uniqueFileName(forBaseName: "...", extension: "jpg", used: &used)
                == "book.jpg"
        )
        // 長すぎる名前は切り詰める(ファイルシステムの上限)。
        let long = String(repeating: "あ", count: 300)
        let name = ShelfCoverArchive.uniqueFileName(forBaseName: long, extension: "jpg", used: &used)
        #expect(name.utf8.count <= 255)
    }
}
