import Foundation
import SwiftUI
import Combine

/// CBZ出力ウインドウのロジック。EpubExportViewModelと同じく、共通部分は
/// BookExportViewModelにあり、ここに残るのはCBZ固有の出力オプションと
/// CbzExportInput/CbzExportOptionsへの詰め替えだけ。
final class CbzExportViewModel: BookExportViewModel {
    /// ComicInfo.xmlの`Volume`要素にも巻数を書き出すか(既定OFF)。
    /// 既定をOFFにしている理由はCbzExportOptions.writesVolumeElementのコメント参照。
    @Published var writesVolumeElement = false

    override var outputFileExtension: String { "cbz" }

    /// ユーザー選択: CBZ出力にもカバー画像の選択機能を設ける(ComicInfo.xmlの
    /// `Page@Type="FrontCover"`として書き出す)。
    override var supportsCoverSelection: Bool { true }

    override init(
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore, metadataStore: BookMetadataStore,
        preferences: AppPreferences
    ) {
        super.init(
            bookmarkStore: bookmarkStore, layoutStore: layoutStore, metadataStore: metadataStore,
            preferences: preferences
        )
        // CBZだけは連番リネームを既定ONにする。CBZには読み順を表すメタデータが無く、
        // リーダーはファイル名の並び順だけでページ順を決めるため、ページの並べ替え・除外を
        // 確実に反映するには連番へ振り直す必要がある(CbzExportOptionsのコメント参照)。
        renumberImagesSequentially = true
    }

    override func export(_ prepared: PreparedBook, to destinationURL: URL) async throws {
        let input = CbzExportInput(
            book: prepared.book,
            pageOrderOverride: prepared.pageOrderOverride,
            pageOverrides: prepared.pageOverrides,
            readingDirection: prepared.readingDirection,
            bookmarks: prepared.bookmarks,
            coverOverride: prepared.coverOverride,
            titleOverride: prepared.title,
            author: prepared.author,
            series: prepared.metadata?.series,
            // ComicInfoのNumberはxs:stringのため、EPUB/PDFと違い数値へ丸めずに
            // 生のseriesIndexをそのまま渡す(「上」「下」もそのまま書ける)。
            seriesIndex: prepared.metadata?.seriesIndex,
            language: exportLanguageCode
        )
        let options = CbzExportOptions(
            renumberImagesSequentially: renumberImagesSequentially,
            includeExcludedPages: includeExcludedPages,
            writesVolumeElement: writesVolumeElement
        )
        try await CbzExporter.export(input, options: options, to: destinationURL)
    }
}
