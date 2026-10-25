import Foundation
import Testing

@testable import qooViewer

/// 2026-10-25 のハング・クラッシュの監査で直したところを固定する(番号は監査の報告のもの)。
///
/// 落ちる直しは「落ちずに答える」こと、止まる直しは「同じ答えを、止まらない形で返す」ことを見る。**時間は測らない**
/// (docs/02「テストの待ち方」)―― 遅い実装に戻っても答えが同じなら通るが、選ばれる reader の型・答えの一致で戻りを捕まえる。
struct HangCrashAuditTests {

    // MARK: - #1・#6 zip はローカルでも中央ディレクトリの reader

    @Test("ローカルの zip は CentralDirectoryZipReader で開き、ZIPFoundation と同じ一覧を返す(#1・#6)")
    func localZipUsesTheCentralDirectoryReader() throws {
        let url = Fixtures.url("zip/zip-zipcli.cbz")
        let reader = try makeArchiveReader(for: url)
        #expect(reader is CentralDirectoryZipReader)
        #expect(try reader.listFilePaths().sorted() == (try ZipArchiveReader(url: url).listFilePaths().sorted()))
    }

    @Test("入れ子の zip(メモリ上)も CentralDirectoryZipReader で開く(#6)")
    func nestedZipUsesTheCentralDirectoryReader() throws {
        let url = Fixtures.url("zip/zip-zipcli.cbz")
        let data = try Data(contentsOf: url)
        let reader = try makeArchiveReader(kind: .zip, data: data)
        #expect(reader is CentralDirectoryZipReader)
        let paths = try reader.listFilePaths().sorted()
        #expect(paths == (try ZipArchiveReader(url: url).listFilePaths().sorted()))
        // 中身も同じバイト列。
        let first = try #require(paths.first)
        #expect(try reader.data(at: first) == (try ZipArchiveReader(url: url).data(at: first)))
    }

    @Test("終端レコードの無い .cbz は、ファイル全体を遡らずに断る(#1)")
    func zipWithoutEndRecordIsRefused() throws {
        let folder = try TemporaryDirectory("audit-no-eocd")
        // 中身が zip でないファイル(RAR の中身の .cbz と同じ形)。末尾の 64KB より前に署名を置いても拾わない。
        var bytes = Data(repeating: 0x41, count: 2 * 1024 * 1024)
        bytes.replaceSubrange(10..<14, with: [0x50, 0x4B, 0x05, 0x06])
        let url = folder.file("not-a-zip.cbz")
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { _ = try makeArchiveReader(for: url) }
    }

    // MARK: - #2 自動配置の起点

    @Test("起点の 2 ページが同じ鍵でも落ちない(#2)")
    func anchorWithTheSameKeyTwiceDoesNotTrap() {
        let keys = ["a.zip/001.jpg", "a.zip/001.jpg", "a.zip/002.jpg", "a.zip/003.jpg"]
        let result = LayoutAutoCalculator.recalculate(
            orderedPageKeys: keys, anchor: .init(pageKeys: ["a.zip/001.jpg", "a.zip/001.jpg"]), scope: .wholeBook,
            isWideImage: { _ in false }, isRightToLeft: true
        )
        // 同じ鍵へは後の書き込み(2 番目に読むページの位置)が残る。
        #expect(result["a.zip/001.jpg"] == .spreadLeft)
    }

    // MARK: - #5 rar の先頭だけの取り出し

    @Test("rar の dataPrefix は全体の先頭と同じバイト列を、頼んだ長さだけ返す(#5)", arguments: ["rar/rar-flat.cbr", "rar/rar-solid.cbr"])
    func rarDataPrefixMatchesTheWholeEntry(path: String) throws {
        let reader = try makeArchiveReader(for: Fixtures.url(path))
        #expect(reader is RarArchiveReader)
        let entry = try #require(try reader.listFilePaths().sorted().first)
        let whole = try reader.data(at: entry)
        #expect(whole.count > 16)
        let prefix = try reader.dataPrefix(at: entry, maxByteCount: 16)
        #expect(prefix == whole.prefix(16))
        // 全体より長く頼めば全体。
        #expect(try reader.dataPrefix(at: entry, maxByteCount: whole.count + 100) == whole)
    }

