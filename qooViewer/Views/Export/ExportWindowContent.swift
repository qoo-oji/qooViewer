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
/// 列の幅指定とウインドウ最小幅の計算の双方から参照するため、ジェネリックな
/// ExportWindowContentの外に出してある(型引数を書かずに参照できるようにするため)。
enum ExportRowMetrics {
    /// アイコン3つ(レイアウト/ブックマーク/メタデータ)を並べた領域の幅。
    /// スロットの寸法とアイコンの出し分け方はExportIndicatorIconにまとめてある
    /// (行ごとに並びがずれていた不具合の経緯もそちらのコメント参照)。
    static let indicatorIconsWidth: CGFloat = ExportIndicatorIcon.totalWidth(iconCount: 3)
    /// インジケータ列そのものの幅。かつては「レイアウトインジケータ左側の空白は詰め、
    /// ブックマークインジケータ右側はもう少し広く」というユーザー要望に合わせて自前の隙間を
    /// 前後に足していたが、一覧をネイティブのTableへ置き換えてからは列の左右余白はTableが
    /// 持つため、アイコン3つ分に僅かな余裕を足すだけにしてある。
    static let indicatorColumnWidth: CGFloat = indicatorIconsWidth + 8
    /// 先頭のチェックボックス列の幅。
    static let checkboxColumnWidth: CGFloat = 20
}

/// ファイル名列・タイトル列・著者名列・カバー列の「開いた直後の幅」(ユーザー要望: 各列に
/// 表示する文字列の長さに応じて、ウインドウ幅と各列の幅を自動調整してほしい)。
/// TableColumnの`.width(min:ideal:)`のidealとして渡す値で、以降はユーザーがヘッダーの
/// 区切り線をドラッグして自由に変えられる(結果はTableColumnCustomizationが保持する)。
/// カバー列はshowsCoverColumnがfalseなら使わない。
struct ExportColumnWidths: Equatable {
    /// 各列がこれ以上狭くならない下限。ウインドウの最小幅の算出にも使う。
    static let fileNameMin: CGFloat = 130
    static let titleMin: CGFloat = 110
    static let authorMin: CGFloat = 70
    static let coverMin: CGFloat = 90

    var fileName: CGFloat = 220
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
    /// 形式ごとの出力オプション(optionsクロージャ)を出すポップオーバーの表示状態
    /// (ユーザー要望: チェックボックス類は常時表示ではなく、ボタンを押したときだけ出す)。
    @State private var isOptionsPopoverPresented = false
    @State private var columnWidths = ExportColumnWidths()
    /// autoSizeColumnsIfNeeded()を、一覧の行が出そろった時点で1回だけ実行するためのフラグ
    /// (SidebarWidthEstimatorと同じ考え方。以降はユーザーの手動ドラッグを優先し、
    /// 内容の変化のたびに勝手にリサイズしないようにする)。
    @State private var didAutoSizeColumns = false
    /// ユーザーがタイトル行の区切り線をドラッグして変えた列幅を、Tableに保持させるための入れ物
    /// (ユーザー要望: タイトル行の区切り線をドラッグして列の幅を調整できるようにしてほしい)。
    /// 以前は自前のHStackとドラッグジェスチャーで再現していたが、タイトル行と各行の区切り線が
    /// 揃わない・ファイル名列の区切り線だけドラッグできないといった不具合が避けられなかったため、
    /// 一覧そのものをネイティブのTableへ置き換え、列幅の変更はTableに任せている。
    @State private var columnCustomization = TableColumnCustomization<BookExportViewModel.Row>()

    /// 各列の幅以外に、1行が必ず使う固定幅。チェックボックス列＋インジケータ列に加え、
    /// Table(insetスタイル)の左右余白・列間の隙間・スクロールバーのためのおおよその余裕。
    private var fixedChromeWidth: CGFloat {
        ExportRowMetrics.checkboxColumnWidth + ExportRowMetrics.indicatorColumnWidth + 72
    }

    /// 各列の下限幅から逆算した、ウインドウに最低限必要な幅(ユーザー要望: 右端の
    /// インジケータが見切れないようにしたい)。ユーザーが列を広げたぶんについては、
    /// Table自身が横スクロールで面倒を見る。
    private var contentMinWidth: CGFloat {
        ExportColumnWidths.fileNameMin + ExportColumnWidths.titleMin + ExportColumnWidths.authorMin
            + (configuration.showsCoverColumn ? ExportColumnWidths.coverMin : 0)
            + fixedChromeWidth
    }

