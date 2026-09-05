import Foundation
import Testing

@testable import qooViewer

/// EPUB の構造解決(`EpubStructureResolver`)。**EPUB はページ順が spine で決まる唯一の形式**
/// (名前順ではない)なので、ここが動くと本の並びがそのまま変わる。
///
/// 本として開いた結果(`BookLoader.loadEpub` 経由の sortKey / epubSpreadPosition)は
/// `GeneratedFixtureTests` が押さえているので、こちらは解決役そのものを直接呼んで、
/// 書き方の揺れ(名前空間の接頭辞、media-type の省略、画像を直に指す spine、svg、画像欠け)と
/// 書誌メタデータ・目次を見る。
struct EpubStructureTests {

    /// 組み立てた EPUB と、その解決結果。`temp` を一緒に持たせてあるのは、`TemporaryDirectory` が
    /// 手放されるとフォルダごと消えるため ―― reader が掴んでいるファイルを、使い終わるまで残す。
    private struct Resolved {
        let temp: TemporaryDirectory
        let reader: ArchiveReading
        let structure: EpubStructure
    }

    private func resolve(_ builder: EpubFixtureBuilder, label: String = "epub") throws -> Resolved {
        let temp = try TemporaryDirectory(label)
        let url = temp.file("book.epub")
        try builder.write(to: url)
        let reader = try ZipArchiveReader(url: url)
        return Resolved(temp: temp, reader: reader, structure: try EpubStructureResolver.resolve(reader: reader))
    }

    // MARK: - spine

    @Test("ページは spine の順(manifest の並びには従わない)")
    func spineOrder() throws {
        var builder = EpubFixtureBuilder.pages(3)
        builder.manifestReversed = true
        let structure = try resolve(builder).structure
        #expect(structure.pages.map(\.entryPath) == builder.expectedEntryPaths)
        #expect(structure.pages.map(\.sourceHref) == (0..<3).map { "OEBPS/\(builder.xhtmlHref($0))" })
    }

    @Test("見開きの指定は page-spread-left / right / rendition:page-spread-center")
    func spreadPositions() throws {
        var builder = EpubFixtureBuilder.pages(4)
        builder.pages[0].spineProperties = "rendition:page-spread-center"
        builder.pages[1].spineProperties = "page-spread-left"
        builder.pages[2].spineProperties = "page-spread-right"
        let structure = try resolve(builder).structure
        #expect(structure.pages.map(\.spreadPosition) == [.center, .left, .right, nil])
    }

    @Test(
        "読み方向は spine の page-progression-direction",
        arguments: [("rtl", ReadingDirection.rightToLeft), ("ltr", .leftToRight)]
    )
    func pageProgressionDirection(rawValue: String, expected: ReadingDirection) throws {
        var builder = EpubFixtureBuilder.pages(2)
        builder.pageProgressionDirection = rawValue
        #expect(try resolve(builder).structure.pageProgressionDirection == expected)
    }

    /// `rendition:spread` は 5 値あるが、macOS のウインドウには「端末の向き」が無いので
    /// none(単ページ強制)と both(見開き強制)だけを強制値として扱う(型コメント)。
    @Test(
        "rendition:spread は none / both だけを強制値として扱う",
        arguments: [("none", DisplayMode.single), ("both", .spread), ("auto", nil), ("landscape", nil)]
    )
    func renditionSpread(rawValue: String, expected: DisplayMode?) throws {
        var builder = EpubFixtureBuilder.pages(2)
        builder.renditionSpread = rawValue
        #expect(try resolve(builder).structure.forcedDisplayMode == expected)
    }

    @Test("指定が無ければ読み方向も見開き強制も nil")
    func noLayoutHints() throws {
        let structure = try resolve(.pages(2)).structure
        #expect(structure.pageProgressionDirection == nil)
        #expect(structure.forcedDisplayMode == nil)
    }

    // MARK: - 書き方の揺れ

    @Test("接頭辞付きの名前空間(opf:)でも読める")
    func namespacePrefixedPackageDocument() throws {
        var builder = EpubFixtureBuilder.pages(3)
        builder.namespacePrefixed = true
        builder.pageProgressionDirection = "rtl"
        let structure = try resolve(builder).structure
        #expect(structure.pages.map(\.entryPath) == builder.expectedEntryPaths)
        #expect(structure.pageProgressionDirection == .rightToLeft)
    }

    @Test("manifest の media-type が無ければ拡張子で判断する")
    func missingMediaType() throws {
        var builder = EpubFixtureBuilder.pages(3)
        builder.omitMediaType = true
        let structure = try resolve(builder).structure
        #expect(structure.pages.map(\.entryPath) == builder.expectedEntryPaths)
    }

    @Test("spine が画像そのものを指す形・svg の image・画像の無い項目")
    func spineVariants() throws {
        var builder = EpubFixtureBuilder.pages(4)
        builder.pages[0].imageInSpine = true
        builder.pages[1].svg = true
        builder.pages[2].imageMissing = true  // この項目はページにならない
        let structure = try resolve(builder).structure
        #expect(structure.pages.map(\.entryPath) == builder.expectedEntryPaths)
        #expect(structure.pages.count == 3)
    }

    @Test("OPF がルート直下でなくても、href は OPF の場所を基準に解決する")
    func contentDirectory() throws {
        var builder = EpubFixtureBuilder.pages(2)
        builder.contentDirectory = "item/xhtml"
        let structure = try resolve(builder).structure
        #expect(structure.pages.map(\.entryPath) == builder.expectedEntryPaths)
        #expect(structure.pages.allSatisfy { $0.entryPath.hasPrefix("item/xhtml/Images/") })
    }

