import SwiftUI
import AppKit
import Combine


/// PDF出力専用ウインドウ。File メニューの「PDFとしてエクスポート…」(「EPUBとしてエクスポート…」の
/// 直下)から開く。EpubExportWindowと同じく、本を今開いているかどうかに関わらずいつでも開ける
/// 独立ウインドウ。
///
/// PDFExportViewModelはbookmarkStore/layoutStore(@EnvironmentObject)を受け取ってから組み立てる
/// 必要があり、宣言時のデフォルト値だけでは初期化できない(EpubExportWindowと同じ制約)。
struct PDFExportWindow: View {
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var preferences: AppPreferences

    @State private var viewModel: PDFExportViewModel?

    var body: some View {
        Group {
            if let viewModel {
                PDFExportContentView(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(minWidth: 700, minHeight: 480)
                    .onAppear {
                        viewModel = PDFExportViewModel(
                            bookmarkStore: bookmarkStore, layoutStore: layoutStore, metadataStore: metadataStore
                        )
                    }
            }
        }
    }
}

/// PDFExportWindowの実体表示。EpubExportContentViewと同じ理由(@ObservedObjectでViewModelを
/// 直接観測する必要がある)で親から分離してある。
private struct PDFExportContentView: View {
    @ObservedObject var viewModel: PDFExportViewModel
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var insufficientSpaceMessage: String?
    /// ファイル名列・タイトル列・著者名列の幅。EpubExportColumnWidthsと同じ考え方だが、
    /// カバー列は無い(PDF出力にはカバー画像の指定機能自体が無いため)。
    @State private var columnWidths = PDFExportColumnWidths()
    @State private var didAutoSizeColumns = false

    /// EpubExportContentView.fixedChromeWidthと同じ考え方だが、列が3つ(カバー列が無い)ぶん
    /// 区切り線の数も1つ少ない。
    private static let fixedChromeWidth: CGFloat = 20 + 4 * 9 + trailingIndicatorWidth + 32 + 6 * 6
    /// ユーザー要望によりメタデータのインジケータを追加したため、アイコンのスロットは3つ。
    fileprivate static let trailingIndicatorWidth: CGFloat =
        indicatorLeadingGap + indicatorIconsWidth + indicatorTrailingGap
    /// アイコン3つ(レイアウト/ブックマーク/メタデータ)を並べた領域の幅。
    /// スロットの寸法とアイコンの出し分け方はExportIndicatorIconにまとめてある
    /// (行ごとに並びがずれていた不具合の経緯もそちらのコメント参照)。
    fileprivate static let indicatorIconsWidth: CGFloat = ExportIndicatorIcon.totalWidth(iconCount: 3)

    fileprivate static let indicatorLeadingGap: CGFloat = 4
    fileprivate static let indicatorTrailingGap: CGFloat = 14

    private var contentMinWidth: CGFloat {
        columnWidths.fileName + columnWidths.title + columnWidths.author + Self.fixedChromeWidth
    }

