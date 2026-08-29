import SwiftUI
import SwiftData
import AppKit

/// ユーザー要望: 編集メニューの「レイアウトの編集」の下に区切り線を挟んで追加した
/// 「メタデータの編集」から開く独立ウインドウ。1ペイン構成で、上部に3つの編集ダイアログを
/// 開くボタン、その下に本の一覧(ファイル名・著者・タイトル・シリーズ・巻数・登録ボタン)を置く。
///
/// EpubExportWindowと同じ構成にしている: MetadataEditorViewModelは複数の
/// @EnvironmentObjectを受け取ってから組み立てる必要があり、宣言時のデフォルト値だけでは
/// 初期化できないため、まず素の@Stateで持っておき、.onAppearで組み立てた後の表示・状態観測は
/// @ObservedObjectを持つ子ビュー(MetadataEditorContentView)に委ねる。
struct MetadataEditorWindow: View {
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var formatStore: MetadataFormatStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel: MetadataEditorViewModel?

    var body: some View {
        Group {
            if let viewModel {
                MetadataEditorContentView(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(minWidth: 900, minHeight: 480)
                    .onAppear {
                        viewModel = MetadataEditorViewModel(
                            metadataStore: metadataStore,
                            formatStore: formatStore,
                            bookmarkStore: bookmarkStore,
                            layoutStore: layoutStore,
                            favoritesStore: favoritesStore,
                            modelContext: modelContext
                        )
                    }
            }
        }
    }
}

/// どの編集ダイアログをシートとして表示中か。3つのシートを別々の@Stateで持つと、
/// 「片方を閉じないともう片方が開かない」といった取りこぼしが起きやすいため、1つの状態に
/// まとめてある。
private enum MetadataFormatSheet: String, Identifiable {
    case filenameFormat
    case volumeFormat
    case exclusionRule

    var id: String { rawValue }
}

/// 一覧の各列の「開いた直後の幅」(ユーザー要望: 各列の幅は、実際に表示される文字列やボタンの
/// 幅を実測して自動調整すること。ただしウインドウ幅が過剰に広くならないよう上限は設けること)。
/// 出力ウインドウのExportColumnWidthsと同じ考え方・同じ実装パターンで、幅の計算そのものも
/// ExportColumnWidthEstimatorを使い回している。
private struct MetadataColumnWidths: Equatable {
    /// 各列がこれ以上狭くならない下限。
    static let fileNameMin: CGFloat = 160
    static let authorMin: CGFloat = 80
    static let titleMin: CGFloat = 100
    static let seriesMin: CGFloat = 100
    static let volumeMin: CGFloat = 44

    /// 実測がこれを超えたら省略表示にする上限(ユーザー要望: ウインドウ幅が過剰に広くならない
    /// ようにすること)。上限の合計＋巻数＋ボタン列が、既定のウインドウ幅(1300pt前後)に
    /// 収まる値にしてある。ここを大きくしすぎると、開いた直後に一覧が横スクロールになって
    /// 右端の登録/削除ボタンが見えなくなる(実機で確認済み)。
    /// なお、ファイル名列は上限を持たない代わりに、ここでの値は「開いた直後の幅」でしかなく、
    /// ウインドウを広げれば余った幅を吸って伸びる。
    static let fileNameMax: CGFloat = 300
    static let authorMax: CGFloat = 180
    static let titleMax: CGFloat = 260
    static let seriesMax: CGFloat = 220
    /// 巻数は「1」「12」程度しか入らないので、上限も見出し(「巻数」/「Volume」)が
    /// 収まる程度にとどめる。
    static let volumeMax: CGFloat = 90

    /// 実測で決まった幅から、さらに手で広げられる余地。著者名・タイトル・シリーズは編集できる
    /// 欄なので、後から今より長い文字を入れたときにドラッグで広げられるようにしておく
    /// (この余地が無いと、実測ぴったりで固定されて広げられなくなる)。
    ///
    /// 大きくしすぎないこと: ウインドウを広げたときに余る幅は、上限を持たない列(ファイル名)へ
    /// 回る前に、まず各列がこの余地を使い切るまで配られる。60ptにしていたときは、内容が
    /// 「40010 試作型」程度しかない著者名列まで一緒に間延びして見えた(実機で確認済み)。
    static let editableHeadroom: CGFloat = 20

