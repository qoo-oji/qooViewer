import SwiftUI
import SwiftData
import AppKit

/// ユーザー要望: 検証用に開いただけの本など、DBに残ったままの不要なデータを個別に消したい。
/// チェックボックス・ファイルパス・ファイルが実在するかどうか・登録データのインジケータ・
/// 削除ボタンを持つ専用ウインドウ。「履歴の削除」(HistoryCleanupWindow)と対になる画面で、
/// クロームの置き方・件数表示の位置・文言の形はそちらと揃えてある。
/// 環境設定の「リセット」タブからのみ開ける
/// (ResetDataSettingsView参照。日常的に押す種類のボタンではないため、他の画面には置かない)。
///
/// MetadataEditorWindowと同じ構成: ViewModelは複数の@EnvironmentObjectを受け取ってから
/// 組み立てる必要があるため、まず素の@Stateで持ち、実体の表示・状態観測は@ObservedObjectを持つ
/// 子ビューへ委ねる。
struct LibraryCleanupWindow: View {
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel: LibraryCleanupViewModel?

    var body: some View {
        Group {
            if let viewModel {
                LibraryCleanupContentView(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(minWidth: 900, minHeight: 460)
                    .onAppear {
                        viewModel = LibraryCleanupViewModel(
                            favoritesStore: favoritesStore,
                            bookmarkStore: bookmarkStore,
                            layoutStore: layoutStore,
                            metadataStore: metadataStore,
                            folderAccess: folderAccess,
                            modelContext: modelContext
                        )
                    }
            }
        }
    }
}

private struct LibraryCleanupContentView: View {
    @ObservedObject var viewModel: LibraryCleanupViewModel
    /// 列幅の実測に使う表示言語。環境設定で切り替わるので、OSのロケールではなくこれを見る
    /// (メタデータの編集ウインドウのactionColumnWidthと同じ理由・同じ書き方)。
    @Environment(\.locale) private var locale

    /// ユーザーがタイトル行の区切り線をドラッグして変えた列幅の保持先。他の一覧ウインドウ
    /// (メタデータの編集・書き出し3種)は列幅を自由に変えられるのに、このウインドウだけ
    /// 変えられなかった(ユーザー指摘: 似た構成なのに片方だけできないのはUXとしてだめ)。
    @State private var columnCustomization = TableColumnCustomization<LibraryCleanupViewModel.Row>()
    /// パス列の「開いた直後の幅」。実際に並ぶパスの長さを実測して決める(下のautoSizeColumnsIfNeeded)。
    @State private var pathColumnWidth: CGFloat = LibraryCleanupContentView.pathColumnMin
    /// 自動調整を、行が出そろった時点で1回だけ実行するためのフラグ(以降はユーザーの
    /// ドラッグを優先し、削除のたびに勝手にリサイズしない。書き出しウインドウと同じ考え方)。
    @State private var didAutoSizeColumns = false

    /// パス列がこれ以上狭くならない下限と、自動調整の上限。
    private static let pathColumnMin: CGFloat = 220
    private static let pathColumnMax: CGFloat = 620

    /// 削除確認の対象。nilの間は確認ダイアログを出さない。
    /// 行の削除ボタンによる1冊だけの削除と、チェックボックスで選んだ複数冊の削除の両方を
    /// この1つの状態で扱う。
    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion: Identifiable {
        /// 1冊だけの場合はその表示名、まとめて削除の場合はnil。
        let displayName: String?
        let bookIDs: [String]
        /// 確認ダイアログを出し分けるためだけの識別子。bookIDsを連結して作ると、
        /// 数千冊を選んだときに巨大な文字列が毎回できてしまうため、
        /// この構造体を作るときに1つ振る。
        let id = UUID()
    }