    private func autoSizeColumnsIfNeeded() {
        guard !didAutoSizeColumns, !viewModel.rows.isEmpty else { return }
        didAutoSizeColumns = true
        let fileNames = viewModel.rows.map(\.displayName)
        let titles = viewModel.rows.map { viewModel.titleOverrides[$0.bookID] ?? $0.displayName }
        let authors = viewModel.rows.map { viewModel.authorOverrides[$0.bookID] ?? "" }
        columnWidths.fileName = PDFExportColumnWidthEstimator.idealWidth(
            for: fileNames, minWidth: 130, maxWidth: 420, extraChrome: 44 // フォーマットバッジぶんの余白
        )
        columnWidths.title = PDFExportColumnWidthEstimator.idealWidth(for: titles, minWidth: 130, maxWidth: 420)
        columnWidths.author = PDFExportColumnWidthEstimator.idealWidth(for: authors, minWidth: 80, maxWidth: 260)
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.rows.isEmpty {
                ContentUnavailableView(
                    "No Eligible Books",
                    systemImage: "square.and.arrow.up",
                    description: Text("Books need bookmarks, page layout settings, or metadata before they can be exported as PDF.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                bookListSection
            }

            spreadInfoWarningBanner

            Divider()
            optionsSection
            Divider()
            bottomSection
        }
        .frame(minWidth: max(700, contentMinWidth), minHeight: 480)
        .onAppear { autoSizeColumnsIfNeeded() }
        .alert(
            "Not Enough Free Space",
            isPresented: Binding(
                get: { insufficientSpaceMessage != nil }, set: { if !$0 { insufficientSpaceMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { insufficientSpaceMessage = nil }
        } message: {
            Text(insufficientSpaceMessage ?? "")
        }
        .sheet(isPresented: .constant(viewModel.isExporting)) {
            progressSheet
        }
        .sheet(isPresented: Binding(get: { viewModel.didFinish }, set: { if !$0 { viewModel.acknowledgeFinish() } })) {
            resultSheet
        }
    }

    /// PDFにはEPUBのrendition:spread/page-progression-directionに相当する情報を書き込むための
    /// 公式APIが無いため(PDFExportInputのコメント参照)、見開き/読み方向の設定はこの書き出しには
    /// 反映されないことを常に表示しておく(ユーザー指示: エクスポートウインドウに見開き情報は
    /// 失われる旨の警告を記載する)。一過性の通知ではなくこの機能の恒常的な制約のため、
    /// BookmarkListView.reorderWarningMessageと違って閉じるボタンは付けない。
    private var spreadInfoWarningBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("PDF files can't store spread/reading-direction layout information. Bookmarks and title/author are exported, but the spread and reading-direction settings will be lost.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - 対象一覧

    private var selectAllBinding: Binding<Bool> {
        Binding(
            get: { !viewModel.rows.isEmpty && viewModel.selectedBookIDs.count == viewModel.rows.count },
            set: { isOn in
                if isOn {
                    viewModel.selectAll()
                } else {
                    viewModel.deselectAll()
                }
            }
        )
    }

    /// EpubExportWindow.columnHeaderRowと同じ考え方だが、カバー列は無い。
    private var columnHeaderRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: selectAllBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Select All / Deselect All")

            PDFColumnDividerLine()

            Text("File Name")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.fileName, alignment: .leading)

            PDFResizableColumnDivider(width: $columnWidths.fileName)

            Text("Title")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.title, alignment: .leading)

            PDFResizableColumnDivider(width: $columnWidths.title)

            Text("Author")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.author, alignment: .leading)

            PDFResizableColumnDivider(width: $columnWidths.author, minWidth: 60, maxWidth: 260)

            Spacer()
        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// EpubExportWindow.columnHeaderRowContainerと同じ理由(List行として揃える)。
    private var columnHeaderRowContainer: some View {
        List {
            columnHeaderRow
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .frame(height: 28)
    }

    @ViewBuilder
    private var bookListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeaderRowContainer

            List(viewModel.rows) { row in
                PDFExportRowView(row: row, viewModel: viewModel, columnWidths: columnWidths)
                    .padding(.leading, 12)
                    .padding(.trailing, 20)
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
        }
    }

    // MARK: - 出力オプション

    @ViewBuilder
    private var optionsSection: some View {
        Form {
            Toggle("Include Excluded Pages", isOn: $viewModel.includeExcludedPages)
        }
        .padding()
    }

    // MARK: - 実行ボタン

    @ViewBuilder
    private var bottomSection: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Start PDF Export…") {
                startExportButtonTapped()
            }
            .disabled(viewModel.selectedBookIDs.isEmpty || viewModel.isExporting)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func startExportButtonTapped() {
        let locale = preferences.effectiveLocale
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", locale: locale)
        panel.message = String(localized: "Choose a destination folder for the exported PDF files.", locale: locale)
        if let lastFolder = LastUsedFolderMemory.pdfExport.lastFolder() {
            panel.directoryURL = lastFolder
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        LastUsedFolderMemory.pdfExport.remember(destination)

        guard viewModel.hasSufficientDiskSpace(at: destination) else {
            insufficientSpaceMessage = String(
                localized: "The destination volume doesn't have enough free space (at least 1.2× the total size of the selected books is required). Choose a different destination, or select fewer books.",
                locale: locale
            )
            return
        }

        Task {
            await viewModel.startExport(destinationFolder: destination)
        }
    }

    // MARK: - 進捗シート

    @ViewBuilder
    private var progressSheet: some View {
        VStack(spacing: 16) {
            Text("Exporting PDF Files…")
                .font(.headline)
            ProgressView(
                value: Double(viewModel.completedCount), total: Double(max(viewModel.totalCount, 1))
            )
            .frame(width: 320)
            Text(viewModel.currentBookDisplayName ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 320)
            Text(
                String(format: String(localized: "%d of %d"), viewModel.completedCount, viewModel.totalCount)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Cancel") {
                viewModel.cancel()
            }
        }
        .padding(32)
        .frame(minWidth: 380, minHeight: 220)
        .alert(
            "Overwrite Existing File?",
            isPresented: Binding(
                get: { viewModel.pendingOverwriteBookDisplayName != nil },
                set: { _ in }
            ),
            presenting: viewModel.pendingOverwriteBookDisplayName
        ) { displayName in
            Button("Skip", role: .cancel) {
                viewModel.resolveOverwrite(.skip, applyToRemaining: false)
            }
            Button("Skip All Remaining") {
                viewModel.resolveOverwrite(.skip, applyToRemaining: true)
            }
            Button("Overwrite") {
                viewModel.resolveOverwrite(.overwrite, applyToRemaining: false)
            }
            Button("Overwrite All Remaining") {
                viewModel.resolveOverwrite(.overwrite, applyToRemaining: true)
            }
        } message: { displayName in
            Text(
                String(
                    format: String(localized: "“%@.pdf” already exists in the destination folder."), displayName
                )
            )
        }
    }

    // MARK: - 結果シート

    @ViewBuilder
    private var resultSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Complete")
                .font(.headline)
            Text(
                String(
                    format: String(localized: "%d of %d book(s) exported successfully."),
                    viewModel.successCount, viewModel.totalCount
                )
            )
            if !viewModel.failures.isEmpty {
                Text("Failed:")
                    .font(.subheadline)
                    .padding(.top, 4)
                List(viewModel.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.displayName)
                            .font(.callout)
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120)
            }
            HStack {
                Spacer()
                Button("OK") {
                    viewModel.acknowledgeFinish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: viewModel.failures.isEmpty ? 160 : 320)
    }
}

/// ファイル名列・タイトル列・著者名列の幅。EpubExportColumnWidthsと同じ考え方だが、カバー列は無い。
private struct PDFExportColumnWidths {
    var fileName: CGFloat = 170
    var title: CGFloat = 190
    var author: CGFloat = 140
}

/// EpubColumnDividerLineと同じ実装(区切り線)。
private struct PDFColumnDividerLine: View {
    static let height: CGFloat = 18
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: Self.height)
    }
}

