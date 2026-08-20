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
                    CbzExportOptionsView(viewModel: viewModel)
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

/// CBZ固有の出力オプション(EpubExportOptionsViewと同じ理由で分けてある)。
private struct CbzExportOptionsView: View {
    @ObservedObject var viewModel: CbzExportViewModel

    var body: some View {
        Toggle("Renumber Image Files Sequentially", isOn: $viewModel.renumberImagesSequentially)
            // CBZには読み順を表すメタデータが無く、ファイル名の並び順だけが順序を決めるため、
            // OFFにするとページの並べ替え・除外が他アプリで再現されないことがある。
            .help("CBZ files have no page-order metadata, so readers sort by file name. Turn this off only if you want to keep the original file names.")
        Toggle("Include Excluded Pages", isOn: $viewModel.includeExcludedPages)
        Toggle("Also Write the Volume Number to ComicInfo’s Volume Element", isOn: $viewModel.writesVolumeElement)
            .help("Kavita reads Volume as the volume number, but Komga appends it to the series name, which can split a series into one series per volume.")
    }
}
