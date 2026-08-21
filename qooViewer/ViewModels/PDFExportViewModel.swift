import Foundation

/// PDF出力ウインドウのロジック。EpubExportViewModelと同じく、共通部分は
/// BookExportViewModelにあり、ここに残るのはPDFExportInput/PDFExportOptionsへの
/// 詰め替えだけ。
///
/// カバー画像の選択機能は持たない(supportsCoverSelectionを上書きしない)。PDFには
/// EPUBのproperties="cover-image"のような「ページではない埋め込み画像メタデータ」の
/// 仕組みが無く、実質的にPDFの1ページ目がカバーとして扱われるため
/// (PDFExportInputのコメント、ユーザーの意向参照)。
final class PDFExportViewModel: BookExportViewModel {
    override var outputFileExtension: String { "pdf" }

    override func export(_ prepared: PreparedBook, to destinationURL: URL) async throws {
        let input = PDFExportInput(
            book: prepared.book,
            pageOrderOverride: prepared.pageOrderOverride,
            pageOverrides: prepared.pageOverrides,
            bookmarks: prepared.bookmarks,
            titleOverride: prepared.title,
            author: prepared.author,
            series: prepared.metadata?.series,
            // 巻数は、Calibreのcalibre:series_indexが数値として読まれるため、数値として
            // 解釈できる場合だけ書き出す(BookMetadata.exportableSeriesIndex参照)。
            seriesIndex: prepared.metadata?.exportableSeriesIndex,
            readingDirection: prepared.readingDirection,
            forcedDisplayMode: prepared.forcedDisplayMode
        )
        let options = PDFExportOptions(includeExcludedPages: includeExcludedPages)
        try await PDFExporter.export(input, options: options, to: destinationURL)
    }
}