    @Test("container.xml が無ければ containerNotReadable")
    func missingContainer() throws {
        var builder = EpubFixtureBuilder.pages(2)
        builder.omitContainer = true
        let temp = try TemporaryDirectory("epub-no-container")
        let url = temp.file("book.epub")
        try builder.write(to: url)
        let reader = try ZipArchiveReader(url: url)
        #expect(throws: EpubStructureError.self) { _ = try EpubStructureResolver.resolve(reader: reader) }
    }

    // MARK: - 書誌メタデータ

    @Test("dc:title / dc:creator を読む")
    func metadataFromDublinCore() throws {
        var builder = EpubFixtureBuilder.pages(2)
        builder.title = "テスト本"
        builder.author = "作者"
        let resolved = try resolve(builder)
        let metadata = EpubStructureResolver.resolveMetadata(reader: resolved.reader)
        #expect(metadata.title == "テスト本")
        #expect(metadata.author == "作者")
        #expect(metadata.series.isEmpty)
        #expect(metadata.seriesIndex.isEmpty)
    }

    @Test("EPUB3 の belongs-to-collection(collection-type = series)をシリーズとして読む")
    func metadataFromCollection() throws {
        var builder = EpubFixtureBuilder.pages(2)
        builder.collection = (name: "テストシリーズ", position: "3", type: "series")
        let resolved = try resolve(builder)
        let metadata = EpubStructureResolver.resolveMetadata(reader: resolved.reader)
        #expect(metadata.series == "テストシリーズ")
        #expect(metadata.seriesIndex == "3")
    }

    @Test("collection-type が省かれていても次善の候補として採る")
    func metadataFromCollectionWithoutType() throws {
        var builder = EpubFixtureBuilder.pages(2)
        builder.collection = (name: "型無しシリーズ", position: "2.50", type: nil)
        let resolved = try resolve(builder)
        let metadata = EpubStructureResolver.resolveMetadata(reader: resolved.reader)
        #expect(metadata.series == "型無しシリーズ")
        #expect(metadata.seriesIndex == "2.5")
    }

    @Test("collection-type が series 以外(set)なら採らない")
    func metadataIgnoresNonSeriesCollection() throws {
        var builder = EpubFixtureBuilder.pages(2)
        builder.collection = (name: "全集", position: "1", type: "set")
        let resolved = try resolve(builder)
        #expect(EpubStructureResolver.resolveMetadata(reader: resolved.reader).series.isEmpty)
    }

    /// 両方書かれている場合は Calibre 側を採る(ユーザー指定。EPUB3 側は書き出し時のまま
    /// 古くなっていることがあるため)。
    @Test("calibre:series は belongs-to-collection より優先する")
    func calibreSeriesWins() throws {
        var builder = EpubFixtureBuilder.pages(2)
        builder.calibreSeries = "Calibre のシリーズ"
        builder.calibreSeriesIndex = "3.00"
        builder.collection = (name: "EPUB3 のシリーズ", position: "9", type: "series")
        let resolved = try resolve(builder)
        let metadata = EpubStructureResolver.resolveMetadata(reader: resolved.reader)
        #expect(metadata.series == "Calibre のシリーズ")
        #expect(metadata.seriesIndex == "3")
    }

    /// 巻数の整形。Calibre は "3.00" / "3.50" の形で書くので戻す。qooViewer 自身の書き出しも
    /// この形なので、ここが変わると「3.5 と入力した巻数が開き直すたびに 3.50 になる」が再発する。
    @Test(
        "normalizedSeriesIndex",
        arguments: [
            ("3.00", "3"), ("3.50", "3.5"), ("3", "3"), ("3.125", "3.125"), (" 3 ", "3"),
            ("", ""), ("上巻", "上巻"), ("3.5e1", "35"),
        ]
    )
    func normalizedSeriesIndex(rawValue: String, expected: String) {
        #expect(EpubStructureResolver.normalizedSeriesIndex(rawValue) == expected)
    }

    @Test("normalizedSeriesIndex は nil を空文字にする")
    func normalizedSeriesIndexOfNil() {
        #expect(EpubStructureResolver.normalizedSeriesIndex(nil) == "")
    }

    // MARK: - 目次

    @Test("nav.xhtml の目次を、入れ子ごとページのインデックスへ対応付ける")
    func tableOfContents() throws {
        let resolved = try resolve(.pages(4))
        let toc = EpubStructureResolver.resolveTableOfContents(
            reader: resolved.reader, structure: resolved.structure
        )
        // EpubFixtureBuilder の nav は「第1章(1 ページ目)> 1.1 節(2 ページ目)」「第2章(最後)」。
        #expect(toc.map(\.title) == ["第1章", "1.1 節", "第2章"])
        #expect(toc.map(\.pageIndex) == [0, 1, 3])
    }

    @Test("nav が無ければ目次は空(エラーにはしない)")
    func tableOfContentsWithoutNav() throws {
        var builder = EpubFixtureBuilder.pages(3)
        builder.includeNav = false
        let resolved = try resolve(builder)
        #expect(EpubStructureResolver.resolveTableOfContents(
            reader: resolved.reader, structure: resolved.structure
        ).isEmpty)
    }
}
