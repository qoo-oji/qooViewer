import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 各出力ウインドウ(EPUB / PDF / CBZ)の、形式ごとに異なるところだけを束ねた設定。
/// 一覧・列幅・進捗・結果・出力先選択といった残りの部分はExportWindowContentが共通で持つ。
struct ExportWindowConfiguration {
    /// カバー列を表示するか。EPUB/CBZはカバー画像を選べるためtrue、PDFはカバーの概念自体が
    /// 無いためfalse(BookExportViewModel.supportsCoverSelectionと必ず揃えること)。
    let showsCoverColumn: Bool
    /// 対象になる本が1冊も無いときの説明文。
    let emptyDescription: LocalizedStringKey
    /// 一覧の下に常時表示しておく注意書き(PDFの「見開き情報は失われる」など)。不要ならnil。
    let warningBanner: LocalizedStringKey?
    let startButtonTitle: LocalizedStringKey
    let progressTitle: LocalizedStringKey
    /// 出力ファイルの拡張子。同名確認のメッセージに使う。
    let fileExtension: String
    /// 出力先フォルダ選択パネルに出すメッセージ。アプリ内表示言語で解決する必要があるため
    /// (OSのロケールとは独立しているため。QooViewerApp参照)、Localeを受け取る形にしてある。
    let destinationPanelMessage: (Locale) -> String
    let lastUsedFolder: LastUsedFolderMemory
    /// ウインドウの最小幅の下限(列幅から計算した値とのmaxを取る)。
    let minimumWindowWidth: CGFloat
}

/// 一覧の右端に並ぶインジケータ列(レイアウト/ブックマーク/メタデータ)の寸法。
/// タイトル行・各行・ウインドウ最小幅の計算の3か所から参照するため、ジェネリックな
/// ExportWindowContentの外に出してある(型引数を書かずに参照できるようにするため)。
enum ExportRowMetrics {
    /// レイアウトインジケータの左側の空白(ユーザー要望: レイアウトインジケータ左側の空白を
    /// 縮めてほしい)。
    static let indicatorLeadingGap: CGFloat = 4
    /// ブックマークインジケータの右側の空白(ユーザー要望: ブックマークインジケータ右側の
    /// 空白をもう少し広げてほしい)。
    static let indicatorTrailingGap: CGFloat = 14
    /// アイコン3つ(レイアウト/ブックマーク/メタデータ)を並べた領域の幅。
    /// スロットの寸法とアイコンの出し分け方はExportIndicatorIconにまとめてある
    /// (行ごとに並びがずれていた不具合の経緯もそちらのコメント参照)。
    static let indicatorIconsWidth: CGFloat = ExportIndicatorIcon.totalWidth(iconCount: 3)
    /// 右端のインジケータ列のために確保する幅の合計。ウインドウが縮んでも、この幅ぶんは
    /// 常に表示領域が残るようにする(ユーザー要望: 右端のインジケータが見切れないようにしたい)。
    static var trailingIndicatorWidth: CGFloat {
        indicatorLeadingGap + indicatorIconsWidth + indicatorTrailingGap
    }
}

/// ファイル名列・タイトル列・著者名列・カバー列の幅。タイトル行と各行で共有する
/// (ユーザー要望: タイトル列の右にカバー画像の列を追加してほしい。さらにApple Books
/// 互換性対応で、タイトル・著者名を編集できる列を追加。タイトル列の左には、元のファイル名を
/// 表示するファイル名列を追加してほしい)。カバー列はshowsCoverColumnがfalseなら使わない。
///
/// ファイル名列だけは可変幅のため、この値は幅そのものではなく下限として使う
/// (ExportWindowContent.columnHeaderRow参照)。
struct ExportColumnWidths {
    var fileName: CGFloat = 170
    var title: CGFloat = 190
    var author: CGFloat = 140
    var cover: CGFloat = 150
}

/// 出力ウインドウの実体表示。@ObservedObjectでViewModelを直接観測するため、rows/selection/
/// isExporting等のすべての変化がここで正しく再描画される(各Windowの親ビュー自身は
/// ViewModelを観測していないため、この子ビューを分けないと@Publishedの変化が再描画に
/// 反映されない)。
///
/// 形式ごとの出力オプション(チェックボックス群)だけはoptionsクロージャで受け取る。
struct ExportWindowContent<Options: View>: View {
    @ObservedObject var viewModel: BookExportViewModel
    let configuration: ExportWindowConfiguration
    @ViewBuilder let options: () -> Options