    /// クローム(絞り込み・すべて選択・選択した項目を削除・検索欄)はコンテンツ領域ではなく
    /// ウインドウのツールバーに置き、一覧はその下へスクロールして潜る。「メタデータの編集」
    /// 「EPUB/PDF/CBZの書き出し」「ブックマーク・レイアウトの編集」「お気に入りの整理」と
    /// 同じ形(ユーザー指摘: このウインドウだけ古い作りだった)。
    ///
    /// `.searchable`はナビゲーションコンテナの中でだけツールバーへ載るため、Tableを
    /// NavigationStackで包んでいる。素のVStackに付けるとツールバーに出ない(実測)。
    var body: some View {
        NavigationStack {
            Group {
                if viewModel.rows.isEmpty {
                    ContentUnavailableView(
                        viewModel.totalRowCount == 0 ? "No Saved Book Data" : "No Matching Books",
                        systemImage: viewModel.totalRowCount == 0 ? "internaldrive" : "magnifyingglass",
                        description: Text(
                            viewModel.totalRowCount == 0
                                ? "qooViewer isn't storing data for any book yet."
                                : "No book matches the current filter or search text."
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    bookTable
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                statusBar
            }
            .toolbar {
                toolbarItems
            }
            // ツールバー右端のネイティブな検索欄。ウインドウが狭いと自動で虫眼鏡に畳まれる。
            // 自前のTextFieldに付けていた`.releasesFocusOnOutsideClick()`は、ネイティブの
            // 検索欄がEsc・欄外クリックでのフォーカス解除を自前で持つため不要になった。
            .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: Text("Search"))
            // ツールバーの下へ潜る一覧の、上端の縁の効果(ScrollEdgeEffect.swift参照)。
            .hardTopScrollEdgeEffect()
        }
        .frame(minWidth: 900, minHeight: 480)
        // 一覧はDBから同期に埋まるが、実在判定は後から入る。表示直後と行が入った瞬間の
        // 両方で試みる(実際に走るのは最初の1回だけ。書き出しウインドウと同じ)。
        .onAppear { autoSizeColumnsIfNeeded() }
        .onChange(of: viewModel.totalRowCount) { _, _ in autoSizeColumnsIfNeeded() }
        .alert(item: $pendingDeletion) { deletion in
            Alert(
                title: Text(
                    deletion.displayName == nil
                        ? "Delete saved data for \(deletion.bookIDs.count) books?"
                        : "Delete saved data for “\(deletion.displayName ?? "")”?"
                ),
                message: Text(
                    "This permanently deletes the favorites, bookmarks, page layout settings, metadata, and reading history qooViewer has saved for this. The file itself is not touched. This cannot be undone."
                ),
                primaryButton: .destructive(Text("Delete")) {
                    viewModel.deleteAllData(forBookIDs: deletion.bookIDs)
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - ツールバー

    /// 絞り込み・すべて選択・選択した項目を削除。並び順と見た目は、同じ役割の項目を持つ他の
    /// ウインドウに揃えてある(絞り込みのPicker = ブックマーク・レイアウトの編集、
    /// すべて選択のトグル = 書き出しウインドウ)。
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            // 絞り込み。ツールバーの上ではLabel項目のPickerは既定だとアイコンだけに畳まれて
            // 選択中の文字が消えるため、.labelStyle(.titleAndIcon)を明示する
            // (BookmarkListViewの「Filter Books」と同じ書き方・同じ理由)。
            Picker(selection: $viewModel.filter) {
                ForEach(LibraryCleanupViewModel.Filter.allCases) { filter in
                    Label {
                        Text(filter.titleKey)
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .tag(filter)
                }
            } label: {
                Text("Filter Books")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .help("Filter Books")

            // すべて選択/すべて選択解除。ツールバーにチェックボックスは載らないため、
            // 押している間だけ色が付くトグルボタンにする(書き出しウインドウと同じ形・
            // 同じアイコン)。対象は**今一覧に出ている行だけ**で、絞り込みで隠れている行の
            // 選択には触れない(LibraryCleanupViewModel.setAllShownRowsSelected参照)。
            Toggle(isOn: Binding(
                get: { viewModel.isEveryShownRowSelected },
                set: { viewModel.setAllShownRowsSelected($0) }
            )) {
                Label("Select All", systemImage: "checkmark.rectangle.stack")
            }
            .toggleStyle(.button)
            .labelStyle(.titleAndIcon)
            .help("Select All / Deselect All")
            .disabled(viewModel.rows.isEmpty)

            Button(role: .destructive) {
                pendingDeletion = PendingDeletion(
                    displayName: nil,
                    bookIDs: Array(viewModel.selectedBookIDs)
                )
            } label: {
                Label("Delete Selected…", systemImage: "trash")
            }
            .labelStyle(.titleAndIcon)
            .help("Delete Selected…")
            .disabled(viewModel.selectedBookIDs.isEmpty)
        }
    }

    // MARK: - 下部

    /// 件数の表示。位置・見た目は他の一覧ウインドウと共通(ListWindowStatusBar参照)。
    ///
    /// 選択は絞り込み・検索をまたいで残る(LibraryCleanupViewModel.selectedBookIDs参照)ため、
    /// 「今いくつ消えるのか」が一覧を見ただけでは分からないことがある。選択件数を常に出しておく。
    /// 実在確認の進行中表示と「見つからない件数」も、以前は上部の自前の行に置いていたが、
    /// どちらも操作ではなく状態なのでここへ移した。
    private var statusBar: some View {
        ListWindowStatusBar {
            if viewModel.isCheckingExistence {
                ProgressView()
                    .controlSize(.small)
            }

            Text("\(viewModel.rows.count) of \(viewModel.totalRowCount) books shown")

            if viewModel.missingCount > 0 {
                ListWindowStatusSeparator()
                Text("\(viewModel.missingCount) missing")
                    .foregroundStyle(.orange)
            }

            if !viewModel.selectedBookIDs.isEmpty {
                ListWindowStatusSeparator()
                Text("\(viewModel.selectedBookIDs.count) selected")
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 一覧

    /// MetadataEditorWindowと同じくネイティブのTableを使う(ヘッダーと行が同一の列定義を
    /// 共有するため、区切り線がずれない。列幅のドラッグ変更も標準で効く)。
    private var bookTable: some View {
        Table(viewModel.rows, columnCustomization: $columnCustomization) {
            // 見出しの無いチェックボックス列(ユーザー要望: 複数の本を選んで一括削除したい)。
            // 空のLocalizedStringKeyを文字列カタログへ登録させたくないためText(verbatim:)で
            // 書く ―― EPUB/CBZ/PDF出力ウインドウの同じ列と同じ書き方(ExportWindowContent参照)。
            // TableColumnの見出しはTextしか置けないため、「すべて選択」はこの列の頭ではなく
            // ツールバーのトグルボタンにある(toolbarItems参照)。
            TableColumn(Text(verbatim: "")) { row in
                LibraryCleanupSelectionCell(row: row, viewModel: viewModel)
            }
            .width(20)
            .disabledCustomizationBehavior(.all)

            // ユーザー指摘: パスの末尾はファイル名そのものなので、ファイル名の列は重複していた。
            // 列を1つに統合し、フルパスだけを見せる(形式バッジはこの列に残す)。
            TableColumn("Path") { row in
                HStack(spacing: 4) {
                    // 長いパスは中央を省略する。先頭(どのフォルダの下か)と末尾(ファイル名)は
                    // どちらも本を見分けるのに必要な情報のため、両端を残す。
                    // 全体はツールチップと、ドラッグ選択によるコピーで取れる。
                    Text(row.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(row.path)
                    FormatBadgeView(bookID: row.bookID)
                }
            }
            .width(min: Self.pathColumnMin, ideal: pathColumnWidth)
            .customizationID("path")
            .disabledCustomizationBehavior([.reorder, .visibility])

            // ユーザー指摘: この2列と削除ボタン列だけ幅が決め打ちで、中身に対して無駄に広く、
            // ウインドウを広げると一緒に間延びしていた(他のウインドウは表示する文字列を
            // 実測して幅を決めている)。取りうる文言が有限で、後から長くなることもない列
            // なので、min/idealではなく**実測した固定幅**にする。余った幅はパス列が吸う。
            TableColumn("File") { row in
                existenceLabel(row.existence)
            }
            .width(existenceColumnWidth)
            .disabledCustomizationBehavior(.all)

            TableColumn("Saved Data") { row in
                savedDataIndicators(row)
            }
            .width(savedDataColumnWidth)
            .disabledCustomizationBehavior(.all)

            TableColumn(Text(verbatim: "")) { row in
                Button("Delete", role: .destructive) {
                    pendingDeletion = PendingDeletion(displayName: row.fileName, bookIDs: [row.bookID])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .width(actionColumnWidth)
            .disabledCustomizationBehavior(.all)
        }
        // 自動調整した幅(=.width(ideal:))が決まるのはTable生成より1描画ぶん後になる。
        // Tableは一度決めた列幅をidealの変化では作り直さないため、済んだ時点で一度だけ
        // 作り直す(ユーザーがドラッグした幅はcolumnCustomizationが外で保持している)。
        .id(didAutoSizeColumns)
    }

    /// パス列の幅を、実際に並ぶパスの長さから決める(ユーザー指摘: 他のウインドウは列の中の
    /// 文字列を実測して幅を合わせているのに、このウインドウだけ決め打ちだった)。
    /// 書き出しウインドウのファイル名列と同じ部品・同じ余白の足し方を使う。
    private func autoSizeColumnsIfNeeded() {
        guard !didAutoSizeColumns, !viewModel.rows.isEmpty else { return }
        pathColumnWidth = ExportColumnWidthEstimator.idealWidth(
            for: viewModel.rows.map(\.path),
            minWidth: Self.pathColumnMin,
            maxWidth: Self.pathColumnMax,
            extraChrome: 44 // 形式バッジぶんの余白
        )
        didAutoSizeColumns = true
    }

    /// 実在列の幅。「見つかりました」「見つかりません」「確認中…」「不明」のうち最も長いものが
    /// 省略されずに収まる幅を、アイコン1つ分の余白を足して見積もる。見出し(「ファイル」/「File」)も
    /// 一緒に測る ―― 見出しのほうが長いと、そちらが省略されてしまうため。
    private var existenceColumnWidth: CGFloat {
        ExportColumnWidthEstimator.idealWidth(
            for: [
                String(localized: "Found", language: locale),
                String(localized: "Missing", language: locale),
                String(localized: "Checking…", language: locale),
                String(localized: "Unknown", language: locale),
                String(localized: "File", language: locale)
            ],
            minWidth: 70,
            maxWidth: 200,
            extraChrome: ExportIndicatorIcon.slotWidth + ExportIndicatorIcon.slotSpacing
        )
    }

    /// 保存データ列の幅。中身はアイコン4つで固定なので、見出し(「保存データ」/「Saved Data」)が
    /// 収まるかどうかだけが効く。アイコン列の幅の出し方は書き出しウインドウと同じ部品を使う。
    private var savedDataColumnWidth: CGFloat {
        max(
            ExportIndicatorIcon.totalWidth(iconCount: 4) + 8,
            ExportColumnWidthEstimator.idealWidth(
                for: [String(localized: "Saved Data", language: locale)],
                minWidth: 0, maxWidth: 200
            )
        )
    }

    /// 行の削除ボタンの列幅。小さいサイズのボタンの実寸を文言から見積もる
    /// (メタデータの編集ウインドウの登録/削除ボタン列と同じ部品・同じ値の使い方)。
    private var actionColumnWidth: CGFloat {
        MetadataButtonWidthEstimator.equalWidth(
            for: [String(localized: "Delete", language: locale)],
            minWidth: 40,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            chrome: MetadataButtonWidthEstimator.smallChrome
        ) + 8
    }

    /// 元ファイルの実在。「見つからない」と「確認できない」を明確に描き分ける
    /// (LibraryCleanupViewModel.FileExistenceのコメント参照)。
    @ViewBuilder
    private func existenceLabel(_ existence: LibraryCleanupViewModel.FileExistence) -> some View {
        switch existence {
        case .exists:
            Label("Found", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .help("The original file or folder still exists.")
        case .missing:
            Label("Missing", systemImage: "xmark.circle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .help("The original file or folder could not be found.")
        case .checking:
            // 非同期スキャンの結果待ち(LibraryCleanupViewModel.FileExistence.checking参照)。
            Label("Checking…", systemImage: "clock")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .help("qooViewer is still checking whether the original file or folder exists.")
        case .unknown:
            Label("Unknown", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .help(
                    "qooViewer doesn't have permission to check this location, so it can't tell whether the file still exists. Granting access to the folder in Settings › Access, or connecting the volume, will let it check."
                )
        }
    }

    /// この本について、どの種類のデータが保存されているかのインジケータ。
    /// 登録があるものだけを濃く描き、無いものは薄いままにする(EPUB出力ウインドウの
    /// レイアウト/ブックマークインジケータと同じ考え方)。
    private func savedDataIndicators(_ row: LibraryCleanupViewModel.Row) -> some View {
        HStack(spacing: 6) {
            indicator("star.fill", isOn: row.favoriteCount > 0, help: "Is a favorite")
            indicator("bookmark.fill", isOn: row.bookmarkCount > 0, help: "Has bookmarks")
            indicator("rectangle.split.2x1", isOn: row.hasLayout, help: "Has page layout settings")
            indicator("tag.fill", isOn: row.hasMetadata, help: "Has metadata")
        }
    }

    private func indicator(_ systemName: String, isOn: Bool, help: LocalizedStringKey) -> some View {
        Image(systemName: systemName)
            .font(.caption)
            .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.25)))
            .help(help)
    }
}

/// チェックボックス列のセル。双方向のBindingを作るためにViewModelを観測している必要があるため、
/// TableColumnのクロージャに直接書かず小さなビューに分けてある
/// (出力ウインドウのExportSelectionCellと同じ理由・同じ形)。
private struct LibraryCleanupSelectionCell: View {
    let row: LibraryCleanupViewModel.Row
    @ObservedObject var viewModel: LibraryCleanupViewModel

    var body: some View {
        Toggle(
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
        ) {
            // 見た目としては隠すが、VoiceOverがどの行のチェックボックスなのかを読めるように
            // ファイル名をラベルに入れておく(空にすると「チェックボックス」としか読まれない)。
            // ここはString変数なので文字列カタログには登録されない。
            Text(row.fileName)
        }
        .toggleStyle(.checkbox)
        .labelsHidden()
    }
}