    var fileName: CGFloat = 300
    var author: CGFloat = 140
    var title: CGFloat = 220
    var series: CGFloat = 180
    var volume: CGFloat = 56
}

/// MetadataEditorWindowの実体表示。@ObservedObjectでViewModelを直接観測するため、
/// rows/draftsの変化がここで正しく再描画される。
private struct MetadataEditorContentView: View {
    @ObservedObject var viewModel: MetadataEditorViewModel
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @Environment(\.locale) private var locale

    @State private var presentedSheet: MetadataFormatSheet?
    @State private var columnWidths = MetadataColumnWidths()
    /// autoSizeColumnsIfNeeded()を、行と推測値が出そろった時点で1回だけ実行するためのフラグ
    /// (出力ウインドウと同じ考え方。以降はユーザーの手動ドラッグを優先し、入力のたびに
    /// 勝手にリサイズしないようにする)。
    @State private var didAutoSizeColumns = false
    /// ユーザーがタイトル行の区切り線をドラッグして変えた列幅の保持先。
    @State private var columnCustomization = TableColumnCustomization<MetadataEditorViewModel.Row>()

    /// 登録/削除ボタンの列の、ボタン以外に要る左右の余白(Tableのセルの余白ぶん)。
    private static let actionCellPadding: CGFloat = 4

    /// 登録/削除ボタンの列幅。文言が切り替わっても列幅が動かないよう、両方が収まる幅に固定する。
    ///
    /// ユーザー指摘: 以前は92ptの決め打ちで、「登録」「削除」という短い日本語のボタンに対して
    /// 列が広すぎた。小さいサイズのボタンの実寸を文言から見積もって求める
    /// (表示言語は環境設定で切り替わるので、OSのロケールではなく`\.locale`で見積もる)。
    private var actionColumnWidth: CGFloat {
        MetadataButtonWidthEstimator.equalWidth(
            for: [
                String(localized: "Register", locale: locale),
                String(localized: "Remove", locale: locale)
            ],
            minWidth: 40,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            chrome: MetadataButtonWidthEstimator.smallChrome
        ) + Self.actionCellPadding
    }

