import Foundation

/// EPUB出力ウインドウ(設計コンセプト7節)のロジック。
///
/// 対象一覧・実在確認・タイトル/著者名の編集欄・カバー画像の選択・空き容量チェック・
/// 進捗/キャンセル/同名確認/失敗集約は、PDF出力・CBZ出力とまったく同じ処理のため
/// BookExportViewModelへ集約してある。このクラスに残っているのは、集めた材料を
/// EpubExportInput/EpubExportOptionsへ詰め替えてEpubExporterを呼ぶところだけ。
final class EpubExportViewModel: BookExportViewModel {
    override var format: BookExportFormat { .epub }

    /// ユーザー要望: EPUB出力時のカバー画像を選択・変更できるようにしたい。
    override var supportsCoverSelection: Bool { true }

    override func export(_ prepared: PreparedBook, to destinationURL: URL) async throws {
        let input = EpubExportInput(
            book: prepared.book,
            pageOrderOverride: prepared.pageOrderOverride,
            pageOverrides: prepared.pageOverrides,
            // 本ごとの上書きが無い場合も環境設定の既定読み方向で埋めた値が渡ってくる
            // (常に明示的なpage-progression-directionを出力するため。
            // PreparedBook.readingDirectionのコメント参照)。
            readingDirectionOverride: prepared.readingDirection,
            forcedDisplayMode: prepared.forcedDisplayMode,
            bookmarks: prepared.bookmarks,
            coverOverride: prepared.coverOverride,
            titleOverride: prepared.title,
            author: prepared.author,
            // シリーズ名・巻数はこの画面に入力欄が無く、メタデータDBの登録内容をそのまま使う
            // (ユーザー要望: 登録がある場合はそちらを優先する)。巻数はEPUBのgroup-positionが
            // 数値必須のため、数値として解釈できる場合だけ書き出す
            // (BookMetadata.exportableSeriesIndex参照)。
            series: prepared.metadata?.series,
            seriesIndex: prepared.metadata?.exportableSeriesIndex,
            language: exportLanguageCode
        )
        let options = EpubExportOptions(
            renumberImagesSequentially: renumberImagesSequentially, includeExcludedPages: includeExcludedPages
        )
        try await EpubExporter.export(input, options: options, to: destinationURL)
    }
}
