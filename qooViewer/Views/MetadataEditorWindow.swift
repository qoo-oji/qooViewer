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

/// MetadataEditorWindowの実体表示。@ObservedObjectでViewModelを直接観測するため、
/// rows/draftsの変化がここで正しく再描画される。
private struct MetadataEditorContentView: View {
    @ObservedObject var viewModel: MetadataEditorViewModel
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var presentedSheet: MetadataFormatSheet?

    /// 登録/削除ボタンの列幅。文言が切り替わっても列幅が動かないよう固定にする。
    private static let actionColumnWidth: CGFloat = 92

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

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

            Divider()
            bottomSection
        }
        .frame(minWidth: 900, minHeight: 480)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .filenameFormat: FilenameFormatEditorSheet()
            case .volumeFormat: VolumeFormatEditorSheet()
            case .exclusionRule: ExclusionRuleEditorSheet()
            }
        }
    }

    // MARK: - 上部(3つの編集ダイアログを開くボタン + 検索)

    /// ユーザー要望: ウインドウ上部に「ファイル名フォーマットの編集」「巻数フォーマットの編集」
    /// 「除外文字列の編集」というボタンを備え、幅は3つとも揃えること。
    ///
    /// 幅の指定はButton自身ではなくラベル(Text)側へ付けること。macOSの標準ボタンスタイルは、
    /// Button全体に`.frame(width:)`を付けても枠(ベゼル)自体はラベルの自然なサイズのまま
    /// 中央に置かれるだけで、見た目の幅は揃わない(実機で確認済み)。ラベルに幅を持たせると
    /// ベゼルがそれに追随して広がるため、3つのボタンの見た目が揃う。
    private var headerSection: some View {
        let buttonWidth = MetadataButtonWidthEstimator.equalWidth(
            for: [
                String(localized: "Edit File Name Formats…", locale: locale),
                String(localized: "Edit Volume Formats…", locale: locale),
                String(localized: "Edit Excluded Text…", locale: locale)
            ]
        )
        return HStack(spacing: 8) {
            Button { presentedSheet = .filenameFormat } label: {
                Text("Edit File Name Formats…").frame(width: buttonWidth)
            }
            Button { presentedSheet = .volumeFormat } label: {
                Text("Edit Volume Formats…").frame(width: buttonWidth)
            }
            Button { presentedSheet = .exclusionRule } label: {
                Text("Edit Excluded Text…").frame(width: buttonWidth)
            }

            Spacer(minLength: 16)

            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                // 欄の外のクリック・Return・Escでフォーカスを外す(FocusReleasingField参照)。
                .releasesFocusOnOutsideClick()
        }
        .padding(12)
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
        Table(viewModel.rows) {
            TableColumn("File Name") { row in
                fileNameCell(row)
            }
            .width(min: 160, ideal: 300)

            TableColumn("Author") { row in
                editableCell(row, keyPath: \.author)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Title") { row in
                editableCell(row, keyPath: \.title)
            }
            .width(min: 100, ideal: 220)

            TableColumn("Series") { row in
                editableCell(row, keyPath: \.series)
            }
            .width(min: 100, ideal: 180)

            TableColumn("Volume") { row in
                editableCell(row, keyPath: \.seriesIndex)
            }
            .width(min: 50, ideal: 70)

            // 登録/削除ボタンの列。見出しは付けない(ユーザー要望の一覧に見出しの指定が無く、
            // 操作列に見出しを置かないのはEPUB出力ウインドウのインジケータ列と同じ扱い)。
            TableColumn("") { row in
                actionCell(row)
            }
            .width(Self.actionColumnWidth)
        }
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

    private var bottomSection: some View {
        HStack {
            Text(
                "\(metadataStore.registeredBookIDs.count) of \(viewModel.totalRowCount) books have metadata"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
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
