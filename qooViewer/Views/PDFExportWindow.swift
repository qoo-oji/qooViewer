import SwiftUI

/// PDF出力専用ウインドウ。File メニューの「PDFとしてエクスポート…」(「EPUBとして
/// エクスポート…」の直下)から開く。EpubExportWindowと同じ構成で、違うのは文言・
/// 出力オプション・カバー列を持たないことだけ(共通部分はExportWindowContent)。
struct PDFExportWindow: View {
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var preferences: AppPreferences

    @State private var viewModel: PDFExportViewModel?

    private static let configuration = ExportWindowConfiguration(
        // PDF出力はカバー画像の指定機能自体を持たない(PDFExportInputのコメント参照)。
        showsCoverColumn: false,
        emptyDescription: "Books need bookmarks, page layout settings, or metadata before they can be exported as PDF.",
        // 以前はここに「見開き・読み方向は失われる」という警告を出していた。CGPDFContextに
        // これらを書き込むAPIが無かったためだが、現在は書き出したあとに増分更新で
        // `/ViewerPreferences`・`/PageLayout`を書き加えるようにしたため、本全体の読み方向と
        // 見開き強制はPDFにもそのまま入る(PDFCatalogAugmenter参照)。
        //
        // 残る制約はページ単位のレイアウト(このページだけ単独/見開き左右)で、これはPDFの
        // 仕様に対応する概念が無い(PDFExportInputのコメント参照)。ただしこれは
        // 「PDFでは何も引き継げない」という以前の状況とは重みが違ううえ、ページ単位の指定を
        // 使っている本自体が限られるため、全員に常時見せる警告は出さない。
        warningBanner: nil,
        startButtonTitle: "Start PDF Export…",
        progressTitle: "Exporting PDF Files…",
        fileExtension: "pdf",
        destinationPanelMessage: { locale in
            String(localized: "Choose a destination folder for the exported PDF files.", locale: locale)
        },
        lastUsedFolder: .pdfExport,
        minimumWindowWidth: 700
    )

    var body: some View {
        Group {
            if let viewModel {
                ExportWindowContent(viewModel: viewModel, configuration: Self.configuration) {
                    BookExportFormatOptions(format: .pdf, viewModel: viewModel)
                }
            } else {
                ProgressView()
                    .frame(minWidth: 700, minHeight: 480)
                    .onAppear {
                        viewModel = PDFExportViewModel(
                            bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                            metadataStore: metadataStore, preferences: preferences
                        )
                    }
            }
        }
    }
}