    /// ユーザー要望: 各列に表示する文字列の長さに応じて、ウインドウ幅と各列の幅を自動調整して
    /// ほしい。一覧に並ぶ内容(ファイル名・タイトル・著者名)を基に、省略表示("…")にならずに
    /// 済む幅をあらかじめ計算する。SidebarWidthEstimatorと同じく、リストの内容が変わるたびに
    /// 勝手にリサイズされると使い勝手が悪いため、行が出そろった最初の1回だけ行う
    /// (以降はユーザーのドラッグ=columnCustomizationに委ねる)。
    ///
    /// バグ修正(ユーザー報告: PDF/CBZ出力ウインドウでファイル名列が狭いまま省略表示になり、
    /// インジケータ列の左に異様に広い余白ができる): 以前はこれを.onAppearからだけ呼んでいた。
    /// しかしviewModel.rowsは、元ファイルの実在確認をメインアクターの外へ逃がした結果
    /// (reload()のTask.detached参照)、必ず.onAppearより後に埋まる。そのため
    /// rows.isEmptyのguardに毎回はじかれ、自動調整は事実上一度も動いていなかった。
    /// 行が入った時点でも呼ぶようにして、実際に自動調整が効くようにする。
    private func autoSizeColumnsIfNeeded() {
        guard !didAutoSizeColumns, !viewModel.rows.isEmpty else { return }
        let fileNames = viewModel.rows.map(\.displayName)
        let titles = viewModel.rows.map { viewModel.titleOverrides[$0.bookID] ?? $0.displayName }
        let authors = viewModel.rows.map { viewModel.authorOverrides[$0.bookID] ?? "" }
        columnWidths.fileName = ExportColumnWidthEstimator.idealWidth(
            for: fileNames, minWidth: ExportColumnWidths.fileNameMin, maxWidth: 420,
            extraChrome: 44 // フォーマットバッジぶんの余白
        )
        columnWidths.title = ExportColumnWidthEstimator.idealWidth(
            for: titles, minWidth: ExportColumnWidths.titleMin, maxWidth: 420
        )
        columnWidths.author = ExportColumnWidthEstimator.idealWidth(
            for: authors, minWidth: ExportColumnWidths.authorMin, maxWidth: 260
        )
        didAutoSizeColumns = true
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
                bookTable
            }

