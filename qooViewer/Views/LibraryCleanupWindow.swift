import SwiftUI
import SwiftData
import AppKit

/// ユーザー要望: 検証用に開いただけの本など、DBに残ったままの不要なデータを個別に消したい。
/// ファイル名・ファイルパス・ファイルが実在するかどうか・登録データのインジケータ・削除ボタンを
/// 持つ専用ウインドウ。環境設定の「リセット」タブからのみ開ける
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
    @Environment(\.dismiss) private var dismiss

    /// 削除確認の対象。nilの間は確認ダイアログを出さない。
    /// 1冊だけの削除と、一覧に出ている全件の削除の両方をこの1つの状態で扱う。
    @State private var pendingDeletion: PendingDeletion?

    private struct PendingDeletion: Identifiable {
        /// 1冊だけの場合はその表示名、まとめて削除の場合はnil。
        let displayName: String?
        let bookIDs: [String]
        /// 確認ダイアログを出し分けるためだけの識別子。bookIDsを連結して作ると、
        /// 「表示中をすべて削除」で数千冊ぶんの巨大な文字列が毎回できてしまうため、
        /// この構造体を作るときに1つ振る。
        let id = UUID()
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

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

            Divider()
            bottomSection
        }
        .frame(minWidth: 900, minHeight: 460)
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

    // MARK: - 上部(絞り込み + 検索)

    private var headerSection: some View {
        HStack(spacing: 8) {
            Picker("", selection: $viewModel.filter) {
                ForEach(LibraryCleanupViewModel.Filter.allCases) { filter in
                    Text(filter.titleKey).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

            if viewModel.isCheckingExistence {
                ProgressView()
                    .controlSize(.small)
            }

            if viewModel.missingCount > 0 {
                Text("\(viewModel.missingCount) missing")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 16)

            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                // 欄の外のクリック・Return・Escでフォーカスを外す(FocusReleasingField参照)。
                .releasesFocusOnOutsideClick()
        }
        .padding(12)
    }

    // MARK: - 一覧

    /// MetadataEditorWindowと同じくネイティブのTableを使う(ヘッダーと行が同一の列定義を
    /// 共有するため、区切り線がずれない。列幅のドラッグ変更も標準で効く)。
    private var bookTable: some View {
        Table(viewModel.rows) {
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
            .width(min: 220, ideal: 560)

            TableColumn("File") { row in
                existenceLabel(row.existence)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Saved Data") { row in
                savedDataIndicators(row)
            }
            .width(min: 110, ideal: 130)

            TableColumn("") { row in
                Button("Delete", role: .destructive) {
                    pendingDeletion = PendingDeletion(displayName: row.fileName, bookIDs: [row.bookID])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .width(88)
        }
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

    // MARK: - 下部

    private var bottomSection: some View {
        HStack {
            Text("\(viewModel.rows.count) of \(viewModel.totalRowCount) books shown")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            // 「見つからない本だけ」に絞ってからまとめて消す、という流れを想定した一括削除。
            // 絞り込みの結果そのものを対象にするため、何が消えるのかは一覧を見れば分かる。
            Button("Delete All Shown…", role: .destructive) {
                pendingDeletion = PendingDeletion(displayName: nil, bookIDs: viewModel.rows.map(\.bookID))
            }
            .disabled(viewModel.rows.isEmpty)

            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}
