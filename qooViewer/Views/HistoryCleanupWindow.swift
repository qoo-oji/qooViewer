import SwiftUI
import AppKit

/// 「開いたファイルの履歴の削除」ウインドウ。
///
/// ユーザー要望: 「本ごとの保存データの削除」(LibraryCleanupWindow)と同じ、チェックボックスで
/// 複数選んでまとめて消せるインタフェースを、履歴についても環境設定の「リセット」タブから
/// 使えるようにしたい。**この2つは対になる画面なので、ウインドウの形・クロームの置き方・
/// 件数表示の位置・文言の形をすべて揃えてある**(ユーザー指摘: 似た機能なのに名前も見た目も
/// バラバラだった)。開ける場所も同じ「リセット」タブだけに限る。
///
/// 形そのものは「メタデータの編集」「EPUB/PDF/CBZの書き出し」「ブックマーク・レイアウトの編集」
/// 「お気に入りの整理」と共通 ―― 操作するものはタイトルバー(ツールバー)、一覧はその下へ
/// スクロールして潜り、件数は下部中央のステータスバーに出る。
///
/// **一覧の表示ではセキュリティスコープ付きブックマークを一切解決しない。** RecentFilesStoreの
/// 型コメントにあるとおり、解決は対象が未接続の外付け/ネットワークボリュームを指していると
/// 1件で秒単位ブロックしうる。そのため「本ごとの保存データの削除」にある「ファイルが実在するか」
/// 列は、こちらには**意図的に無い** ―― 履歴の実在確認はRecentFilesStoreが自前の契機
/// (アプリのアクティブ化・ボリュームのマウント)で非同期に行っており、その結果は一覧に
/// 反映される。ここで独自に確認を走らせると、その設計をこの画面だけ壊すことになる。
///
/// LibraryCleanupWindowと違ってViewModelを持たない。表示するデータはRecentFilesStore.entriesの
/// ままでよく、この画面が固有に持つ状態は「検索文字列」と「チェックの付いている項目」だけの
/// ためである。
struct HistoryCleanupWindow: View {
    @EnvironmentObject private var recentFiles: RecentFilesStore
    /// 列幅の実測に使う表示言語(LibraryCleanupWindowと同じ理由・同じ書き方)。
    @Environment(\.locale) private var locale

    /// 列幅のドラッグ変更の保持先・パス列の実測幅・自動調整の実行済みフラグ。
    /// 「本ごとの保存データの削除」とまったく同じ作りにしてある(ユーザー指摘: 似た構成の
    /// ウインドウで、片方だけ列幅を変えられない・幅が中身に合わないのはUXとしてだめ)。
    @State private var columnCustomization = TableColumnCustomization<RecentFilesStore.Entry>()
    @State private var pathColumnWidth: CGFloat = HistoryCleanupWindow.pathColumnMin
    @State private var didAutoSizeColumns = false

    private static let pathColumnMin: CGFloat = 220
    private static let pathColumnMax: CGFloat = 620

    @State private var searchText = ""
    /// チェックの付いている項目(RecentFilesStore.Entry.id、すなわちパス)。
    ///
    /// 検索を変えても選択は保持する(LibraryCleanupViewModel.selectedBookIDsと同じ考え方・
    /// 同じ理由)。代わりに下部へ選択件数を常に出し、確認ダイアログでも件数を必ず見せる。
    @State private var selectedPaths: Set<String> = []
    /// 削除確認の対象。nilの間は確認ダイアログを出さない。
    /// 行の削除ボタンによる1件だけの削除と、チェックボックスで選んだ複数件の削除の両方を
    /// この1つの状態で扱う(LibraryCleanupWindow.PendingDeletionと同じ形)。
    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion: Identifiable {
        /// 1件だけの場合はその表示名、まとめて削除の場合はnil。
        let displayName: String?
        let paths: Set<String>
        let id = UUID()
    }

    /// 検索で絞り込んだあとの一覧。並び順は履歴そのもの(新しい順)のまま変えない ――
    /// 「最近開いたファイル」メニューやサイドパネルの履歴モードと同じ並びで探せるほうが、
    /// 消したい項目に行き着きやすい。
    private var shownEntries: [RecentFilesStore.Entry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return recentFiles.entries }
        return recentFiles.entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    /// 一覧に出ている項目がすべて選ばれているか(ツールバーの「すべて選択」の状態)。
    private var isEveryShownEntrySelected: Bool {
        let shown = shownEntries
        return !shown.isEmpty && shown.allSatisfy { selectedPaths.contains($0.id) }
    }

