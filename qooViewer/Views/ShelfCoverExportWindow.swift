import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// コレクション表紙をzipにまとめて書き出す独立ウインドウ(ユーザー要望 2026-09-11)。
///
/// ■ 形は「コレクション表紙の読み込み」と対にしてある
/// 当初は小さなダイアログ(件数と保存ボタンだけ)だったが、**対になる読み込みが一覧ウインドウ
/// なのに、こちらだけ別物の形をしているのは分かりにくい**という指摘を受けて作り替えた。
/// 他の一覧ウインドウ(「メタデータの編集」「保存データの削除」「履歴の削除」等)と同じ形
/// ―― 操作するものはツールバー、一覧はその下へスクロールして潜り、件数は下部中央の
/// ステータスバー。列幅も実測して合わせる。
///
/// 一覧に出るのは**利用者が画像を指定した表紙だけ**(ShelfCoverArchiveの型コメント参照)。
/// 既定では全部にチェックが付く ―― 書き出しは「全部出す」のが普通の使い方で、外したい本が
/// あるときだけ外す。
///
/// ViewModelの持ち方は「メタデータの編集」と同じ2段構え(親が@Stateで作り、子が
/// @ObservedObjectで観測する)。**親の@Stateに入れただけでは変更を観測できない**
/// ―― 実際、読み込み側をこの形にし忘れて「ファイルを選んでも画面が変わらない」不具合を
/// 出した(ユーザー報告 2026-09-11)。
struct ShelfCoverExportWindow: View {
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var preferences: AppPreferences

    @State private var viewModel: ShelfCoverExportViewModel?

    var body: some View {
        Group {
            if let viewModel {
                ShelfCoverExportContentView(viewModel: viewModel)
            } else {
                Color.clear
                    .onAppear {
                        viewModel = ShelfCoverExportViewModel(
                            layoutStore: layoutStore, preferences: preferences
                        )
                    }
            }
        }
        .frame(minWidth: 900, minHeight: 480)
    }
}

/// 実体。ViewModelを`@ObservedObject`で直接観測する(型コメント参照)。
private struct ShelfCoverExportContentView: View {
    @ObservedObject var viewModel: ShelfCoverExportViewModel
    /// 列幅の実測に使う表示言語(他の一覧ウインドウと同じ理由・同じ書き方)。
    @Environment(\.locale) private var locale

    @State private var columnCustomization = TableColumnCustomization<ShelfCoverExportViewModel.Row>()
    @State private var fileNameColumnWidth: CGFloat = ShelfCoverExportContentView.fileNameColumnMin
    @State private var bookColumnWidth: CGFloat = ShelfCoverExportContentView.bookColumnMin
    @State private var didAutoSizeColumns = false