    // MARK: - #7 取り込んだ読書位置

    @Test("取り込むページ番号は 0 以上・ページ数の範囲に丸める(#7)")
    func importedPageIndexIsClamped() {
        #expect(LibraryImportExportService.clampedPageIndex(Int.max, pageCount: 10) == 9)
        #expect(LibraryImportExportService.clampedPageIndex(-5, pageCount: 10) == 0)
        #expect(LibraryImportExportService.clampedPageIndex(Int.max, pageCount: nil) == Int.max)
        #expect(LibraryImportExportService.clampedPageIndex(3, pageCount: 0) == 3)
    }

    // MARK: - #8 名前の比べ方

    @Test("名前の比べ方は APFS と同じく ß と ss を同じ名前とみなす(#8)")
    func foldingTreatsSharpSAsDoubleS() {
        #expect(FileNameValidation.foldedForComparison("straße.zip") == FileNameValidation.foldedForComparison("STRASSE.zip"))
        #expect(FileNameValidation.foldedForComparison("Book.cbz") == FileNameValidation.foldedForComparison("book.CBZ"))
        let available = BulkRename.availableName(
            for: "straße.zip", ownName: "foo.zip", existingNames: ["foo.zip", "STRASSE.zip"], isRegistered: { _ in true }
        )
        #expect(available != "straße.zip", "塞がっている名前を選んだ")
    }

    // MARK: - A1-6 重なった並べ替えの鍵