    /// `.searchable`はナビゲーションコンテナの中でだけツールバーへ載るため、Tableを
    /// NavigationStackで包んでいる。素のVStackに付けるとツールバーに出ない(実測)。
    var body: some View {
        NavigationStack {
            Group {
                if shownEntries.isEmpty {
                    ContentUnavailableView(
                        recentFiles.entries.isEmpty ? "No History Entries" : "No Matching Books",
                        systemImage: recentFiles.entries.isEmpty ? "clock" : "magnifyingglass",
                        description: Text(
                            recentFiles.entries.isEmpty
                                ? "qooViewer hasn't recorded any book you opened yet."
                                : "No book matches the current search text."
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    entryTable
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                statusBar
            }
            .toolbar {
                toolbarItems
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search"))
            // ツールバーの下へ潜る一覧の、上端の縁の効果(ScrollEdgeEffect.swift参照)。
            .hardTopScrollEdgeEffect()
        }
        // 大きさも対になるウインドウと揃える(ユーザー指摘)。
        .frame(minWidth: 900, minHeight: 480)
        .onAppear { autoSizeColumnsIfNeeded() }
        .onChange(of: recentFiles.entries.count) { _, _ in autoSizeColumnsIfNeeded() }
        // 削除の結果として消えた項目のチェックを外す。ここで外しておかないと、次に開いた同じ
        // ファイルが履歴の先頭へ戻ってきたとき(パスが同じなのでidも同じ)、身に覚えのない
        // チェックが付いた状態で現れることになる。
        .onChange(of: recentFiles.entries) { _, entries in
            selectedPaths.formIntersection(entries.map(\.id))
        }
        .alert(item: $pendingDeletion) { deletion in
            Alert(
                title: Text(
                    deletion.displayName == nil
                        ? "Remove \(deletion.paths.count) books from the history?"
                        : "Remove “\(deletion.displayName ?? "")” from the history?"
                ),
                message: Text(
                    "This removes the selected entries from the File menu's Open Recent and from the side panel's History mode. Your files are not touched."
                ),
                primaryButton: .destructive(Text("Remove")) {
                    recentFiles.remove(recentFiles.entries.filter { deletion.paths.contains($0.id) })
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - ツールバー

    /// すべて選択・選択した項目を削除。「本ごとの保存データの削除」の同名の項目と、順番も
    /// アイコンも文言も揃えてある(あちらにある絞り込みは、履歴には絞り込む軸が無いので置かない)。
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            // ツールバーにチェックボックスは載らないため、押している間だけ色が付くトグル
            // ボタンにする(書き出しウインドウ・LibraryCleanupWindowと同じ形・同じアイコン)。
            // 対象は今一覧に出ている項目だけで、検索で隠れている項目の選択には触れない。
            Toggle(isOn: Binding(
                get: { isEveryShownEntrySelected },
                set: { isSelected in
                    let shown = shownEntries.map(\.id)
                    if isSelected {
                        selectedPaths.formUnion(shown)
                    } else {
                        selectedPaths.subtract(shown)
                    }
                }
            )) {
                Label("Select All", systemImage: "checkmark.rectangle.stack")
            }
            .toggleStyle(.button)
            .labelStyle(.titleAndIcon)
            .help("Select All / Deselect All")
            .disabled(shownEntries.isEmpty)

            Button(role: .destructive) {
                pendingDeletion = PendingDeletion(displayName: nil, paths: selectedPaths)
            } label: {
                Label("Delete Selected…", systemImage: "trash")
            }
            .labelStyle(.titleAndIcon)
            .help("Delete Selected…")
            .disabled(selectedPaths.isEmpty)
        }
    }

    // MARK: - 一覧

    /// 「本ごとの保存データの削除」と同じくネイティブのTableで描く(ヘッダーと行が同一の列定義を
    /// 共有するため区切り線がずれない。列幅のドラッグ変更も標準で効く)。列の並び
    /// (チェックボックス → 内容 → 行ごとの削除ボタン)もあちらと揃えてある。
    private var entryTable: some View {
        Table(shownEntries, columnCustomization: $columnCustomization) {
            // 見出しの無いチェックボックス列。空のLocalizedStringKeyを文字列カタログへ
            // 登録させたくないためText(verbatim:)で書く(LibraryCleanupWindow/
            // ExportWindowContentの同じ列と同じ書き方)。
            TableColumn(Text(verbatim: "")) { entry in
                HistoryCleanupSelectionCell(entry: entry, selectedPaths: $selectedPaths)
            }
            .width(20)
            .disabledCustomizationBehavior(.all)

            // 表示するのはフルパス1列だけ(「本ごとの保存データの削除」でファイル名の列が
            // パスの末尾と重複していたという指摘を受けた形に揃える)。
            // 長いパスは中央を省略する。先頭(どのフォルダの下か)と末尾(ファイル名)は
            // どちらも項目を見分けるのに必要なため、両端を残す。
            TableColumn("Path") { entry in
                HStack(spacing: 4) {
                    // フォルダとファイルの区別。entry.isDirectoryはキャッシュ済みの値で、
                    // 参照してもファイルアクセスは発生しない(RecentFilesStore.Entry参照)。
                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                        .foregroundStyle(.secondary)
                    Text(entry.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(entry.path)
                    FormatBadgeView(bookID: entry.path)
                }
            }
            .width(min: Self.pathColumnMin, ideal: pathColumnWidth)
            .customizationID("path")
            .disabledCustomizationBehavior([.reorder, .visibility])

            // 幅は決め打ちにせず、ボタンの文言から実測する(ユーザー指摘: 決め打ちだと中身に
            // 対して無駄に広い。「本ごとの保存データの削除」の同じ列・メタデータの編集
            // ウインドウの登録/削除ボタン列と、同じ部品で同じように求める)。
            TableColumn(Text(verbatim: "")) { entry in
                Button("Delete", role: .destructive) {
                    pendingDeletion = PendingDeletion(
                        displayName: entry.displayName, paths: [entry.id]
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .width(actionColumnWidth)
            .disabledCustomizationBehavior(.all)
        }
        // 自動調整が済んだ時点で一度だけ作り直す(理由はLibraryCleanupWindowの同じ行参照)。
        .id(didAutoSizeColumns)
    }

    /// パス列の幅を、実際に並ぶパスの長さから決める(LibraryCleanupWindowと同じ部品・同じ値)。
    private func autoSizeColumnsIfNeeded() {
        guard !didAutoSizeColumns, !recentFiles.entries.isEmpty else { return }
        pathColumnWidth = ExportColumnWidthEstimator.idealWidth(
            for: recentFiles.entries.map(\.path),
            minWidth: Self.pathColumnMin,
            maxWidth: Self.pathColumnMax,
            extraChrome: 44 // 形式バッジ＋フォルダ/ファイルのアイコンぶんの余白
        )
        didAutoSizeColumns = true
    }

    /// 行の削除ボタンの列幅。
    private var actionColumnWidth: CGFloat {
        MetadataButtonWidthEstimator.equalWidth(
            for: [String(localized: "Delete", locale: locale)],
            minWidth: 40,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            chrome: MetadataButtonWidthEstimator.smallChrome
        ) + 8
    }

    // MARK: - 下部

    /// 件数の表示。位置・見た目は他の一覧ウインドウと共通(ListWindowStatusBar参照)。
    private var statusBar: some View {
        ListWindowStatusBar {
            // 履歴に並ぶのもフォルダ/書庫/PDF/EPUB=「本」なので、数え方も文言も
            // 「保存データの削除」と**同じ文字列**を使う(ユーザー指摘: 同じものを
            // 「冊」と「件」で数え分けていた)。
            Text("\(shownEntries.count) of \(recentFiles.entries.count) books shown")

            if !selectedPaths.isEmpty {
                ListWindowStatusSeparator()
                Text("\(selectedPaths.count) selected")
                    .monospacedDigit()
            }
        }
    }
}

/// チェックボックス列のセル。LibraryCleanupSelectionCellと同じ役割だが、こちらの選択状態は
/// ViewModelではなく親ビューの@Stateにあるため、Bindingをそのまま受け取る。
private struct HistoryCleanupSelectionCell: View {
    let entry: RecentFilesStore.Entry
    @Binding var selectedPaths: Set<String>

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { selectedPaths.contains(entry.id) },
                set: { isOn in
                    if isOn {
                        selectedPaths.insert(entry.id)
                    } else {
                        selectedPaths.remove(entry.id)
                    }
                }
            )
        ) {
            // 見た目としては隠すが、VoiceOverがどの行のチェックボックスなのかを読めるように
            // ファイル名をラベルに入れておく(LibraryCleanupSelectionCellと同じ)。
            Text(entry.displayName)
        }
        .toggleStyle(.checkbox)
        .labelsHidden()
    }
}
