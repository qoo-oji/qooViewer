import SwiftUI

/// 設計コンセプト7節: EPUB出力専用ウインドウ。File メニューの「EPUBとしてエクスポート…」から
/// 開く。「ブックマーク・レイアウトの編集」ウインドウと同じく、本を今開いているかどうかに
/// 関わらずいつでも開ける独立ウインドウ。
///
/// EpubExportViewModelはbookmarkStore/layoutStore(@EnvironmentObject)を受け取ってから
/// 組み立てる必要があり、宣言時のデフォルト値だけでは初期化できない(QooViewerApp.init()が
/// favoritesStore等を組み立てるのと同じ制約)。そのため、まず素の@State(参照を保持するだけ)で
/// 持っておき、.onAppearで実際に組み立てた後は、実体の表示・すべての状態観測は
/// @ObservedObjectを持つ子ビュー(ExportWindowContent)に委ねる(このEpubExportWindow自身は
/// ViewModelを観測していないため、子ビューを分けないと@Publishedプロパティの変化が
/// 再描画に反映されない)。
///
/// 一覧・列幅・進捗・結果・出力先選択はPDF出力・CBZ出力とまったく同じもので、
/// ExportWindowContentが共通で持っている。ここに残っているのは、EPUB固有の文言と
/// 出力オプションだけ。
struct EpubExportWindow: View {
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var preferences: AppPreferences

    @State private var viewModel: EpubExportViewModel?

    private static let configuration = ExportWindowConfiguration(
        showsCoverColumn: true,
        emptyDescription: "Books need bookmarks, page layout settings, or metadata before they can be exported as EPUB.",
        warningBanner: nil,
        startButtonTitle: "Start EPUB Export…",
        progressTitle: "Exporting EPUB Files…",
        fileExtension: "epub",
        destinationPanelMessage: { locale in
            String(localized: "Choose a destination folder for the exported EPUB files.", locale: locale)
        },
        lastUsedFolder: .epubExport,
        minimumWindowWidth: 820
    )

    var body: some View {
        Group {
            if let viewModel {
                ExportWindowContent(viewModel: viewModel, configuration: Self.configuration) {
                    EpubExportOptionsView(viewModel: viewModel)
                }
            } else {
                ProgressView()
                    .frame(minWidth: 820, minHeight: 480)
                    .onAppear {
                        viewModel = EpubExportViewModel(
                            bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                            metadataStore: metadataStore, preferences: preferences
                        )
                    }
            }
        }
    }
}

/// EPUB固有の出力オプション。Toggleの双方向Bindingを作るには@ObservedObjectで
/// ViewModelを観測している必要があるため、親(EpubExportWindow)から分けた小さなビューにする。
private struct EpubExportOptionsView: View {
    @ObservedObject var viewModel: EpubExportViewModel

    var body: some View {
        Toggle("Renumber Image Files Sequentially", isOn: $viewModel.renumberImagesSequentially)
        Toggle("Include Excluded Pages", isOn: $viewModel.includeExcludedPages)
    }
}