    // 列の実測幅の上限は、**既定のウインドウ幅(760)に収まる合計**にしてある。
    // 合計がそれを超えると、SwiftUIがその理想幅に合わせてウインドウを広く開いてしまい、
    // ツールバーに空きができて検索欄が畳まれない(実測 2026-09-11: 上限が広すぎて900ptで
    // 開いていた)。足りないときは利用者が列の境目をドラッグして広げられる。
    private static let fileNameColumnMin: CGFloat = 180
    private static let fileNameColumnMax: CGFloat = 300
    private static let bookColumnMin: CGFloat = 260
    private static let bookColumnMax: CGFloat = 380

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.rows.isEmpty {
                    ContentUnavailableView(
                        "No Collection Covers to Export",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(
                            "Only books whose collection cover is an image you chose are included. Covers taken from a page of the book can always be made again from the book itself."
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.shownRows.isEmpty {
                    ContentUnavailableView(
                        "No Matching Books", systemImage: "magnifyingglass",
                        description: Text("No book matches the current search text.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    rowTable
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            .toolbar { toolbarItems }
            .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: Text("Search"))
            .hardTopScrollEdgeEffect()
        }
        .onAppear { autoSizeColumnsIfNeeded() }
        .onChange(of: viewModel.rows.count) { _, _ in autoSizeColumnsIfNeeded() }
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: Binding(
                get: { viewModel.isEveryShownRowSelected },
                set: { viewModel.setAllShownSelected($0) }
            )) {
                Label("Select All", systemImage: "checkmark.rectangle.stack")
            }
            .toggleStyle(.button)
            .labelStyle(.titleAndIcon)
            .help("Select All / Deselect All")
            .disabled(viewModel.shownRows.isEmpty)

            if viewModel.isExporting {
                ProgressView().controlSize(.small)
            }

            Button {
                exportButtonTapped()
            } label: {
                Label("Export Collection Covers…", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.titleAndIcon)
            .disabled(viewModel.selectedBookIDs.isEmpty || viewModel.isExporting)
        }
    }

    // MARK: - 一覧

    private var rowTable: some View {
        Table(viewModel.shownRows, columnCustomization: $columnCustomization) {
            // 見出しの無いチェックボックス列。空のLocalizedStringKeyを文字列カタログへ
            // 登録させたくないためText(verbatim:)で書く(他の一覧ウインドウと同じ書き方)。
            TableColumn(Text(verbatim: "")) { row in
                Toggle(isOn: Binding(
                    get: { viewModel.selectedBookIDs.contains(row.bookID) },
                    set: { viewModel.setSelected($0, bookID: row.bookID) }
                )) {
                    Text(verbatim: "")
                }
                .labelsHidden()
            }
            .width(20)
            .disabledCustomizationBehavior(.all)

            TableColumn("Image in the Zip") { row in
                Text(row.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.fileName)
            }
            .width(min: Self.fileNameColumnMin, ideal: fileNameColumnWidth)
            .customizationID("fileName")
            .disabledCustomizationBehavior([.reorder, .visibility])

            TableColumn("Book") { row in
                HStack(spacing: 4) {
                    Text(row.bookID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.bookID)
                    FormatBadgeView(bookID: row.bookID)
                }
            }
            .width(min: Self.bookColumnMin, ideal: bookColumnWidth)
            .customizationID("book")
            .disabledCustomizationBehavior([.reorder, .visibility])
        }
        // 自動調整が済んだ時点で一度だけ作り直す(他の一覧ウインドウと同じ理由)。
        .id(didAutoSizeColumns)
    }

    private func autoSizeColumnsIfNeeded() {
        guard !didAutoSizeColumns, !viewModel.rows.isEmpty else { return }
        fileNameColumnWidth = ExportColumnWidthEstimator.idealWidth(
            for: viewModel.rows.map(\.fileName),
            minWidth: Self.fileNameColumnMin, maxWidth: Self.fileNameColumnMax, extraChrome: 12
        )
        bookColumnWidth = ExportColumnWidthEstimator.idealWidth(
            for: viewModel.rows.map(\.bookID),
            minWidth: Self.bookColumnMin, maxWidth: Self.bookColumnMax,
            extraChrome: 44 // 形式バッジぶんの余白
        )
        didAutoSizeColumns = true
    }

    // MARK: - 下部

    private var statusBar: some View {
        ListWindowStatusBar {
            Text("\(viewModel.shownRows.count) of \(viewModel.rows.count) books shown")

            if !viewModel.selectedBookIDs.isEmpty {
                ListWindowStatusSeparator()
                Text("\(viewModel.selectedBookIDs.count) selected")
                    .monospacedDigit()
            }
            if !viewModel.skippedBookIDs.isEmpty {
                ListWindowStatusSeparator()
                Text("\(viewModel.skippedBookIDs.count) skipped")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let message = viewModel.resultMessage {
                ListWindowStatusSeparator()
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: viewModel.didSucceed
                        ? "checkmark.circle" : "exclamationmark.triangle")
                }
                .foregroundStyle(viewModel.didSucceed ? Color.primary : Color.orange)
            }
        }
    }

    // MARK: - 保存先を選ぶ

    private func exportButtonTapped() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = String(
            localized: "qooViewer Collection Covers.zip", language: locale
        )
        panel.message = String(
            localized: "Choose where to save the exported zip file.", language: locale
        )
        if let lastFolder = LastUsedFolderMemory.libraryIO.lastFolder() {
            panel.directoryURL = lastFolder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LastUsedFolderMemory.libraryIO.remember(url.deletingLastPathComponent())
        Task { await viewModel.export(to: url) }
    }
}
