import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// zipからコレクション表紙を読み込むウインドウ(ユーザー要望 2026-09-11)。
///
/// 形は他の一覧ウインドウ(「メタデータの編集」「本ごとの保存データの削除」「履歴の削除」等)と
/// 共通 ―― 操作するものはツールバー、一覧はその下へスクロールして潜り、件数は下部中央の
/// ステータスバーに出る。
///
/// ■ 必ず確認を挟む
/// ファイルを選んだ瞬間に取り込まず、**どの画像がどの本に入るのかを一覧で見せてから**
/// 「読み込む」で確定する。名前での照合は当たり外れがあり(同じ名前の本、名前を変えた本)、
/// 黙って入れてしまうと、どの表紙がいつ差し替わったのか後から辿れない。
struct ShelfCoverImportWindow: View {
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel: ShelfCoverImportViewModel?

    var body: some View {
        Group {
            if let viewModel {
                ShelfCoverImportContentView(viewModel: viewModel)
            } else {
                Color.clear
                    .onAppear {
                        viewModel = ShelfCoverImportViewModel(
                            sources: KnownBooks.Sources(
                                metadataStore: metadataStore, bookmarkStore: bookmarkStore,
                                layoutStore: layoutStore, favoritesStore: favoritesStore,
                                collectionStore: collectionStore, modelContext: modelContext
                            ),
                            preferences: preferences
                        )
                    }
            }
        }
        .frame(minWidth: 900, minHeight: 480)
    }
}

/// 実体。ViewModelを`@ObservedObject`で直接観測する。
///
/// **バグ修正(ユーザー報告 2026-09-11): 当初は親の`@State`に入れたViewModelを1つのビューから
/// 直に読んでいた。`@State`はObservableObjectの`@Published`を観測しないので、zipを選んでも
/// 一覧が出てこなかった**(「ファイルを選択してもウインドウの状態が変化しない」)。
/// 「メタデータの編集」と同じ2段構え ―― 親が作って持ち、子が観測する ―― に直してある。
private struct ShelfCoverImportContentView: View {
    @ObservedObject var viewModel: ShelfCoverImportViewModel
    /// 列幅の実測に使う表示言語(他の一覧ウインドウと同じ理由・同じ書き方)。
    @Environment(\.locale) private var locale

    @State private var columnCustomization = TableColumnCustomization<ShelfCoverImportViewModel.Row>()
    @State private var entryColumnWidth: CGFloat = ShelfCoverImportContentView.entryColumnMin
    @State private var bookColumnWidth: CGFloat = ShelfCoverImportContentView.bookColumnMin
    @State private var didAutoSizeColumns = false

    // 列の実測幅の上限は、**既定のウインドウ幅(760)に収まる合計**にしてある。
    // 合計がそれを超えると、SwiftUIがその理想幅に合わせてウインドウを広く開いてしまい、
    // ツールバーに空きができて検索欄が畳まれない(実測 2026-09-11: 上限が広すぎて900ptで
    // 開いていた)。足りないときは利用者が列の境目をドラッグして広げられる。
    private static let entryColumnMin: CGFloat = 160
    private static let entryColumnMax: CGFloat = 240
    private static let bookColumnMin: CGFloat = 220
    private static let bookColumnMax: CGFloat = 260
    private static let statusColumnWidth: CGFloat = 220

    var body: some View {
        NavigationStack {
            Group {
                if !viewModel.rows.isEmpty {
                    rowTable
                } else {
                    emptyState
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                statusBar
            }
            .toolbar { toolbarItems }
            .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: Text("Search"))
            .hardTopScrollEdgeEffect()
        }
        .onChange(of: viewModel.rows.count) { _, _ in autoSizeColumnsIfNeeded() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Collection Covers Loaded",
                systemImage: "photo.on.rectangle.angled",
                description: Text(
                    "Choose a zip file of collection covers. Each image is matched to a book by its file name, and you can check the result before importing."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                chooseFile()
            } label: {
                Label("Choose File…", systemImage: "doc.badge.plus")
            }
            .labelStyle(.titleAndIcon)
            .disabled(viewModel.isLoading || viewModel.isApplying)

            Toggle(isOn: Binding(
                get: { isEveryMatchedRowSelected },
                set: { viewModel.setAllSelected($0) }
            )) {
                Label("Select All", systemImage: "checkmark.rectangle.stack")
            }
            .toggleStyle(.button)
            .labelStyle(.titleAndIcon)
            .help("Select All / Deselect All")
            .disabled(viewModel.rows.isEmpty)

            if viewModel.isApplying {
                ProgressView().controlSize(.small)
            }

            Button {
                Task { await viewModel.apply() }
            } label: {
                Label("Import Collection Covers", systemImage: "square.and.arrow.down")
            }
            .labelStyle(.titleAndIcon)
            .disabled(viewModel.importableCount == 0 || viewModel.isApplying)
        }
    }