    /// クローム(検索欄・フォーマットの編集)はコンテンツ領域ではなくウインドウのツールバーに置く
    /// (純正のmacOSアプリと同じ作法。以前は上部に自前のHStack + Dividerで並べていた)。
    /// `.searchable`はナビゲーションコンテナの中でだけツールバーへ載るため、Tableを
    /// NavigationStackで包んでいる。素のVStackに付けるとツールバーに出ない。
    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isPreparingDrafts {
                    // ファイル名からの推測が終わるまでは一覧を出さない。推測前の空欄を先に出すと、
                    // ほぼ全部の行が未登録である普通の状態では一覧全体が一瞬空になって見える
                    // (MetadataEditorViewModel.isPreparingDrafts参照)。
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.rows.isEmpty {
                    ContentUnavailableView(
                        viewModel.totalRowCount == 0 ? "No Books Yet" : "No Matching Books",
                        systemImage: viewModel.totalRowCount == 0 ? "books.vertical" : "magnifyingglass",
                        description: Text(
                            viewModel.totalRowCount == 0
                                ? "Books you open, favorite, bookmark, or lay out will appear here so you can give them metadata."
                                : "No book matches what you typed in the search field."
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
                ToolbarItem {
                    formatMenu
                }
            }
            // ツールバー右端のネイティブな検索欄。ウインドウが狭いと自動で虫眼鏡に畳まれる。
            // 以前の自前のTextFieldに付けていた`.releasesFocusOnOutsideClick()`は、
            // ネイティブの検索欄がEsc・欄外クリックでのフォーカス解除を自前で持つため不要。
            .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: Text("Search"))
            // ツールバーの下へ潜る一覧の、上端の縁の効果(ScrollEdgeEffect.swift参照)。
            .hardTopScrollEdgeEffect()
        }
        .frame(minWidth: 900, minHeight: 480)
        // 一覧は非同期に埋まる(推測値が入るのはさらに後)ため、表示直後・行が入った瞬間・
        // 推測が終わった瞬間の3か所で試みる(実際に走るのは最初の1回だけ)。
        .onAppear { autoSizeColumnsIfNeeded() }
        .onChange(of: viewModel.rows.count) { _, _ in autoSizeColumnsIfNeeded() }
        .onChange(of: viewModel.isPreparingDrafts) { _, _ in autoSizeColumnsIfNeeded() }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .filenameFormat: FilenameFormatEditorSheet()
            case .volumeFormat: VolumeFormatEditorSheet()
            case .exclusionRule: ExclusionRuleEditorSheet()
            }
        }
    }

    // MARK: - ツールバー

    /// ユーザー要望: 「ファイル名フォーマットの編集」「巻数フォーマットの編集」「除外文字列の編集」を
    /// このウインドウから開けること(当初の要望は上部に3つ並べたボタンで、幅を揃えることだった)。
    ///
    /// 3つとも「たまに使う設定を別のシートで開く」だけの操作で、常に3つ分の幅を占める必要が無い。
    /// クロームをツールバーへ移すにあたって、1つのプルダウンメニューへ畳んである
    /// (幅を揃えるためのMetadataButtonWidthEstimatorはここでは不要になった。
    /// 3つのダイアログ側のフッターでは引き続き使っている)。
    private var formatMenu: some View {
        Menu {
            Button("Edit File Name Formats…") { presentedSheet = .filenameFormat }
            Button("Edit Volume Formats…") { presentedSheet = .volumeFormat }
            Button("Edit Excluded Text…") { presentedSheet = .exclusionRule }
        } label: {
            // ユーザー要望: 文字の左にアイコンを添える。ツールバーのラベルは既定だと
            // アイコンだけ・文字だけのどちらかに畳まれることがあるため、.titleAndIconで
            // 両方出す指定にしてある。
            //
            // アイコンは「編集機能らしい図形」にすること(ユーザー要望)。
            // "textformat"は表示言語に合わせて字形そのものが変わり(日本語では「あぁ」)、
            // 文字が2つ並んで見えて馴染まなかった。"slider.horizontal.3"は図形だが調整つまみに
            // 見えて編集の意味が伝わらなかった。macOS標準の「編集」を表す"square.and.pencil"にしてある。
            Label("Edit Formats", systemImage: "square.and.pencil")
        }
        .labelStyle(.titleAndIcon)
        .help("Edit Formats")
    }

    // MARK: - 一覧

    /// 本の一覧。
    ///
    /// ユーザー報告: 以前はList + 自前のヘッダー行(HStack)という構成にしていたが、ヘッダー行と
    /// 各行が別々のビュー階層でレイアウトされるため、列の区切り線の位置がわずかにずれて見えて
    /// いた(BookmarkListView側で同種の問題を実測補正で解決した経緯があるが、根本的には
    /// 「2つの独立したレイアウトを人手で揃えている」ことに起因する)。
    ///
    /// SwiftUIのTableはmacOSではNSTableView上に構築され、ヘッダーと各行が同一のテーブルの
    /// 列定義を共有する。そのため区切り線のずれが原理的に起こらず、列幅のドラッグ変更・
    /// 列の並べ替えといった標準の挙動も自前で実装せずに手に入る。
    private var bookTable: some View {
        Table(viewModel.rows, columnCustomization: $columnCustomization) {
            TableColumn("File Name") { row in
                fileNameCell(row)
            }
            // ファイル名列だけは上限を付けない。ウインドウを広げたときに余る幅は、
            // 一番長い文字列が入るこの列が吸うのが自然なため(他の列に上限を付けてあるのは、
            // 余った幅が短い内容の列にまで均等に配られて間延びするのを防ぐため)。
            .width(min: MetadataColumnWidths.fileNameMin, ideal: columnWidths.fileName)
            .customizationID("fileName")
            .disabledCustomizationBehavior([.reorder, .visibility])

            TableColumn("Author") { row in
                editableCell(row, keyPath: \.author)
            }
            .width(
                min: MetadataColumnWidths.authorMin, ideal: columnWidths.author,
                max: columnWidths.author + MetadataColumnWidths.editableHeadroom
            )
            .customizationID("author")
            .disabledCustomizationBehavior([.reorder, .visibility])

            TableColumn("Title") { row in
                editableCell(row, keyPath: \.title)
            }
            .width(
                min: MetadataColumnWidths.titleMin, ideal: columnWidths.title,
                max: columnWidths.title + MetadataColumnWidths.editableHeadroom
            )
            .customizationID("title")
            .disabledCustomizationBehavior([.reorder, .visibility])

            TableColumn("Series") { row in
                editableCell(row, keyPath: \.series)
            }
            .width(
                min: MetadataColumnWidths.seriesMin, ideal: columnWidths.series,
                max: columnWidths.series + MetadataColumnWidths.editableHeadroom
            )
            .customizationID("series")
            .disabledCustomizationBehavior([.reorder, .visibility])

            TableColumn("Volume") { row in
                editableCell(row, keyPath: \.seriesIndex)
            }
            .width(
                min: MetadataColumnWidths.volumeMin, ideal: columnWidths.volume,
                max: columnWidths.volume
            )
            .customizationID("volume")
            .disabledCustomizationBehavior([.reorder, .visibility])

            // 登録/削除ボタンの列。見出しは付けない(ユーザー要望の一覧に見出しの指定が無く、
            // 操作列に見出しを置かないのはEPUB出力ウインドウのインジケータ列と同じ扱い)。
            TableColumn("") { row in
                actionCell(row)
            }
            .width(actionColumnWidth)
            .disabledCustomizationBehavior(.all)
        }
        // 自動調整した幅(=.width(ideal:))が決まるのは最初のTable生成より後になる。Tableは
        // 一度決めた列幅をidealの変化では作り直さないため、自動調整が済んだ時点で一度だけ
        // 作り直す(出力ウインドウと同じ対処。ユーザーがドラッグした幅はcolumnCustomizationが
        // このビューの外で保持しているので、これで失われることはない)。
        .id(didAutoSizeColumns)
    }

    /// 各列の幅を、実際に一覧へ並ぶ文字列の実測値に合わせる(ユーザー要望)。
    /// 行が出そろい、ファイル名からの推測値が入り終わってから1回だけ走らせる
    /// (入力のたびに列幅が動くと、文字を打つたびに表がずれて使いにくいため)。
    /// 見出しの文字列も測る対象に入れておかないと、内容が短い列(巻数)で見出しが切れる。
    private func autoSizeColumnsIfNeeded() {
        guard !didAutoSizeColumns, !viewModel.rows.isEmpty, !viewModel.isPreparingDrafts else { return }
        let drafts = viewModel.rows.map { viewModel.drafts[$0.bookID] ?? MetadataEditorViewModel.Draft() }
        columnWidths.fileName = ExportColumnWidthEstimator.idealWidth(
            for: viewModel.rows.map(\.fileName) + [String(localized: "File Name", locale: locale)],
            minWidth: MetadataColumnWidths.fileNameMin, maxWidth: MetadataColumnWidths.fileNameMax,
            extraChrome: 44 // フォーマットバッジ(CBZ/EPUB等)ぶんの余白
        )
        columnWidths.author = ExportColumnWidthEstimator.idealWidth(
            for: drafts.map(\.author) + [String(localized: "Author", locale: locale)],
            minWidth: MetadataColumnWidths.authorMin, maxWidth: MetadataColumnWidths.authorMax
        )
        columnWidths.title = ExportColumnWidthEstimator.idealWidth(
            for: drafts.map(\.title) + [String(localized: "Title", locale: locale)],
            minWidth: MetadataColumnWidths.titleMin, maxWidth: MetadataColumnWidths.titleMax
        )
        columnWidths.series = ExportColumnWidthEstimator.idealWidth(
            for: drafts.map(\.series) + [String(localized: "Series", locale: locale)],
            minWidth: MetadataColumnWidths.seriesMin, maxWidth: MetadataColumnWidths.seriesMax
        )
        columnWidths.volume = ExportColumnWidthEstimator.idealWidth(
            for: drafts.map(\.seriesIndex) + [String(localized: "Volume", locale: locale)],
            minWidth: MetadataColumnWidths.volumeMin, maxWidth: MetadataColumnWidths.volumeMax
        )
        didAutoSizeColumns = true
    }

    private func fileNameCell(_ row: MetadataEditorViewModel.Row) -> some View {
        HStack(spacing: 4) {
            // ユーザー要望: ファイル名の任意の部分をドラッグで選択してコピーできるようにしたい
            // (シリーズ名などを手で入力し直さず、ファイル名から切り出して他の欄へ貼り付けたい
            // ため)。.textSelection(.enabled)でText自体を選択可能にする。
            //
            // 併せてコンテキストメニューからファイル名全体もコピーできるようにしてある。
            // 列幅が狭いとファイル名は末尾が省略されるため、選択によるコピーだけでは
            // 省略された部分を取り出せないことがあるが、こちらは常に全体をそのままコピーできる。
            Text(row.fileName)
                .lineLimit(1)
                .textSelection(.enabled)
                .help(row.bookID)
                .metadataRegisteredForeground(isRegistered: viewModel.isRegistered(bookID: row.bookID))
            FormatBadgeView(bookID: row.bookID)
        }
        .contextMenu {
            Button("Copy File Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.fileName, forType: .string)
            }
        }
    }

    private func editableCell(
        _ row: MetadataEditorViewModel.Row, keyPath: WritableKeyPath<MetadataEditorViewModel.Draft, String>
    ) -> some View {
        TextField("", text: viewModel.binding(forBookID: row.bookID, keyPath: keyPath))
            .textFieldStyle(.plain)
            .lineLimit(1)
            .metadataRegisteredForeground(isRegistered: viewModel.isRegistered(bookID: row.bookID))
    }

    private func actionCell(_ row: MetadataEditorViewModel.Row) -> some View {
        let isRegistered = viewModel.isRegistered(bookID: row.bookID)
        // ユーザー要望: 登録済みの場合は削除ボタンにする。
        return Button(isRegistered ? "Remove" : "Register") {
            if isRegistered {
                viewModel.unregister(bookID: row.bookID)
            } else {
                viewModel.register(bookID: row.bookID)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - 下部

    /// Finder式のステータスバー。中央寄せの文字を`.bar`素材の帯に載せ、一覧はこの帯の下へ
    /// スクロールして潜る(以前はDividerで区切った不透明な行だった)。
    /// 独立ウインドウなので「閉じる」ボタンは置かない(タイトルバーの閉じるボタンで閉じるのが
    /// macOSの作法。Returnで閉じるのはシートの慣習)。
    private var statusBar: some View {
        // 件数の表示は、位置も見た目も他の一覧ウインドウと同じ部品に載せる
        // (ユーザー指摘: ウインドウごとに中央だったり右寄せだったりでバラバラだった。
        // ListWindowStatusBar参照)。
        ListWindowStatusBar {
            Text(
                "\(metadataStore.registeredBookIDs.count) of \(viewModel.totalRowCount) books have metadata"
            )
        }
    }
}

private extension View {
    /// ユーザー選択: 登録済みの行は文字色で識別できるようにする。
    ///
    /// 当初は背景色の帯にしていたが、Tableにはlistの`.listRowBackground`に相当する「行全体の
    /// 背景」を指定する仕組みが無く、各セルの中身に敷いた背景は必ずセル境界でクリップされる
    /// (負のパディングで隣のセルへはみ出させて隙間を埋める手も実機で試したが、はみ出した分は
    /// 描画されず、むしろ塗りが内側へ縮むだけだった)。そのため列と列の間で帯が必ず途切れる。
    /// ユーザーの判断により背景は使わず、文字色だけの強調にしてある。
    ///
    /// TextFieldにも効くため、登録済みの行は入力中の文字も同じ色になる。
    func metadataRegisteredForeground(isRegistered: Bool) -> some View {
        foregroundStyle(isRegistered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary))
    }
}
