import SwiftUI

/// CBZ出力専用ウインドウ。File メニューの「CBZとしてエクスポート…」から開く。
/// EpubExportWindowと同じ構成(カバー列あり)で、違うのは文言と出力オプションだけ
/// (共通部分はExportWindowContent)。
struct CbzExportWindow: View {
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var preferences: AppPreferences

    @State private var viewModel: CbzExportViewModel?

    private static let configuration = ExportWindowConfiguration(
        showsCoverColumn: true,
        emptyDescription: "Books need bookmarks, page layout settings, or metadata before they can be exported as CBZ.",
        warningBanner: nil,
        startButtonTitle: "Start CBZ Export…",
        progressTitle: "Exporting CBZ Files…",
        fileExtension: "cbz",
        destinationPanelMessage: { locale in
            String(localized: "Choose a destination folder for the exported CBZ files.", locale: locale)
        },
        lastUsedFolder: .cbzExport,
        minimumWindowWidth: 820
    )

    var body: some View {
        Group {
            if let viewModel {
                ExportWindowContent(viewModel: viewModel, configuration: Self.configuration) {
                    BookExportFormatOptions(format: .cbz, viewModel: viewModel)
                }
            } else {
                ProgressView()
                    .frame(minWidth: 820, minHeight: 480)
                    .onAppear {
                        viewModel = CbzExportViewModel(
                            bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                            metadataStore: metadataStore, preferences: preferences
                        )
                    }
            }
        }
    }
}