    @EnvironmentObject private var preferences: AppPreferences
    /// ユーザー要望: 「出力を開始」ボタンの左に「キャンセル」ボタンを追加し、書き出さずに
    /// このウインドウを閉じられるようにしたい。他のウインドウ(BulkRenameBookmarksWindow等)と
    /// 同じくEnvironmentのdismissアクションでウインドウを閉じる。
    @Environment(\.dismiss) private var dismiss
    @State private var insufficientSpaceMessage: String?
    @State private var columnWidths = ExportColumnWidths()
    /// autoSizeColumnsIfNeeded()を、一覧の行が出そろった時点で1回だけ実行するためのフラグ
    /// (SidebarWidthEstimatorと同じ考え方。以降はユーザーの手動ドラッグを優先し、
    /// 内容の変化のたびに勝手にリサイズしないようにする)。
    @State private var didAutoSizeColumns = false

    /// 各列の幅以外に、1行が必ず使う固定幅。内訳はチェックボックス列(20)＋区切り線(1ptずつ)
    /// ＋インジケータ列＋左右の外側パディング(.padding(.leading, 12) + .padding(.trailing, 20)
    /// = 32)＋HStack(spacing: 8)の要素間の間隔。区切り線と間隔の数はカバー列の有無で変わる。
    ///
    /// 間隔の数は、columnHeaderRow / ExportBookRowViewのHStackに実際に並ぶ要素数-1と一致させる
    /// (チェックボックス・区切り線・各列・インジケータ左の隙間・インジケータの並び)。
    /// 以前は間隔の数が実際の並びより少なく見積もられていて、カバー列を持たないPDF出力で
    /// contentMinWidthから決まるウインドウ最小幅が数pt足りていなかった。
    private var fixedChromeWidth: CGFloat {
        let dividerCount: CGFloat = configuration.showsCoverColumn ? 5 : 4
        let spacingCount: CGFloat = configuration.showsCoverColumn ? 11 : 9
        return 20 + dividerCount * 1 + spacingCount * 8 + ExportRowMetrics.trailingIndicatorWidth + 32
    }

    /// 現在の各列の幅から逆算した、ウインドウに最低限必要な幅(ユーザー要望: 右端の
    /// インジケータが見切れないようにしたい)。列の幅が(自動調整・手動ドラッグのいずれかで)
    /// 変わるたびに追随するため、ウインドウがそれより縮められることが無くなる。
    ///
    /// ファイル名列だけは可変幅(下限がcolumnWidths.fileName)のため、ここでの合計は
    /// 「ウインドウをいちばん狭くしたときの幅」になる。ウインドウがこれより広い間は、
    /// 余った幅はすべてファイル名列が受け取る(columnHeaderRow参照)。
    private var contentMinWidth: CGFloat {
        columnWidths.fileName + columnWidths.title + columnWidths.author
            + (configuration.showsCoverColumn ? columnWidths.cover : 0)
            + fixedChromeWidth
    }