    private var isEveryMatchedRowSelected: Bool {
        let selectable = viewModel.rows.filter { $0.candidates.count == 1 }
        return !selectable.isEmpty && selectable.allSatisfy { $0.selectedBookID != nil }
    }

    // MARK: - 一覧

    private var rowTable: some View {
        Table(viewModel.shownRows, columnCustomization: $columnCustomization) {
            TableColumn("Image in the Zip") { row in
                Text(row.entryName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.entryName)
            }
            .width(min: Self.entryColumnMin, ideal: entryColumnWidth)
            .customizationID("entry")
            .disabledCustomizationBehavior([.reorder, .visibility])

            TableColumn("Status") { row in
                Text(viewModel.statusText(for: row))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(statusColor(for: row))
            }
            .width(Self.statusColumnWidth)
            .disabledCustomizationBehavior(.all)

            TableColumn("Book") { row in
                ShelfCoverImportBookCell(row: row, viewModel: viewModel)
            }
            .width(min: Self.bookColumnMin, ideal: bookColumnWidth)
            .customizationID("book")
            .disabledCustomizationBehavior([.reorder, .visibility])
        }
        // 自動調整が済んだ時点で一度だけ作り直す(他の一覧ウインドウと同じ理由)。
        .id(didAutoSizeColumns)
    }

    private func statusColor(for row: ShelfCoverImportViewModel.Row) -> Color {
        if case .rejected = row.verdict { return .orange }
        if row.candidates.isEmpty { return .secondary }
        if row.selectedBookID == nil { return .orange }
        return .primary
    }

    /// 列幅を、実際に並ぶ文字列の長さから決める(他の一覧ウインドウと同じ部品)。
    private func autoSizeColumnsIfNeeded() {
        guard !didAutoSizeColumns, !viewModel.rows.isEmpty else { return }
        entryColumnWidth = ExportColumnWidthEstimator.idealWidth(
            for: viewModel.rows.map(\.entryName),
            minWidth: Self.entryColumnMin, maxWidth: Self.entryColumnMax, extraChrome: 12
        )
        bookColumnWidth = ExportColumnWidthEstimator.idealWidth(
            for: viewModel.rows.map { $0.selectedBookID ?? $0.candidates.first ?? "" },
            minWidth: Self.bookColumnMin, maxWidth: Self.bookColumnMax,
            extraChrome: 32 // メニューの矢印ぶん
        )
        didAutoSizeColumns = true
    }

    // MARK: - 下部

    private var statusBar: some View {
        ListWindowStatusBar {
            Group {
                Text("\(viewModel.shownRows.count) of \(viewModel.rows.count) images shown")

                if viewModel.importableCount > 0 {
                    ListWindowStatusSeparator()
                    Text("\(viewModel.importableCount) will be imported")
                        .monospacedDigit()
                }
                if !viewModel.ignoredEntryNames.isEmpty {
                    ListWindowStatusSeparator()
                    Text("\(viewModel.ignoredEntryNames.count) skipped")
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
    }

    // MARK: - ファイルを選ぶ

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.message = String(
            localized: "Choose a zip file of collection covers to import.", language: locale
        )
        if let lastFolder = LastUsedFolderMemory.libraryIO.lastFolder() {
            panel.directoryURL = lastFolder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LastUsedFolderMemory.libraryIO.remember(url.deletingLastPathComponent())
        didAutoSizeColumns = false
        Task {
            await viewModel.load(zipAt: url)
            autoSizeColumnsIfNeeded()
        }
    }
}

/// 「本」列のセル。候補から選び直せるメニューを出す。
///
/// 候補が1つでもメニューにしてあるのは、**取り込まない**という選択を必ず残すため
/// (名前が偶然一致しただけの本に、意図せず表紙が入るのを防ぐ)。
private struct ShelfCoverImportBookCell: View {
    let row: ShelfCoverImportViewModel.Row
    @ObservedObject var viewModel: ShelfCoverImportViewModel

    var body: some View {
        if case .rejected = row.verdict {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
        } else if row.candidates.isEmpty {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
        } else {
            Menu {
                Button("Don't Import") {
                    viewModel.setSelection(nil, for: row.id)
                }
                Divider()
                ForEach(row.candidates, id: \.self) { bookID in
                    Button {
                        viewModel.setSelection(bookID, for: row.id)
                    } label: {
                        if row.selectedBookID == bookID {
                            Label(bookID, systemImage: "checkmark")
                        } else {
                            Text(bookID)
                        }
                    }
                }
            } label: {
                Text(row.selectedBookID ?? String(localized: "Don't Import"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.selectedBookID == nil ? Color.secondary : Color.primary)
            }
            .menuStyle(.borderlessButton)
            .help(row.selectedBookID ?? "")
        }
    }
}
