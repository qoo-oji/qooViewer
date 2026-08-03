import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// 出力先フォルダパネル(NSOpenPanel、canChooseDirectories = true)が最後に開いたフォルダを
/// 記憶する(7.3節)。JSON入出力のLibraryIOFolderMemoryと同じ仕組みだが、目的(EPUB出力先)が
/// 異なるため別のUserDefaultsキーを使う専用の仕組みとして分離している。
private enum EpubExportFolderMemory {
    private static let defaultsKey = "qooViewer.pref.lastEpubExportFolderBookmark"

    static func lastFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
        )
    }

    static func remember(_ folderURL: URL) {
        guard let data = try? folderURL.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// 設計コンセプト7節: EPUB出力専用ウインドウ。File メニューの「epub出力…」から開く。
/// 「ブックマーク・レイアウトの編集」ウインドウと同じく、本を今開いているかどうかに関わらず
/// いつでも開ける独立ウインドウ。
///
/// EpubExportViewModelはbookmarkStore/layoutStore(@EnvironmentObject)を受け取ってから
/// 組み立てる必要があり、宣言時のデフォルト値だけでは初期化できない(QooViewerApp.init()が
/// favoritesStore等を組み立てるのと同じ制約)。そのため、まず素の@State(参照を保持するだけ)で
/// 持っておき、.onAppearで実際に組み立てた後は、実体の表示・すべての状態観測は
/// @ObservedObjectを持つ子ビュー(EpubExportContentView)に委ねる(親のEpubExportWindow自身は
/// ViewModelを観測していないため、子ビューを分けないと@Publishedプロパティの変化が
/// 再描画に反映されない)。
struct EpubExportWindow: View {
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore

    @State private var viewModel: EpubExportViewModel?

    var body: some View {
        Group {
            if let viewModel {
                EpubExportContentView(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(minWidth: 520, minHeight: 480)
                    .onAppear {
                        viewModel = EpubExportViewModel(bookmarkStore: bookmarkStore, layoutStore: layoutStore)
                    }
            }
        }
    }
}

/// EpubExportWindowの実体表示。@ObservedObjectでViewModelを直接観測するため、rows/selection/
/// isExporting等のすべての変化がここで正しく再描画される。
private struct EpubExportContentView: View {
    @ObservedObject var viewModel: EpubExportViewModel
    @EnvironmentObject private var preferences: AppPreferences
    @State private var insufficientSpaceMessage: String?
    /// タイトル列・カバー列の幅。columnHeaderRow(タイトル行)とExportRowView(各行)で共有する
    /// (ユーザー要望: タイトル列の右にカバー列を追加してほしい)。
    @State private var columnWidths = EpubExportColumnWidths()

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.rows.isEmpty {
                ContentUnavailableView(
                    "No Eligible Books",
                    systemImage: "square.and.arrow.up",
                    description: Text("Books need bookmarks or page layout settings before they can be exported as EPUB. (PDF and EPUB source files aren't eligible.)")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                bookListSection
            }

            Divider()
            optionsSection
            Divider()
            bottomSection
        }
        .frame(minWidth: 520, minHeight: 480)
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

    // MARK: - 対象一覧(7.1節)

    /// 一覧のすべての行が選択されているかどうか。タイトル行のチェックボックス
    /// (columnHeaderRow参照)と双方向に結び付けることで、チェックすると全選択、外すと
    /// 全選択解除になる(ユーザー要望: 上部の「選択」メニュー・「選択解除」ボタンを廃止し、
    /// タイトル行のチェックボックスに一本化する)。
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

    /// 一覧のタイトル行。各行(ExportRowView)と列の位置を揃えるため、チェックボックス列・
    /// タイトル列・カバー列(ユーザー要望: タイトル列の右にカバー画像の列を追加してほしい)に
    /// だけ見出しを置く。インジケータ列(レイアウト/ブックマークアイコン)には見出し文字を
    /// 付けない(ユーザー要望)。
    private var columnHeaderRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: selectAllBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Select All / Deselect All")

            EpubColumnDividerLine()

            Text("Title")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.title, alignment: .leading)

            EpubColumnDividerLine()

            Text("Cover")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.cover, alignment: .leading)

            EpubColumnDividerLine()

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// columnHeaderRowを、実際の本一覧(下のList(viewModel.rows))と全く同じ「List行」として
    /// 描画するための入れ物。Listの内側と外側とでは余白の計算パイプラインが異なり、素の
    /// HStackのままだとチェックボックスの位置が行とわずかにずれることがある(BookmarkListView.
    /// columnHeaderRowContainerで実際に経験した不具合と同じ)ため、ここも同じ考え方で
    /// 小さな非スクロールListに収めている。
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
                ExportRowView(row: row, viewModel: viewModel, columnWidths: columnWidths)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
        }
    }

    // MARK: - 出力オプション(7.2節)

    @ViewBuilder
    private var optionsSection: some View {
        Form {
            Toggle("Renumber Image Files Sequentially", isOn: $viewModel.renumberImagesSequentially)
            Toggle("Include Excluded Pages", isOn: $viewModel.includeExcludedPages)
        }
        .padding()
    }

    // MARK: - 実行ボタン

    @ViewBuilder
    private var bottomSection: some View {
        HStack {
            Spacer()
            Button("Start EPUB Export…") {
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
        panel.message = String(localized: "Choose a destination folder for the exported EPUB files.", locale: locale)
        if let lastFolder = EpubExportFolderMemory.lastFolder() {
            panel.directoryURL = lastFolder
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        EpubExportFolderMemory.remember(destination)

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
            Text("Exporting EPUB Files…")
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
        // 同名ファイルの確認(7.3節)は、書き出し中(進捗シートの表示中)にだけ起こりうる操作の
        // ため、あえてこの進捗シート自身にalertを付ける(親ビュー側に付けると、進捗シートの
        // 上に正しく重なって表示されない可能性があるため)。
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
                    format: String(localized: "“%@.epub” already exists in the destination folder."), displayName
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

/// タイトル列・カバー列の幅。columnHeaderRow(タイトル行)とExportRowView(各行)で共有する
/// (ユーザー要望: タイトル列の右にカバー画像の列を追加してほしい)。
private struct EpubExportColumnWidths {
    var title: CGFloat = 220
    var cover: CGFloat = 180
}

/// 列の区切り線(ユーザー要望: このウインドウにも区切り線を追加してほしい)。BookmarkListView.
/// ColumnDividerLineと同じ考え方で、素のRectangleをHStackへ直接置く(Divider()は既定で水平線に
/// なるため使えない)。この列は幅固定でユーザーがドラッグして広げることはないため、
/// BookmarkListView.ResizableColumnDividerのようなドラッグ用ヒットエリアは不要で、
/// columnHeaderRowとExportRowViewの双方でこの同じ1pt幅のRectangleだけを使う限り、ZStackの
/// 最大サイズ問題(BookmarkListViewで経験した不具合)は起こりえない。
private struct EpubColumnDividerLine: View {
    static let height: CGFloat = 18
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: Self.height)
    }
}

/// 一覧の1行。カバー列はボタンでpopoverを開き、本に含まれる画像またはそれ以外のファイルから
/// カバー画像を選べるようにする(ユーザー要望: カバー画像はデフォルトで最初の画像を使い、
/// このウインドウから変更できるようにしたい)。
private struct ExportRowView: View {
    let row: EpubExportViewModel.Row
    @ObservedObject var viewModel: EpubExportViewModel
    let columnWidths: EpubExportColumnWidths

    @State private var isCoverPickerPresented = false

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

            EpubColumnDividerLine()

            HStack(spacing: 4) {
                Text(row.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                FormatBadgeView(bookID: row.bookID)
            }
            .frame(width: columnWidths.title, alignment: .leading)

            EpubColumnDividerLine()

            // カバー列(ユーザー要望)。現在カバー画像として使われることになっているファイル名を
            // 表示し、クリックすると本のページ一覧/外部ファイルから選び直せるpopoverを開く。
            Button {
                isCoverPickerPresented = true
            } label: {
                HStack(spacing: 4) {
                    Text(viewModel.coverDisplayName(forBookID: row.bookID))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .frame(width: columnWidths.cover, alignment: .leading)
            .help("Change Cover Image")
            .popover(isPresented: $isCoverPickerPresented) {
                CoverPickerContent(bookID: row.bookID, viewModel: viewModel)
            }

            EpubColumnDividerLine()

            Spacer()

            if row.hasLayout {
                Image(systemName: "square.stack")
                    .foregroundStyle(.secondary)
                    .help("Has page layout settings")
            }
            if row.hasBookmarks {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.secondary)
                    .help("Has bookmarks")
            }
        }
        // カバー列の表示名は、上書き設定が無い場合(既定=先頭ページ)は本を読み込んで確認する
        // 必要があるため非同期で解決する(BookmarkListView.PageRowViewのサムネイル読み込みと
        // 同じ考え方)。
        .task(id: row.bookID) {
            await viewModel.refreshCoverName(forBookID: row.bookID)
        }
    }
}

/// カバー画像の選択画面(ユーザー要望: 本に含まれる画像の中から選べることは勿論、本に含まれて
/// いない画像ファイルをカバー画像専用として追加することもできるようにしたい)。ExportRowViewの
/// カバー列ボタンからpopoverとして開く。
///
/// 追加した専用ファイルはLayoutStore.setExternalCoverが本(MangaBook.pages)には一切追加しない
/// (BookLayoutSettingsの別プロパティとして保持するだけ)ため、ビューアのページ一覧には
/// 現れない(ユーザー要望通り)。
private struct CoverPickerContent: View {
    let bookID: String
    @ObservedObject var viewModel: EpubExportViewModel

    @State private var loadedBook: MangaBook?
    @State private var loadFailed = false
    @State private var pageLoader: PageLoader?
    @State private var thumbnails: [String: CGImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                viewModel.resetCover(forBookID: bookID)
            } label: {
                Label("Reset to Default (First Page)", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .padding(8)

            Divider()

            Group {
                if let loadedBook {
                    List(Array(loadedBook.pages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            viewModel.setCover(forBookID: bookID, book: loadedBook, page: page)
                        } label: {
                            HStack(spacing: 8) {
                                pageThumbnail(for: page)
                                Text(page.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .task(id: page.id) {
                            guard thumbnails[page.id] == nil, let pageLoader else { return }
                            thumbnails[page.id] = await pageLoader.thumbnail(at: index)
                        }
                    }
                    .frame(minWidth: 260, minHeight: 260)
                } else if loadFailed {
                    Text("Could not open this book.")
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(minWidth: 260, minHeight: 120)
                } else {
                    ProgressView()
                        .padding()
                        .frame(minWidth: 260, minHeight: 120)
                }
            }

            Divider()

            Button {
                chooseExternalFile()
            } label: {
                Label("Choose File…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.plain)
            .padding(8)
            .disabled(loadedBook == nil)
        }
        .task {
            guard loadedBook == nil else { return }
            guard let book = await viewModel.loadBookForCoverPicker(bookID: bookID) else {
                loadFailed = true
                return
            }
            loadedBook = book
            pageLoader = PageLoader(book: book)
        }
    }

    @ViewBuilder
    private func pageThumbnail(for page: PageRef) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let image = thumbnails[page.id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 32, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func chooseExternalFile() {
        guard let loadedBook else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose an image file to use as the cover.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.setExternalCover(forBookID: bookID, book: loadedBook, fileURL: url)
    }
}