            if let warningBanner = configuration.warningBanner {
                warningBannerView(warningBanner)
            }
        }
        // 「すべて選択」と「出力オプション…」はウインドウのツールバーへ載せる(純正のmacOSアプリと
        // 同じ作法。以前は下部のボタン行に4つとも並べていた)。確定操作(キャンセル/出力を開始)は
        // 「右下に既定ボタン」という慣習どおり下部に残す。
        .toolbar { toolbarItems }
        // ツールバーの下へ潜る一覧の、上端の縁の効果(ScrollEdgeEffect.swift参照)。
        .hardTopScrollEdgeEffect()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .frame(minWidth: max(configuration.minimumWindowWidth, contentMinWidth), minHeight: 480)
        // 一覧が非同期に埋まるため、表示直後と「行が入った瞬間」の両方で試みる
        // (autoSizeColumnsIfNeeded()のコメント参照。実際に走るのは最初の1回だけ)。
        .onAppear {
            // 書き出しオプションは、ウインドウを開くたびに環境設定「レイアウト」の既定値から
            // 始める(AppPreferences.bookExportRenumbersImagesのコメントどおりの
            // 「開いた直後の値」)。ViewModelはinitでも取り込んでいるが、SwiftUIのWindow
            // シーンは閉じたあとも中身を保持することがあり(Settingsシーンでの同種の挙動:
            // FB21393010)、その場合initは二度と走らず、環境設定で既定値を変えて開き直しても
            // 初回の値のまま残る(監査で指摘)。開く直後に必ず揃え直す。
            viewModel.resetOptionsToDefaults()
            autoSizeColumnsIfNeeded()
        }
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
                        format: String(localized: "“%1$@.%2$@” already exists in the destination folder.", language: preferences.effectiveLocale),
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
    ///
    /// 見た目は「メール」などが使う角丸のインラインバナー。以前はウインドウ幅いっぱいの
    /// オレンジ色の帯だったが、面積のわりに強い色で、ウインドウの構造の一部(下部バーの一種)
    /// のようにも見えていた。角丸のカードにして左右に余白を取り、一覧の内容に添えられた
    /// 注意書きだと分かる形にしている。
    private func warningBannerView(_ message: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25))
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - 対象一覧

    /// 一覧のすべての行が選択されているかどうか。「すべて選択」チェックボックスと双方向に
    /// 結び付けることで、チェックすると全選択、外すと全選択解除になる(ユーザー要望:
    /// 上部の「選択」メニュー・「選択解除」ボタンを廃止し、チェックボックスに一本化する)。
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

    /// 対象の本の一覧。macOSネイティブの表(Table)で描く。
    ///
    /// 以前はタイトル行と各行をそれぞれ自前のHStackで組み、区切り線も自前のRectangle、
    /// 列幅の変更も自前のドラッグジェスチャーで再現していた。しかしタイトル行と各行は
    /// 別々のList(余白の計算パイプラインが違う)に載っていたため区切り線の位置がずれ、
    /// 余った幅を吸わせていたファイル名列の区切り線だけはドラッグしても何も起きない、という
    /// 状態だった(ユーザー報告)。Tableに置き換えると、ヘッダーと本体の列位置が一致すること・
    /// すべての区切り線をドラッグして幅を変えられることの双方がAppKit側の保証になる。
    ///
    /// 引き換えに、見出しに任意のビューを置けなくなる(TableColumnの見出しはTextのみ)ため、
    /// タイトル行にあった「全選択/全解除」チェックボックスは下部のボタン行へ移してある。
    private var bookTable: some View {
        Table(viewModel.rows, columnCustomization: $columnCustomization) {
            // 見出しの無い列。空のLocalizedStringKeyを文字列カタログへ登録させたくないため
            // Text(verbatim:)で書く。幅の変更・並べ替え・非表示のいずれもさせない。
            TableColumn(Text(verbatim: "")) { row in
                ExportSelectionCell(row: row, viewModel: viewModel)
            }
            .width(ExportRowMetrics.checkboxColumnWidth)
            .disabledCustomizationBehavior(.all)

            // ファイル名列(ユーザー要望: タイトル列の左に、元のファイル名を表示する列を
            // 追加してほしい)。
            TableColumn("File Name") { row in
                HStack(spacing: 4) {
                    Text(row.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    FormatBadgeView(bookID: row.bookID)
                }
            }
            .width(min: ExportColumnWidths.fileNameMin, ideal: columnWidths.fileName)
            .customizationID("fileName")
            .disabledCustomizationBehavior([.reorder, .visibility])

            // タイトル列・著者名列(ユーザー要望: Apple Books互換性。ファイル名/フォルダ名から
            // 取得したタイトル・著者名を、この画面で変更できるようにしたい)。
            TableColumn("Title") { row in
                TextField("", text: viewModel.titleBinding(forBookID: row.bookID))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
            }
            .width(min: ExportColumnWidths.titleMin, ideal: columnWidths.title)
            .customizationID("title")
            .disabledCustomizationBehavior([.reorder, .visibility])

            TableColumn("Author") { row in
                TextField("", text: viewModel.authorBinding(forBookID: row.bookID))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
            }
            .width(min: ExportColumnWidths.authorMin, ideal: columnWidths.author)
            .customizationID("author")
            .disabledCustomizationBehavior([.reorder, .visibility])

            if configuration.showsCoverColumn {
                TableColumn("Cover") { row in
                    ExportCoverCell(bookID: row.bookID, viewModel: viewModel)
                }
                .width(min: ExportColumnWidths.coverMin, ideal: columnWidths.cover)
                .customizationID("cover")
                .disabledCustomizationBehavior([.reorder, .visibility])
            }

            // レイアウト/ブックマーク/メタデータのインジケータ(ユーザー要望: 見出し文字は
            // 付けない)。アイコンそれぞれを固定幅のスロットに収めることで、片方だけしか
            // 無い行でも位置がずれない(ExportIndicatorIcon参照)。
            TableColumn(Text(verbatim: "")) { row in
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
            }
            .width(ExportRowMetrics.indicatorColumnWidth)
            .disabledCustomizationBehavior(.all)
        }
        .tableStyle(.inset)
        // 一覧は非同期に埋まるため、自動調整した幅(=.width(ideal:))が決まるのは最初の
        // Table生成より1描画ぶん後になる。Tableは一度決めた列幅をidealの変化では作り直さない
        // ため、自動調整が済んだ時点で一度だけ作り直す(ユーザーがドラッグして変えた幅は
        // columnCustomizationがこのビューの外で保持しているので、これで失われることはない)。
        .id(didAutoSizeColumns)
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // 全選択/全解除(ユーザー要望: 「選択」メニュー・「選択解除」ボタンを廃止し、
        // チェックボックス1つに一本化する)。一覧をネイティブのTableへ置き換えた際に
        // タイトル行から下部のボタン行へ移し、さらにツールバーへ移した。
        // ツールバーにチェックボックスは載らないため、押している間だけ色が付く
        // トグルボタン(すべて選択されているときON)にしてある。
        ToolbarItem {
            Toggle(isOn: selectAllBinding) {
                // アイコンはユーザー選択。Finderの「すべてを選択」(角丸の枠＋中身)と同じ系統の
                // 図形にしたいが、Finderのものは`character.textbox`で中身が表示言語で変わる文字
                // (日本語では「あ」)なので、一覧の項目を全部選ぶ意味に合う
                // "checkmark.rectangle.stack"にしてある。
                Label("Select All", systemImage: "checkmark.rectangle.stack")
            }
            .toggleStyle(.button)
            .labelStyle(.titleAndIcon)
            .help("Select All / Deselect All")
            .disabled(viewModel.rows.isEmpty || viewModel.isExporting)
        }

        // 形式ごとの出力オプション(ユーザー要望: チェックボックス類はオプションとして
        // まとめ、ボタンを押したときだけ出す。一覧の下の余白を無くしたい)。
        // 見出しに形式名は入れず、3つのウインドウで同じ表記にする(ユーザー要望)。
        ToolbarItem {
            Button {
                isOptionsPopoverPresented = true
            } label: {
                // アイコンはユーザー選択で歯車(macOSで「設定・オプション」を表す図形)。
                // 当初の"slider.horizontal.3"は調整つまみに見えて好まれなかった。
                Label("Export Options…", systemImage: "gearshape")
            }
            .labelStyle(.titleAndIcon)
            .disabled(viewModel.isExporting)
            // arrowEdgeは「アンカーのどちら側へポップオーバーを出すか」。下部のボタン行に
            // あった頃は上へ出す.topが正しかったが、ツールバーへ移した今は下へ出す.bottomに
            // する(.topのままだとウインドウの外、タイトルバーの上に浮いて出る)。
            .popover(isPresented: $isOptionsPopoverPresented, arrowEdge: .bottom) {
                // 中身はToggleが1〜3個だけなので、Formの列レイアウトではなく素直に左揃えで縦に
                // 並べる(ポップオーバーは内容に合わせて縮むため、幅は下限だけ与えておく)。
                VStack(alignment: .leading, spacing: 8) {
                    options()
                }
                .padding(16)
                .frame(minWidth: 260, alignment: .leading)
            }
        }
    }

    // MARK: - 実行ボタン

    /// 下部のボタン行。確定操作を持つウインドウの「右下に既定ボタン」は正しい慣習なので、
    /// 並び(キャンセル→出力を開始)はそのままに、`.bar`素材の帯へ載せ替えてある
    /// (一覧がこの帯の下へ透けて潜る。以前はDividerで区切った不透明な行だった)。
    private var bottomBar: some View {
        HStack {
            Spacer()

            // ユーザー要望: 「出力を開始」ボタンの左に「キャンセル」ボタンを追加してほしい。
            // 他のウインドウ(FavoriteFolderPickerView.bottomBar等)と同じ並び
            // (キャンセル→既定ボタン)・同じキーボードショートカットの割り当て方に揃える。
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            // 「…」は「押すと必ず何か尋ねられる」ことを表す記号なので、保存先が決めてあって
            // パネルが出ないときは付けない(コンテキストメニューの「EPUBとして書き出す」に
            // 「…」を付けていないのと同じ理由。BookExportFormat.menuTitleKey参照)。
            Button(
                fixedDestination == nil
                    ? viewModel.format.startExportTitleKey
                    : viewModel.format.startExportWithoutPanelTitleKey
            ) {
                startExportButtonTapped()
            }
            .disabled(viewModel.selectedBookIDs.isEmpty || viewModel.isExporting)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// 環境設定「レイアウト」で、この形式の保存先が決めてあるか
    /// (AppPreferences.bookExportDestinationMode参照)。
    ///
    /// 決めてあれば、このウインドウも保存先を尋ねない。
    ///
    /// ■ 経緯(ユーザーからの指摘)
    /// 「保存先」の設定を入れた当初、それに従うのはビューアの右クリックからの書き出しだけで、
    /// この3つのウインドウは**設定を無視して常にフォルダ選択パネルを開いていた**。
    /// 同じ「EPUBの保存先」を決めたつもりでも、どのメニューから書き出したかで効いたり
    /// 効かなかったりする、というちぐはぐな状態になっていた。
    ///
    /// 保存先は形式の性質であって、どの画面から呼んだかで変わるものではないので、
    /// 設定は両方の経路に等しく効かせる。
    private var fixedDestination: URL? {
        guard preferences.bookExportDestinationMode(for: viewModel.format) == .fixedFolder else {
            return nil
        }
        // 決めてあってもブックマークが解決できない(フォルダが消された・外付けが外れている)
        // ことはある。その場合はnilを返してパネルへ落とし、その場で選び直せるようにする
        // (ViewerView.startOpenBookExportと同じ考え方)。
        return viewModel.format.fixedFolder.lastFolder()
    }

    private func startExportButtonTapped() {
        let locale = preferences.effectiveLocale

        if let fixedDestination {
            // 保存済みのブックマークから解決したフォルダなので、書き出しのあいだ
            // セキュリティスコープを開いておく(OpenBookExportSheet.runと同じ理由)。
            startExport(to: fixedDestination, isSecurityScoped: true, locale: locale)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", language: locale)
        panel.message = configuration.destinationPanelMessage(locale)
        if let lastFolder = configuration.lastUsedFolder.lastFolder() {
            panel.directoryURL = lastFolder
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        configuration.lastUsedFolder.remember(destination)
        // パネルで今まさに選んだフォルダには既に権限が付いているので、開き直す必要は無い。
        startExport(to: destination, isSecurityScoped: false, locale: locale)
    }

    private func startExport(to destination: URL, isSecurityScoped: Bool, locale: Locale) {
        let didAccess = isSecurityScoped && destination.startAccessingSecurityScopedResource()

        guard viewModel.hasSufficientDiskSpace(at: destination) else {
            if didAccess { destination.stopAccessingSecurityScopedResource() }
            insufficientSpaceMessage = String(
                localized: "The destination volume doesn't have enough free space (at least 1.2× the total size of the selected books is required). Choose a different destination, or select fewer books.",
                language: locale
            )
            return
        }

        Task {
            defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }
            await viewModel.startExport(destinationFolder: destination)
        }
    }
}

/// チェックボックス列のセル。双方向Bindingを作るためにViewModelを観測している必要があるため、
/// TableColumnのクロージャに直接書かず小さなビューに分けてある。
private struct ExportSelectionCell: View {
    let row: BookExportViewModel.Row
    @ObservedObject var viewModel: BookExportViewModel

    var body: some View {
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
    }
}

/// カバー列のセル(ユーザー要望: カバー画像はデフォルトで最初の画像を使い、このウインドウから
/// 変更できるようにしたい)。現在カバー画像として使われることになっているファイル名を表示し、
/// クリックすると本のページ一覧/外部ファイルから選び直せるpopoverを開く。
/// 内部公開なのは、ビューアの右クリックから1冊だけ書き出すシート(OpenBookExportSheet)でも
/// **同じカバー画像の選び方**を使うため。あちらは一覧の行を持たないので、`Row`ではなく
/// bookIDだけを受け取る形にしてある(このセルが行から使っていたのも元々bookIDだけだった)。
struct ExportCoverCell: View {
    let bookID: String
    @ObservedObject var viewModel: BookExportViewModel

    @State private var isCoverPickerPresented = false

    var body: some View {
        Button {
            isCoverPickerPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.coverDisplayName(forBookID: bookID))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Change Cover Image")
        .popover(isPresented: $isCoverPickerPresented) {
            ExportCoverPickerContent(bookID: bookID, viewModel: viewModel)
        }
        // カバー列の表示名は、上書き設定が無い場合(既定=先頭ページ)は本を読み込んで確認する
        // 必要があるため非同期で解決する(BookmarkListView.PageRowViewのサムネイル読み込みと
        // 同じ考え方)。
        .task(id: bookID) {
            await viewModel.refreshCoverName(forBookID: bookID)
        }
    }
}

/// カバー画像の選択画面(ユーザー要望: 本に含まれる画像の中から選べることは勿論、本に含まれて
/// いない画像ファイルをカバー画像専用として追加することもできるようにしたい)。
/// ExportCoverCellのカバー列ボタンからpopoverとして開く。
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
                            bookSourceURL: loadedBook.sourceURL,
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
        panel.message = String(localized: "Choose an image file to use as the cover.", language: preferences.effectiveLocale)
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
    /// 本そのものの場所。この画像が本の中のどこにあるか(書庫内のフォルダ・入れ子の書庫)を
    /// 求める起点(PageRef.location(inBookAt:)参照)。
    let bookSourceURL: URL
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
    /// previewImageをデコードしたときの解像度。設定が変わっていれば読み直すための控え
    /// (ThumbnailGridView.ThumbnailCell.loadPreviewImageIfNeeded参照)。
    @State private var previewPixelSize: CGFloat = 0
    /// ホバー開始から実際にpopoverを出すまでの遅延用タスク。
    @State private var hoverPreviewTask: Task<Void, Never>?
    /// ホバー開始から実際にpopoverを出すまでの遅延(ナノ秒)。BookmarkListView.PageRowViewと同じ値。
    /// 遅延は環境設定(AppPreferences.thumbnailHoverPreviewDelay)。ON/OFFの設定はページ一覧
    /// 専用で、ここには効かせない(サイズ調整の無いサムネイルでは、拡大が無いと何のページか
    /// 分からなくなるため。ユーザー指示)。
    @EnvironmentObject private var preferences: AppPreferences

    /// このページの本の中での居場所(ファイル名 + 書庫内フォルダ/入れ子書庫の相対パス)。
    private var location: PageLocation { page.location(inBookAt: bookSourceURL) }

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 8) {
                thumbnailView
                VStack(alignment: .leading, spacing: 1) {
                    // 書庫の中のフォルダ・入れ子の書庫の中にある画像は、ファイル名だけでは
                    // どの章のページか分からない(章ごとに001.jpgから振り直されている本では
                    // 同じ名前が一覧に何度も並ぶ)。本の直下からの相対パスを、ファイル名より
                    // 一段弱い見た目で上に添える(ユーザー要望)。直下の画像ではnilになり、
                    // 従来どおりファイル名だけの1行になる。
                    if let folderPath = location.folderPath {
                        Text(folderPath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(location.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .help(location.fullPath)
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

            VStack(spacing: 2) {
                // 行と同じ理由で、本の中での居場所も添える(location参照)。
                if let folderPath = location.folderPath {
                    Text(folderPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(location.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: preferences.thumbnailHoverPreviewSideLength)
        }
        .padding(12)
        .task {
            // ポップオーバーの枠に合わせた解像度で読む(ViewerViewModel.loadPreviewImage参照)。
            // 解像度が設定と違えば読み直す(ThumbnailGridView.ThumbnailCell.
            // loadPreviewImageIfNeededと同じ理由)。
            let pixelSize = preferences.thumbnailHoverPreviewPixelSize
            guard previewImage == nil || previewPixelSize != pixelSize, let pageLoader else { return }
            guard let loaded = await pageLoader.gridThumbnail(
                at: index, maxPixelSize: pixelSize, usesDiskCache: false
            ), !Task.isCancelled else { return }
            previewImage = loaded
            previewPixelSize = pixelSize
        }
    }
}