/// EpubResizableColumnDividerと同じ実装(区切り線をドラッグして列幅を変更する)。
private struct PDFResizableColumnDivider: View {
    @Binding var width: CGFloat
    var minWidth: CGFloat = 90
    var maxWidth: CGFloat = 420

    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        PDFColumnDividerLine()
            .overlay(
                Color.clear
                    .frame(width: 8, height: PDFColumnDividerLine.height)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if widthAtDragStart == nil {
                                    widthAtDragStart = width
                                }
                                let proposed = (widthAtDragStart ?? width) + value.translation.width
                                width = min(max(proposed, minWidth), maxWidth)
                            }
                            .onEnded { _ in
                                widthAtDragStart = nil
                            }
                    )
            )
    }
}

/// EpubExportColumnWidthEstimatorと同じ実装(列幅の自動調整)。
private enum PDFExportColumnWidthEstimator {
    private static let baseChrome: CGFloat = 20

    static func idealWidth(
        for texts: [String], minWidth: CGFloat, maxWidth: CGFloat, extraChrome: CGFloat = 0
    ) -> CGFloat {
        guard !texts.isEmpty else { return minWidth }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = texts.map { text -> CGFloat in
            (text as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return min(maxWidth, max(minWidth, (widest + baseChrome + extraChrome).rounded(.up)))
    }
}

/// 一覧の1行。ExportRowView(EPUB版)と同じ構成だが、カバー列は無い。
private struct PDFExportRowView: View {
    let row: PDFExportViewModel.Row
    @ObservedObject var viewModel: PDFExportViewModel
    let columnWidths: PDFExportColumnWidths

    var body: some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { viewModel.selectedBookIDs.contains(row.bookID) },
                    set: { isOn in
                        if isOn {
                            viewModel.selectedBookIDs.insert(row.bookID)
                        } else {
                            viewModel.selectedBookIDs.remove(row.bookID)
                        }
                    }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()

            PDFColumnDividerLine()

            HStack(spacing: 4) {
                Text(row.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                FormatBadgeView(bookID: row.bookID)
            }
            .frame(width: columnWidths.fileName, alignment: .leading)

            PDFColumnDividerLine()

            TextField("", text: viewModel.titleBinding(forBookID: row.bookID))
                .textFieldStyle(.plain)
                .lineLimit(1)
                .frame(width: columnWidths.title, alignment: .leading)

            PDFColumnDividerLine()

            TextField("", text: viewModel.authorBinding(forBookID: row.bookID))
                .textFieldStyle(.plain)
                .lineLimit(1)
                .frame(width: columnWidths.author, alignment: .leading)

            PDFColumnDividerLine()

            Spacer(minLength: PDFExportContentView.indicatorLeadingGap)

            HStack(spacing: ExportIndicatorIcon.slotSpacing) {
                ExportIndicatorIcon(
                    systemName: "square.stack", isOn: row.hasLayout, help: "Has page layout settings"
                )
                ExportIndicatorIcon(
                    systemName: "bookmark.fill", isOn: row.hasBookmarks, help: "Has bookmarks"
                )
                // ユーザー要望: インジケータにメタデータを追加。
                ExportIndicatorIcon(
                    systemName: "tag.fill", isOn: row.hasMetadata, help: "Has metadata"
                )
            }
            .frame(width: PDFExportContentView.indicatorIconsWidth, alignment: .leading)
            .padding(.trailing, PDFExportContentView.indicatorTrailingGap)
        }
    }
}