    /// ユーザー要望: 各列に表示する文字列の長さに応じて、ウインドウ幅と各列の幅を自動調整して
    /// ほしい。一覧に並ぶ内容(ファイル名・タイトル・著者名)を基に、省略表示("…")にならずに
    /// 済む幅をあらかじめ計算する。SidebarWidthEstimatorと同じく、リストの内容が変わるたびに
    /// 勝手にリサイズされると使い勝手が悪いため、行が出そろった最初の1回だけ行う
    /// (以降はユーザーの手動ドラッグ(ExportResizableColumnDivider)に委ねる)。
    ///
    /// バグ修正(ユーザー報告: PDF/CBZ出力ウインドウでファイル名列が狭いまま省略表示になり、
    /// インジケータ列の左に異様に広い余白ができる): 以前はこれを.onAppearからだけ呼んでいた。
    /// しかしviewModel.rowsは、元ファイルの実在確認をメインアクターの外へ逃がした結果
    /// (reload()のTask.detached参照)、必ず.onAppearより後に埋まる。そのため
    /// rows.isEmptyのguardに毎回はじかれ、自動調整は事実上一度も動いていなかった
    /// (3つの出力ウインドウすべてが既定値の170/190/140のままだった)。行が入った時点でも
    /// 呼ぶようにして、実際に自動調整が効くようにする。
    private func autoSizeColumnsIfNeeded() {
        guard !didAutoSizeColumns, !viewModel.rows.isEmpty else { return }
        didAutoSizeColumns = true
        let fileNames = viewModel.rows.map(\.displayName)
        let titles = viewModel.rows.map { viewModel.titleOverrides[$0.bookID] ?? $0.displayName }
        let authors = viewModel.rows.map { viewModel.authorOverrides[$0.bookID] ?? "" }
        columnWidths.fileName = ExportColumnWidthEstimator.idealWidth(
            for: fileNames, minWidth: 130, maxWidth: 420, extraChrome: 44 // フォーマットバッジぶんの余白
        )
        columnWidths.title = ExportColumnWidthEstimator.idealWidth(for: titles, minWidth: 130, maxWidth: 420)
        columnWidths.author = ExportColumnWidthEstimator.idealWidth(for: authors, minWidth: 80, maxWidth: 260)
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
                    description: Text(configuration.emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                bookListSection
            }

            if let warningBanner = configuration.warningBanner {
                warningBannerView(warningBanner)
            }

            Divider()
            Form {
                options()
            }
            .padding()
            Divider()
            bottomSection
        }
        .frame(minWidth: max(configuration.minimumWindowWidth, contentMinWidth), minHeight: 480)
        // 一覧が非同期に埋まるため、表示直後と「行が入った瞬間」の両方で試みる
        // (autoSizeColumnsIfNeeded()のコメント参照。実際に走るのは最初の1回だけ)。
        .onAppear { autoSizeColumnsIfNeeded() }
        .onChange(of: viewModel.rows.count) { _, _ in autoSizeColumnsIfNeeded() }
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
            ExportProgressSheet(
                viewModel: viewModel,
                progressTitle: configuration.progressTitle,
                overwriteMessage: { displayName in
                    String(
                        format: String(localized: "“%1$@.%2$@” already exists in the destination folder."),
                        displayName, configuration.fileExtension
                    )
                }
            )
        }
        .sheet(isPresented: Binding(get: { viewModel.didFinish }, set: { if !$0 { viewModel.acknowledgeFinish() } })) {
            ExportResultSheet(viewModel: viewModel)
        }
    }

    /// この書き出し形式が構造的に持てない情報について、常に表示しておく注意書き
    /// (PDFの見開き/読み方向など)。一過性の通知ではなく機能の恒常的な制約のため、
    /// BookmarkListView.reorderWarningMessageと違って閉じるボタンは付けない。
    private func warningBannerView(_ message: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - 対象一覧

    /// 一覧のすべての行が選択されているかどうか。タイトル行のチェックボックスと双方向に
    /// 結び付けることで、チェックすると全選択、外すと全選択解除になる(ユーザー要望:
    /// 上部の「選択」メニュー・「選択解除」ボタンを廃止し、タイトル行のチェックボックスに
    /// 一本化する)。
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

    /// 一覧のタイトル行。各行(ExportBookRowView)と列の位置を揃えるため、チェックボックス列・
    /// ファイル名列・タイトル列・著者名列・カバー列にだけ見出しを置く。インジケータ列
    /// (レイアウト/ブックマーク/メタデータのアイコン)には見出し文字を付けない(ユーザー要望)。
    ///
    /// 各列は、それぞれ直後の区切り線をドラッグして幅を変更できる(ユーザー要望: タイトル行の
    /// 区切り線をドラッグして列の幅を調整できるようにしてほしい。ExportResizableColumnDivider
    /// 参照。チェックボックス列の直後だけは幅固定のExportColumnDividerLineのまま)。
    private var columnHeaderRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: selectAllBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Select All / Deselect All")

            ExportColumnDividerLine()

            // ファイル名列だけは可変幅にして、ウインドウが列の合計より広いときの余りを
            // すべて受け取らせる(ユーザー報告: インジケータ列の左に異様に広い余白ができる
            // 一方で、いちばん長いファイル名の列が省略表示になっていた)。BookmarkListViewの
            // タイトル行の最終列(「ブックマーク」)と同じ考え方。
            //
            // 可変幅にしたぶん、この列の直後だけは幅固定のExportColumnDividerLineに戻している。
            // ドラッグしてもウインドウに余りがある限り見た目が変わらず、操作できるのに何も
            // 起きない区切り線になってしまうため(他の列のドラッグは従来どおり効き、広げた
            // ぶんはファイル名列から引かれる)。
            Text("File Name")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: columnWidths.fileName, maxWidth: .infinity, alignment: .leading)

            ExportColumnDividerLine()

            Text("Title")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.title, alignment: .leading)

            ExportResizableColumnDivider(width: $columnWidths.title)

            // Apple Books互換性(ユーザー要望): ファイル名/フォルダ名から取得したタイトル・
            // 著者名を、この画面で編集できるようにしたい。
            Text("Author")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.author, alignment: .leading)

            ExportResizableColumnDivider(width: $columnWidths.author, minWidth: 60, maxWidth: 260)

            if configuration.showsCoverColumn {
                Text("Cover")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: columnWidths.cover, alignment: .leading)

                ExportResizableColumnDivider(width: $columnWidths.cover, minWidth: 80, maxWidth: 300)
            }

            // 各行のインジケータ列とまったく同じ幅を、見出しの無い空白として確保する。
            // ここをSpacer()のままにすると、可変幅になったファイル名列と余った幅を分け合って
            // しまい、タイトル行と各行とで列の位置がずれる。
            Color.clear
                .frame(width: ExportRowMetrics.indicatorLeadingGap, height: ExportColumnDividerLine.height)

            Color.clear
                .frame(width: ExportRowMetrics.indicatorIconsWidth, height: ExportColumnDividerLine.height)
                .padding(.trailing, ExportRowMetrics.indicatorTrailingGap)
        }
        // ユーザー要望: インジケータの右側にもう少しスペースを開けたい(チェックボックスの
        // 左側と同じくらい)。左右の余白を非対称にし、右側を広めにとる(ExportBookRowViewの
        // .padding(.leading:.trailing:)と揃える。fixedChromeWidthもこの値に合わせてある)。
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

    private var bookListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeaderRowContainer

            List(viewModel.rows) { row in
                ExportBookRowView(
                    row: row, viewModel: viewModel, columnWidths: columnWidths,
                    showsCoverColumn: configuration.showsCoverColumn
                )
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

    // MARK: - 実行ボタン

    private var bottomSection: some View {
        HStack {
            Spacer()
            // ユーザー要望: 「出力を開始」ボタンの左に「キャンセル」ボタンを追加してほしい。
            // 他のウインドウ(FavoriteFolderPickerView.bottomBar等)と同じ並び
            // (キャンセル→既定ボタン)・同じキーボードショートカットの割り当て方に揃える。
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(configuration.startButtonTitle) {
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
        panel.message = configuration.destinationPanelMessage(locale)
        if let lastFolder = configuration.lastUsedFolder.lastFolder() {
            panel.directoryURL = lastFolder
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        configuration.lastUsedFolder.remember(destination)

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
}

/// 一覧の1行。カバー列はボタンでpopoverを開き、本に含まれる画像またはそれ以外のファイルから
/// カバー画像を選べるようにする(ユーザー要望: カバー画像はデフォルトで最初の画像を使い、
/// このウインドウから変更できるようにしたい)。
private struct ExportBookRowView: View {
    let row: BookExportViewModel.Row
    @ObservedObject var viewModel: BookExportViewModel
    let columnWidths: ExportColumnWidths
    let showsCoverColumn: Bool

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

            ExportColumnDividerLine()

            // ファイル名列(ユーザー要望: タイトル列の左に、元のファイル名を表示する列を
            // 追加してほしい)。拡張子付きの実際のファイル名/フォルダ名をそのまま表示する。
            HStack(spacing: 4) {
                Text(row.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                FormatBadgeView(bookID: row.bookID)
            }
            // タイトル行のファイル名列と同じ可変幅(columnHeaderRowのコメント参照)。
            .frame(minWidth: columnWidths.fileName, maxWidth: .infinity, alignment: .leading)

            ExportColumnDividerLine()

            // タイトル列(ユーザー要望: Apple Books互換性。ファイル名/フォルダ名から取得した
            // タイトルを、この画面で変更できるようにしたい)。
            TextField("", text: viewModel.titleBinding(forBookID: row.bookID))
                .textFieldStyle(.plain)
                .lineLimit(1)
                .frame(width: columnWidths.title, alignment: .leading)

            ExportColumnDividerLine()

            // 著者名列(ユーザー要望: Apple Books互換性。ファイル名/フォルダ名から取得した
            // 著者名を、この画面で変更できるようにしたい)。
            TextField("", text: viewModel.authorBinding(forBookID: row.bookID))
                .textFieldStyle(.plain)
                .lineLimit(1)
                .frame(width: columnWidths.author, alignment: .leading)

            ExportColumnDividerLine()

            if showsCoverColumn {
                // カバー列(ユーザー要望)。現在カバー画像として使われることになっている
                // ファイル名を表示し、クリックすると本のページ一覧/外部ファイルから
                // 選び直せるpopoverを開く。
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
                    ExportCoverPickerContent(bookID: row.bookID, viewModel: viewModel)
                }

                ExportColumnDividerLine()
            }

            // レイアウト/ブックマーク/メタデータのインジケータ(ユーザー要望: 右のインジケータが
            // 見切れないようにしたい。さらにレイアウトインジケータの左側は詰め、
            // ブックマークインジケータの右側はもう少し広めに空けたい)。アイコンそれぞれを
            // 固定幅のスロットに収めることで、片方だけしか無い行でも位置がずれず、かつ
            // 列全体としてはtrailingIndicatorWidthぶんを確保してウインドウが縮んでも
            // 見切れないようにする(contentMinWidth参照)。
            // 幅固定の隙間にしてある(Spacerのままだと、可変幅になったファイル名列と
            // 余った幅を分け合ってしまう。columnHeaderRowのコメント参照)。
            Color.clear
                .frame(width: ExportRowMetrics.indicatorLeadingGap, height: ExportColumnDividerLine.height)

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
            .frame(width: ExportRowMetrics.indicatorIconsWidth, alignment: .leading)
            .padding(.trailing, ExportRowMetrics.indicatorTrailingGap)
        }
        // カバー列の表示名は、上書き設定が無い場合(既定=先頭ページ)は本を読み込んで確認する
        // 必要があるため非同期で解決する(BookmarkListView.PageRowViewのサムネイル読み込みと
        // 同じ考え方)。カバー列を出さない形式では解決自体が不要。
        .task(id: row.bookID) {
            guard showsCoverColumn else { return }
            await viewModel.refreshCoverName(forBookID: row.bookID)
        }
    }
}

/// カバー画像の選択画面(ユーザー要望: 本に含まれる画像の中から選べることは勿論、本に含まれて
/// いない画像ファイルをカバー画像専用として追加することもできるようにしたい)。
/// ExportBookRowViewのカバー列ボタンからpopoverとして開く。
///
/// 追加した専用ファイルはLayoutStore.setExternalCoverが本(MangaBook.pages)には一切追加しない
/// (BookLayoutSettingsの別プロパティとして保持するだけ)ため、ビューアのページ一覧には
/// 現れない(ユーザー要望通り)。
private struct ExportCoverPickerContent: View {
    let bookID: String
    @ObservedObject var viewModel: BookExportViewModel
    /// PageLoaderのページキャッシュ上限(環境設定「キャッシュ」)を渡すため。
    @EnvironmentObject private var preferences: AppPreferences

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
                        ExportCoverPickerPageRow(
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
            pageLoader = PageLoader(book: book, imageCacheLimitBytes: preferences.pageImageCacheLimitBytes)
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

/// カバー選択画面(ExportCoverPickerContent)の一覧の1行。ページを選ぶボタンに加えて、小さな
/// サムネイルにカーソルを乗せている間、拡大プレビューをpopoverで表示する(ユーザー要望:
/// このサムネイルも他の一覧と同じように大きく確認できるようにしたい)。
/// BookmarkListView.PageRowViewのホバー拡大プレビューと同じ考え方・同じ実装パターン
/// (350msの遅延の後にだけpopoverを出す。ドラッグ操作等は無いためここでは単純にホバー判定だけ)。
private struct ExportCoverPickerPageRow: View {
    let page: PageRef
    let index: Int
    let pageLoader: PageLoader?
    /// 小さいサムネイル画像のキャッシュ。ExportCoverPickerContent側の@Stateを共有し、
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
    /// 遅延は環境設定(AppPreferences.thumbnailHoverPreviewDelay)。ON/OFFの設定はページ一覧
    /// 専用で、ここには効かせない(サイズ調整の無いサムネイルでは、拡大が無いと何のページか
    /// 分からなくなるため。ユーザー指示)。
    @EnvironmentObject private var preferences: AppPreferences

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
                    try? await Task.sleep(nanoseconds: preferences.thumbnailHoverPreviewDelayNanoseconds)
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
    /// (一辺は環境設定。AppPreferences.thumbnailHoverPreviewSideLength)。
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
            .frame(
                width: preferences.thumbnailHoverPreviewSideLength,
                height: preferences.thumbnailHoverPreviewSideLength
            )

            Text(page.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: preferences.thumbnailHoverPreviewSideLength)
        }
        .padding(12)
        .task {
            guard previewImage == nil, let pageLoader else { return }
            // ポップオーバーの枠に合わせた解像度で読む(ViewerViewModel.loadPreviewImage参照)。
            previewImage = await pageLoader.gridThumbnail(
                at: index, maxPixelSize: preferences.thumbnailHoverPreviewPixelSize, usesDiskCache: false
            )
        }
    }
}
