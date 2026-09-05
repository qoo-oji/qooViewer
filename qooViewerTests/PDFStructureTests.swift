import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// PDF の「ページ描画には関わらないメタ情報」(`PDFStructureResolver`)。読み方向・見開き強制は
/// Document Catalog、書誌は XMP / Info 辞書、目次はアウトライン。
///
/// 台帳の pdf/ は `scripts/fixtures/make-pdf.py` が xref まで自分で書いたもので、**読み取りの正解を
/// 書き出し側(PDFExporter / PDFCatalogAugmenter)に依存せずに**持つためにコミットしてある。
/// 本として開いた結果(sourceLayoutHint)は `FixtureBookTests` が台帳と突き合わせているので、
/// ここでは解決役を直接呼ぶ。
struct PDFStructureTests {

    private func document(_ relativePath: String) throws -> CGPDFDocument {
        try #require(CGPDFDocument(Fixtures.url(relativePath) as CFURL), "PDF を開けない: \(relativePath)")
    }

    // MARK: - Document Catalog → SourceLayoutHint

    @Test("/ViewerPreferences/Direction と /PageLayout を読む")
    func layoutHint() throws {
        let rightToLeft = PDFStructureResolver.resolveLayoutHint(document: try document("pdf/pdf-r2l-twopageleft.pdf"))
        #expect(rightToLeft == SourceLayoutHint(pageProgressionDirection: .rightToLeft, forcedDisplayMode: .spread))

        // /PageLayout SinglePage は「単ページ強制」とはみなさない(多くの生成ツールが意図せず
        // 省略・既定値のまま書くため。resolveLayoutHint のコメント)。
        let leftToRight = PDFStructureResolver.resolveLayoutHint(document: try document("pdf/pdf-l2r-singlepage.pdf"))
        #expect(leftToRight == SourceLayoutHint(pageProgressionDirection: .leftToRight, forcedDisplayMode: nil))

        // どちらも無ければヒント自体を作らない。
        #expect(PDFStructureResolver.resolveLayoutHint(document: try document("pdf/pdf-plain.pdf")) == nil)
    }

    /// 読み取りと書き出しで表記がずれないよう、対応表は 1 か所にまとめてある(型コメント)。
    @Test("Catalog へ書く名前は、読み取り側と対になっている")
    func catalogNames() {
        #expect(PDFStructureResolver.catalogDirectionName(for: .rightToLeft) == "R2L")
        #expect(PDFStructureResolver.catalogDirectionName(for: .leftToRight) == "L2R")
        // TwoPageLeft / TwoPageRight は「奇数ページを左右どちらに置くか」なので読み方向で選び分ける。
        #expect(PDFStructureResolver.catalogPageLayoutName(for: .spread, direction: .rightToLeft) == "TwoPageRight")
        #expect(PDFStructureResolver.catalogPageLayoutName(for: .spread, direction: .leftToRight) == "TwoPageLeft")
        #expect(PDFStructureResolver.catalogPageLayoutName(for: .single, direction: .rightToLeft) == "SinglePage")
        // 強制指定が無ければ /PageLayout 自体を書かない(既定値の明示は「単ページ強制」の意味になる)。
        #expect(PDFStructureResolver.catalogPageLayoutName(for: nil, direction: .rightToLeft) == nil)
    }

    // MARK: - Info 辞書 → 書誌メタデータ

    @Test("Info 辞書の Title / Author(UTF-16BE)を読む")
    func metadata() {
        let metadata = PDFStructureResolver.resolveMetadata(url: Fixtures.url("pdf/pdf-outline.pdf"))
        #expect(metadata.title == "テスト本")
        #expect(metadata.author == "作者")
        // このフィクスチャの Keywords は "fixture" だけ(旧形式の series: は入っていない)。
        #expect(metadata.series.isEmpty)
        #expect(metadata.seriesIndex.isEmpty)
    }

    @Test("メタデータの無い PDF は空のまま(取り込むものが無い)")
    func metadataOfPlainPDF() {
        #expect(PDFStructureResolver.resolveMetadata(url: Fixtures.url("pdf/pdf-plain.pdf")).isEmpty)
    }

    /// 旧・独自形式(Keywords の `series:` / `series_index:`)は**読み取り専用の後方互換**。
    /// 今の書き出しは Calibre 互換の XMP なので、この経路は当時の PDF のためだけに残っている。
    @Test(
        "parseSeriesKeywords",
        arguments: [
            ("series:テスト, series_index:3.00", "テスト", "3"),
            ("series: 空白付き , series_index: 2.5 ", "空白付き", "2.5"),
            ("fixture, series:後ろの方, series_index:10", "後ろの方", "10"),
            ("series:カンマ, を含む, series_index:1", "カンマ", "1"),  // この形式の制約(型コメント)
            ("series_index:4", "", "4"),
            ("fixture", "", ""),
            ("", "", ""),
        ]
    )
    func parseSeriesKeywords(keywords: String, series: String, seriesIndex: String) {
        let parsed = PDFStructureResolver.parseSeriesKeywords(keywords)
        #expect(parsed.series == series)
        #expect(parsed.seriesIndex == seriesIndex)
    }

    // MARK: - アウトライン → ブックマーク

    @Test("入れ子のアウトラインを、出現順のページインデックスへ畳む")
    func outline() {
        let entries = PDFStructureResolver.resolveOutline(url: Fixtures.url("pdf/pdf-outline.pdf"))
        // make-pdf.py の --outline は「第1章(1 ページ目)> 1.1 節(2 ページ目)」「第2章(最後)」。
        #expect(entries.map(\.title) == ["第1章", "1.1 節", "第2章"])
        #expect(entries.map(\.pageIndex) == [0, 1, 3])
    }

    @Test("アウトラインが無ければ空(エラーにはしない)")
    func outlineOfPlainPDF() {
        #expect(PDFStructureResolver.resolveOutline(url: Fixtures.url("pdf/pdf-plain.pdf")).isEmpty)
    }
}
