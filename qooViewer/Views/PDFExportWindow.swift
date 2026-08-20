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
        // PDFにはEPUBのrendition:spread/page-progression-directionに相当する情報を書き込む
        // ための公式APIが無いため(PDFExportInputのコメント参照)、見開き/読み方向の設定は
        // この書き出しには反映されないことを常に表示しておく(ユーザー指示: エクスポート
        // ウインドウに見開き情報は失われる旨の警告を記載する)。
        warningBanner: "PDF files can't store spread/reading-direction layout information. Bookmarks and title/author are exported, but the spread and reading-direction settings will be lost.",
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
                    PDFExportOptionsView(viewModel: viewModel)
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

/// PDF固有の出力オプション(EpubExportOptionsViewと同じ理由で分けてある)。
/// 連番リネームに相当する項目はPDF出力には無い(PDFExportOptions参照)。
private struct PDFExportOptionsView: View {
    @ObservedObject var viewModel: PDFExportViewModel

    var body: some View {
        Toggle("Include Excluded Pages", isOn: $viewModel.includeExcludedPages)
    }
}