    @Test("並べ替えに同じ鍵が 2 度あっても、そのページは 1 度だけ並ぶ(A1-6)")
    func duplicatedOverrideKeysAppearOnce() {
        struct Page: PageOrderSortable { let sortKey: String }
        let pages = ["001", "002", "003"].map(Page.init)
        let ordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: ["003", "001", "003", "002"], excludedKeys: []
        )
        #expect(ordered.map(\.sortKey) == ["003", "001", "002"])
    }

    @Test("本の側に同じ鍵のページが 2 枚あれば、鍵が 2 度書かれた並べ替えで 2 枚とも並ぶ(A1-6)")
    func duplicatedBookKeysKeepEveryPage() {
        struct Page: PageOrderSortable { let sortKey: String; let id: Int }
        let pages = [Page(sortKey: "a/1", id: 0), Page(sortKey: "a/1", id: 1), Page(sortKey: "b/2", id: 2)]
        let reordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: ["b/2", "a/1", "a/1"], excludedKeys: []
        )
        #expect(reordered.map(\.id).sorted() == [0, 1, 2])
        #expect(reordered.first?.id == 2)
        // 鍵が 1 度だけなら、残りの 1 枚は後ろへ回る(消えない)。
        let partly = EffectivePageOrder.orderedPages(for: pages, pageOrderOverride: ["b/2", "a/1"], excludedKeys: [])
        #expect(partly.count == 3)
    }

    // MARK: - #16 XML として読めない XHTML の画像の参照

    /// 置き換える前の正規表現(答えを突き合わせる基準)。
    private static func regexAnswer(_ text: String) -> String? {
        for pattern in [#"<img[^>]+src=["']([^"']+)["']"#, #"<image[^>]+(?:xlink:href|href)=["']([^"']+)["']"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let hrefRange = Range(match.range(at: 1), in: text) {
                return String(text[hrefRange])
            }
        }
        return nil
    }

    private static func scanAnswer(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        return EpubStructureResolver.firstTagAttributeValue(in: bytes, tag: Array("<img".utf8), attribute: Array("src=".utf8))
            ?? EpubStructureResolver.firstTagAttributeValue(in: bytes, tag: Array("<image".utf8), attribute: Array("href=".utf8))
    }

    nonisolated static let imageReferenceSamples: [String] = [
        #"<html><body><img src="page.jpg"></body></html>"#,
        #"<IMG SRC='Page.PNG' alt="x">"#,
        #"<img data-src="lazy.jpg" src="real.jpg">"#,
        #"<img src="a.jpg" src="b.jpg">"#,
        #"<img alt="x"><img src="second.jpg">"#,
        #"<imgsrc="x.jpg">"#,
        #"<img src="">"#,
        #"<img src="a>b.jpg">"#,
        #"<img src="a'b.jpg">"#,
        #"<img src=noquote.jpg>"#,
        #"<img alt="no src"> <img"#,
        #"<img <img src="inner.jpg">"#,
        #"<svg><image xlink:href="cover.jpg" /></svg>"#,
        #"<svg><image width="1" href='plain.jpg'/></svg>"#,
        #"<img alt="x"> <svg><image href="svg.jpg"/></svg>"#,
        #"<img src="unterminated.jpg>"#,
        #"text without tags"#,
        #"<img src="first.jpg"><img src="second.jpg">"#,
    ]

    @Test("壊れた XHTML の画像の参照は、元の正規表現と同じ答え(#16)", arguments: imageReferenceSamples)
    func imageReferenceScanMatchesTheRegex(sample: String) {
        #expect(Self.scanAnswer(sample) == Self.regexAnswer(sample))
    }

    @Test("`>` の無い `<img` を繰り返した文書でも答える(#16。一致しない文書で、正規表現は 2 乗の後戻りになった)")
    func imageReferenceScanFinishesOnPathologicalInput() {
        // 一致しないもの(2 乗になるのはこちら)。
        #expect(Self.scanAnswer(String(repeating: "<img ", count: 200_000)) == nil)
        // 閉じない引用符を重ねたもの(正規表現は 2 つ目の `<img src=` を値として拾う ―― 値に `<` は入りうる)。
        #expect(Self.scanAnswer(String(repeating: "<img src='", count: 100_000)) == "<img src=")
        // 最後にだけ一致があるもの。
        #expect(Self.scanAnswer(String(repeating: "<img ", count: 200_000) + #"src="last.jpg""#) == "last.jpg")
    }

    // MARK: - A7-3 自動登録フォルダの有無

    @Test("フォルダの有無の確かめは、あるフォルダで true、無いパスで false(A7-3)")
    func folderExistenceProbeAnswers() async throws {
        let folder = try TemporaryDirectory("audit-folder-probe")
        #expect(await FolderExistenceProbe.isDirectory(atPath: folder.url.path) == true)
        #expect(await FolderExistenceProbe.isDirectory(atPath: folder.url.path + "/missing") == false)
    }
}

/// #12: 一括の削除でコレクションの登録をまとめて外す。
@MainActor
struct HangCrashAuditCollectionTests {
    @Test("何冊ぶんかの登録をまとめて外せる(#12)")
    func removingItemsForSeveralBooksAtOnce() throws {
        let library = try InMemoryLibrary(label: "audit-remove-items-batch")
        defer { library.close() }
        let temporary = try TemporaryDirectory("audit-remove-items-batch")
        let target = try #require(library.collections.libraries.first)
        var books: [URL] = []
        for name in ["one", "two", "three"] {
            let directory = temporary.file(name)
            try FixtureFolder.make(at: directory, pages: [.init("001.jpg", number: 1)])
            books.append(directory)
        }
        let items = books.compactMap { CollectionStore.makePendingItem(for: $0) }
        let collection = try #require(library.collections.createCollection(name: "Shelf", in: target, items: items))
        #expect(collection.items.count == 3)
        let ids = collection.items.map(\.bookID)

        library.collections.removeItems(forBookIDs: Array(ids.prefix(2)))

        #expect(library.collections.allItems().map(\.bookID) == [ids[2]])
    }
}
