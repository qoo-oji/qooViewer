import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers


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
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var preferences: AppPreferences

    @State private var viewModel: EpubExportViewModel?

    var body: some View {
        Group {
            if let viewModel {
                EpubExportContentView(viewModel: viewModel)
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

/// EpubExportWindowの実体表示。@ObservedObjectでViewModelを直接観測するため、rows/selection/
/// isExporting等のすべての変化がここで正しく再描画される。
private struct EpubExportContentView: View {
    @ObservedObject var viewModel: EpubExportViewModel
    @EnvironmentObject private var preferences: AppPreferences
    /// ユーザー要望: 「EPUB出力を開始」ボタンの左に「キャンセル」ボタンを追加し、書き出さずに
    /// このウインドウを閉じられるようにしたい。他のウインドウ(BulkRenameBookmarksWindow等)と
    /// 同じくEnvironmentのdismissアクションでウインドウを閉じる。
    @Environment(\.dismiss) private var dismiss
    @State private var insufficientSpaceMessage: String?
    /// ファイル名列・タイトル列・著者名列・カバー列の幅。columnHeaderRow(タイトル行)と
    /// ExportRowView(各行)で共有する(ユーザー要望: タイトル列の右にカバー列を追加してほしい。
    /// タイトル列の左にファイル名列を追加してほしい。各列に表示する文字列の長さに応じて、
    /// ウインドウ幅と各列の幅を自動調整してほしい。タイトル行の区切り線をドラッグして
    /// 列の幅を調整できるようにしてほしい)。
    @State private var columnWidths = EpubExportColumnWidths()
    /// autoSizeColumnsIfNeeded()を一覧の初回表示時に1回だけ実行するためのフラグ
    /// (SidebarWidthEstimatorと同じ考え方。以降はユーザーの手動ドラッグを優先し、
    /// 内容の変化のたびに勝手にリサイズしないようにする)。
    @State private var didAutoSizeColumns = false

    /// チェックボックス列・区切り線・右端のレイアウト/ブックマークインジケータ用に確保する、
    /// 4つの可変列(ファイル名・タイトル・著者名・カバー)以外のおおよその固定幅。
    /// ユーザー要望: 右端のインジケータが見切れないようにしたい。ウインドウの最小幅
    /// (contentMinWidth参照)がこの固定幅+各列の現在の幅を必ず下回らないようにすることで、
    /// インジケータがList/ウインドウの外へはみ出して見切れることが無いようにする。
    /// 末尾の32は左右の外側パディング(.padding(.leading, 12) + .padding(.trailing, 20)、
    /// ユーザー要望: インジケータの右側にもう少しスペースを開けたい)ぶん。
    private static let fixedChromeWidth: CGFloat = 20 + 5 * 9 + trailingIndicatorWidth + 32 + 8 * 6
    /// 右端のレイアウト/ブックマークインジケータ(アイコン2個ぶんのスロット+アイコン間の
    /// 間隔)のために確保する幅の合計(indicatorLeadingGap + 16 + 6 + 16 + indicatorTrailingGap。
    /// ExportRowView参照)。ウインドウが縮んでも、この幅ぶんは常に表示領域が残るようにする。
    /// ユーザー要望によりメタデータのインジケータを追加したため、アイコンのスロットは3つ。
    fileprivate static let trailingIndicatorWidth: CGFloat =
        indicatorLeadingGap + indicatorIconsWidth + indicatorTrailingGap
    /// アイコン3つ(レイアウト/ブックマーク/メタデータ)を並べた領域の幅。
    /// スロットの寸法とアイコンの出し分け方はExportIndicatorIconにまとめてある
    /// (行ごとに並びがずれていた不具合の経緯もそちらのコメント参照)。
    fileprivate static let indicatorIconsWidth: CGFloat = ExportIndicatorIcon.totalWidth(iconCount: 3)

    /// レイアウトインジケータの左側の空白(ユーザー要望: レイアウトインジケータ左側の空白を
    /// 縮めてほしい)。
    fileprivate static let indicatorLeadingGap: CGFloat = 4
    /// ブックマークインジケータの右側の空白(ユーザー要望: ブックマークインジケータ右側の
    /// 空白をもう少し広げてほしい)。
    fileprivate static let indicatorTrailingGap: CGFloat = 14

    /// 現在の各列の幅から逆算した、ウインドウに最低限必要な幅(ユーザー要望: 右端の
    /// インジケータが見切れないようにしたい)。列の幅が(自動調整・手動ドラッグのいずれかで)
    /// 変わるたびに追随するため、ウインドウがそれより縮められることが無くなる。
    private var contentMinWidth: CGFloat {
        columnWidths.fileName + columnWidths.title + columnWidths.author + columnWidths.cover
            + Self.fixedChromeWidth
    }

    /// ユーザー要望: 各列に表示する文字列の長さに応じて、ウインドウ幅と各列の幅を自動調整して
    /// ほしい。一覧が最初に表示された時点の内容(ファイル名・タイトル・著者名)を基に、
    /// 省略表示("…")にならずに済む幅をあらかじめ計算する。SidebarWidthEstimatorと同じく、
    /// リストの内容が変わるたびに勝手にリサイズされると使い勝手が悪いため、初回表示時に
    /// 1回だけ行う(以降はユーザーの手動ドラッグ(EpubResizableColumnDivider)に委ねる)。
    private func autoSizeColumnsIfNeeded() {
        guard !didAutoSizeColumns, !viewModel.rows.isEmpty else { return }
        didAutoSizeColumns = true
        let fileNames = viewModel.rows.map(\.displayName)
        let titles = viewModel.rows.map { viewModel.titleOverrides[$0.bookID] ?? $0.displayName }
        let authors = viewModel.rows.map { viewModel.authorOverrides[$0.bookID] ?? "" }
        columnWidths.fileName = EpubExportColumnWidthEstimator.idealWidth(
            for: fileNames, minWidth: 130, maxWidth: 420, extraChrome: 44 // フォーマットバッジぶんの余白
        )
        columnWidths.title = EpubExportColumnWidthEstimator.idealWidth(for: titles, minWidth: 130, maxWidth: 420)
        columnWidths.author = EpubExportColumnWidthEstimator.idealWidth(for: authors, minWidth: 80, maxWidth: 260)
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoadingRows && viewModel.rows.isEmpty {
                // 対象一覧の絞り込み(元のファイルの実在確認)がまだ終わっていない。ここで
                // 「対象の本がありません」を出すと、実際には対象がある場合に誤解を招くため
                // 読み込み中の表示にする(viewModel.isLoadingRowsのコメント参照)。
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.rows.isEmpty {
                ContentUnavailableView(
                    "No Eligible Books",
                    systemImage: "square.and.arrow.up",
                    description: Text("Books need bookmarks, page layout settings, or metadata before they can be exported as EPUB.")
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
        .frame(minWidth: max(820, contentMinWidth), minHeight: 480)
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
    /// ファイル名列・タイトル列・カバー列(ユーザー要望: タイトル列の右にカバー画像の列を
    /// 追加してほしい。タイトル列の左には、元のファイル名を表示するファイル名列を追加して
    /// ほしい)にだけ見出しを置く。インジケータ列(レイアウト/ブックマークアイコン)には
    /// 見出し文字を付けない(ユーザー要望)。
    ///
    /// ファイル名・タイトル・著者名・カバーの4列は、それぞれ直後の区切り線をドラッグして
    /// 幅を変更できる(ユーザー要望: タイトル行の区切り線をドラッグして列の幅を調整できる
    /// ようにしてほしい。EpubResizableColumnDivider参照。チェックボックス列の直後だけは
    /// 幅固定のEpubColumnDividerLineのまま)。
    private var columnHeaderRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: selectAllBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Select All / Deselect All")

            EpubColumnDividerLine()

            // ファイル名列(ユーザー要望: タイトル列の左に、元のファイル名を表示する列を
            // 追加してほしい)。
            Text("File Name")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.fileName, alignment: .leading)

            EpubResizableColumnDivider(width: $columnWidths.fileName)

            Text("Title")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.title, alignment: .leading)

            EpubResizableColumnDivider(width: $columnWidths.title)

            // Apple Books互換性(ユーザー要望): ファイル名/フォルダ名から取得したタイトル・
            // 著者名を、この画面で編集できるようにしたい。
            Text("Author")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.author, alignment: .leading)

            EpubResizableColumnDivider(width: $columnWidths.author, minWidth: 60, maxWidth: 260)

            Text("Cover")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.cover, alignment: .leading)

            EpubResizableColumnDivider(width: $columnWidths.cover, minWidth: 80, maxWidth: 300)

            Spacer()
        }
        // ユーザー要望: インジケータの右側にもう少しスペースを開けたい(チェックボックスの
        // 左側と同じくらい)。左右の余白を非対称にし、右側を広めにとる(rows側の
        // ExportRowViewの.padding(.leading:.trailing:)と揃える。EpubExportContentView.
        // fixedChromeWidthもこの値に合わせてある)。
        .padding(.leading, 12)
        .padding(.trailing, 20)
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
                    // columnHeaderRowと同じ非対称の左右余白(ユーザー要望: インジケータの
                    // 右側にもう少しスペースを開けたい)。
                    .padding(.leading, 12)
                    .padding(.trailing, 20)
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
            // ユーザー要望: 「EPUB出力を開始」ボタンの左に「キャンセル」ボタンを追加してほしい。
            // 他のウインドウ(FavoriteFolderPickerView.bottomBar等)と同じ並び
            // (キャンセル→既定ボタン)・同じキーボードショートカットの割り当て方に揃える。
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

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
        if let lastFolder = LastUsedFolderMemory.epubExport.lastFolder() {
            panel.directoryURL = lastFolder
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        LastUsedFolderMemory.epubExport.remember(destination)

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

/// ファイル名列・タイトル列・著者名列・カバー列の幅。columnHeaderRow(タイトル行)と
/// ExportRowView(各行)で共有する(ユーザー要望: タイトル列の右にカバー画像の列を追加して
/// ほしい。さらにApple Books互換性対応で、タイトル・著者名を編集できる列を追加。
/// タイトル列の左には、元のファイル名を表示するファイル名列を追加してほしい)。
private struct EpubExportColumnWidths {
    var fileName: CGFloat = 170
    var title: CGFloat = 190
    var author: CGFloat = 140
    var cover: CGFloat = 150
}

/// 列の区切り線(ユーザー要望: このウインドウにも区切り線を追加してほしい)。BookmarkListView.
/// ColumnDividerLineと同じ考え方で、素のRectangleをHStackへ直接置く(Divider()は既定で水平線に
/// なるため使えない)。チェックボックス列の直後だけはユーザーがドラッグして広げる意味が無い
/// ためこのまま(幅固定)で使い、ファイル名・タイトル・著者名・カバーの各列の直後は
/// ドラッグ可能なEpubResizableColumnDividerを使う(ユーザー要望: タイトル行の区切り線を
/// ドラッグして列の幅を調整できるようにしてほしい)。columnHeaderRowとExportRowViewの
/// 双方でこの同じ1pt幅のRectangleだけを使う限り、ZStackの最大サイズ問題(BookmarkListViewで
/// 経験した不具合)は起こりえない。
private struct EpubColumnDividerLine: View {
    static let height: CGFloat = 18
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: Self.height)
    }
}

/// 区切り線をドラッグして、直前の列の幅(width、双方向Binding)を変更するためのハンドル
/// (ユーザー要望: タイトル行の区切り線をドラッグして列の幅を調整できるようにしてほしい)。
/// BookmarkListView.ResizableColumnDividerと全く同じ考え方・同じ実装(見た目はEpubColumnDividerLine
/// と完全に同じ1pt線のままレイアウトさせ、掴みやすくするための8pt幅の判定領域は.overlayとして
/// 重ねることで、見た目の線とレイアウト上の幅を一致させる。ZStackで重ねると実際より広い幅を
/// 親のHStackへ報告してしまい列がずれるため、あえてoverlayにしている)。ヘッダー行
/// (columnHeaderRow)だけで使い、各行(ExportRowView)側はドラッグ操作を持たない見た目だけの
/// EpubColumnDividerLine()のままにする(カバー列のpopover等、既にジェスチャーが載っている
/// ため、列幅の変更操作はFinderのリスト表示などと同じくヘッダー行からだけ行える形にする)。
private struct EpubResizableColumnDivider: View {
    @Binding var width: CGFloat
    var minWidth: CGFloat = 90
    var maxWidth: CGFloat = 420

    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        EpubColumnDividerLine()
            .overlay(
                Color.clear
                    .frame(width: 8, height: EpubColumnDividerLine.height)
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

/// EPUB出力ウインドウの各列(ファイル名・タイトル・著者名)の幅を、ウインドウを開いた時点の
/// 一覧の内容に応じて自動調整するための計算ロジック(ユーザー要望: 各列に表示する文字列の
/// 長さに応じて、ウインドウ幅と各列の幅を自動調整してほしい)。SidebarWidthEstimatorと
/// 同じ考え方・同じ実装パターン(NSStringのサイズ計測を使う)。
private enum EpubExportColumnWidthEstimator {
    /// テキスト自体の幅以外に、列の左右パディングなどでおおよそ必要になる余白。
    private static let baseChrome: CGFloat = 20

    /// - Parameters:
    ///   - texts: この列に実際に表示されるテキストの一覧。
    ///   - extraChrome: baseChromeに加えて確保しておきたい余白(例: フォーマットバッジの分)。
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

            // ファイル名列(ユーザー要望: タイトル列の左に、元のファイル名を表示する列を
            // 追加してほしい)。拡張子付きの実際のファイル名/フォルダ名をそのまま表示する。
            HStack(spacing: 4) {
                Text(row.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                FormatBadgeView(bookID: row.bookID)
            }
            .frame(width: columnWidths.fileName, alignment: .leading)

            EpubColumnDividerLine()

            // タイトル列(ユーザー要望: Apple Books互換性。ファイル名/フォルダ名から取得した
            // タイトルを、この画面で変更できるようにしたい)。
            TextField("", text: viewModel.titleBinding(forBookID: row.bookID))
                .textFieldStyle(.plain)
                .lineLimit(1)
                .frame(width: columnWidths.title, alignment: .leading)

            EpubColumnDividerLine()

            // 著者名列(ユーザー要望: Apple Books互換性。ファイル名/フォルダ名から取得した
            // 著者名を、この画面で変更できるようにしたい)。
            TextField("", text: viewModel.authorBinding(forBookID: row.bookID))
                .textFieldStyle(.plain)
                .lineLimit(1)
                .frame(width: columnWidths.author, alignment: .leading)

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

            // レイアウト/ブックマークのインジケータ(ユーザー要望: 右のインジケータが
            // 見切れないようにしたい。さらにレイアウトインジケータの左側は詰め、
            // ブックマークインジケータの右側はもう少し広めに空けたい)。アイコンそれぞれを
            // 固定幅のスロットに収めることで、片方だけしか無い行でも位置がずれず、かつ
            // 列全体としてはEpubExportContentView.trailingIndicatorWidthぶんを確保して
            // ウインドウが縮んでも見切れないようにする(EpubExportContentView.contentMinWidth
            // 参照)。
            Spacer(minLength: EpubExportContentView.indicatorLeadingGap)

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
            .frame(width: EpubExportContentView.indicatorIconsWidth, alignment: .leading)
            .padding(.trailing, EpubExportContentView.indicatorTrailingGap)
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
                        CoverPickerPageRow(
                            page: page,
                            index: index,
                            pageLoader: pageLoader,
                            thumbnails: $thumbnails,
                            onSelect: { viewModel.setCover(forBookID: bookID, book: loadedBook, page: page) }
                        )
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

/// カバー選択画面(CoverPickerContent)の一覧の1行。ページを選ぶボタンに加えて、小さな
/// サムネイルにカーソルを乗せている間、拡大プレビューをpopoverで表示する(ユーザー要望:
/// このサムネイルも他の一覧と同じように大きく確認できるようにしたい)。
/// BookmarkListView.PageRowViewのホバー拡大プレビューと同じ考え方・同じ実装パターン
/// (350msの遅延の後にだけpopoverを出す。ドラッグ操作等は無いためここでは単純にホバー判定だけ)。
private struct CoverPickerPageRow: View {
    let page: PageRef
    let index: Int
    let pageLoader: PageLoader?
    /// 小さいサムネイル画像のキャッシュ。CoverPickerContent側の@Stateを共有し、
    /// popoverを開閉しても読み込み直さないようにする(BookmarkListView.thumbnailsと同じ考え方)。
    @Binding var thumbnails: [String: CGImage]
    let onSelect: () -> Void

    /// カーソルが小さいサムネイルの上にあるかどうか(拡大プレビュー用のpopoverの表示制御)。
    @State private var isHoveringThumbnail = false
    /// 拡大プレビュー用のフル解像度画像。一度読み込めば、同じ行を何度ホバーしても読み込み直さない
    /// よう@Stateにキャッシュしておく。
    @State private var previewImage: CGImage?
    /// ホバー開始から実際にpopoverを出すまでの遅延用タスク。
    @State private var hoverPreviewTask: Task<Void, Never>?
    /// ホバー開始から実際にpopoverを出すまでの遅延(ナノ秒)。BookmarkListView.PageRowViewと同じ値。
    private static let hoverPreviewDelayNanoseconds: UInt64 = 350_000_000

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 8) {
                thumbnailView
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

    @ViewBuilder
    private var thumbnailView: some View {
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
        // ユーザー要望: サムネイルにカーソルを乗せている間、拡大プレビューとファイル名を
        // 表示したい。BookmarkListView.PageRowViewと同じく、ホバーした瞬間に即座にpopoverを
        // 出さず、一定時間(hoverPreviewDelayNanoseconds)ホバーし続けた場合にだけ表示する。
        .onHover { hovering in
            hoverPreviewTask?.cancel()
            if hovering {
                hoverPreviewTask = Task {
                    try? await Task.sleep(nanoseconds: Self.hoverPreviewDelayNanoseconds)
                    guard !Task.isCancelled else { return }
                    isHoveringThumbnail = true
                }
            } else {
                hoverPreviewTask = nil
                isHoveringThumbnail = false
            }
        }
        .popover(isPresented: $isHoveringThumbnail, arrowEdge: .trailing) {
            thumbnailPreviewContent
        }
    }

    /// サムネイルをホバーしたときのpopoverの中身。フル解像度画像(previewImage)とファイル名を
    /// 縦に並べる。BookmarkListView.PageRowView.thumbnailPreviewContentと同じ構成・同じサイズ
    /// (440x440)。
    private var thumbnailPreviewContent: some View {
        VStack(spacing: 8) {
            Group {
                if let previewImage {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 440, height: 440)

            Text(page.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(12)
        .task {
            guard previewImage == nil, let pageLoader else { return }
            previewImage = await pageLoader.pageImage(at: index)
        }
    }
}
