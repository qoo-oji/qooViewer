import CoreGraphics
import SwiftUI

/// コレクションの中(改善要望5)。登録した本のカバーを並べ、クリックで開く。
///
/// タイトルは出さない ―― カバーがそのまま見出しになるうえ、名前を添えると1冊あたりの高さが
/// 揃わなくなる。どの本かはツールチップ(`.help`)で確かめられる。
///
/// ■ 実体が見つからない本
/// 一覧を描くたびにディスクを触ることはせず、CollectionStoreが非同期に更新している
/// 存在確認の結果(cachedFileExists)で淡く描くだけにする。実際に開こうとした瞬間に初めて
/// ブックマークを解決し、そこで見つからなければアラートを出す(お気に入りと同じ流れ)。
struct CollectionDetailView: View {
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var coverExtractor: CollectionCoverExtractor
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var state: WelcomeLibraryState
    let collection: BookCollection
    let allowsEditing: Bool

    private static let spacing: CGFloat = 16
    private static let coverByteBudget = 96 * 1024 * 1024

    @State private var cellImageBudget = LazyCellImageBudget(byteBudget: coverByteBudget)
    @State private var isRenaming = false
    /// 開こうとしたが実体が見つからなかった本。
    @State private var missingItem: CollectionItem?
    /// メタデータ編集シートを出している本(実体のURLは開く前に解決しておく)。
    @State private var metadataTarget: MetadataTarget?

    /// メタデータ編集シートの対象。シートを出す時点で本のURLが解決できている必要があるため
    /// (BookMetadataSheetのコメント参照)、行とURLを組にして持つ。
    private struct MetadataTarget: Identifiable {
        let item: CollectionItem
        let url: URL
        var id: UUID { item.id }
    }

    private var items: [CollectionItem] {
        collectionStore.items(in: collection, sort: state.itemSort)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if items.isEmpty {
                emptyMessage
            } else {
                grid
            }
        }
        .sheet(isPresented: $isRenaming) {
            if let library = collection.library {
                CollectionNameSheet(
                    kind: .renameCollection,
                    initialName: collection.name,
                    isDuplicate: { name in
                        collectionStore.hasCollectionNamed(name, in: library, excluding: collection)
                    },
                    onCommit: { name in collectionStore.rename(collection, to: name) }
                )
            }
        }
        .alert(
            "Book Not Found",
            isPresented: Binding(
                get: { missingItem != nil },
                set: { if !$0 { missingItem = nil } }
            )
        ) {
            Button("OK") { missingItem = nil }
            // 削除はDBへの書き込みなので、シークレットウインドウでは出さない
            // (ContentViewの「お気に入りが見つかりません」と同じ判断)。
            if allowsEditing {
                Button("Remove from Collection", role: .destructive) {
                    if let missingItem { collectionStore.remove(missingItem) }
                    missingItem = nil
                }
            }
        } message: {
            Text("The file or folder for “") + Text(missingItem?.title ?? "")
                + Text("” could not be found. It may have been moved or deleted.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SidePanelNavButton(
                systemName: "chevron.backward", isDisabled: false, help: "Back to Collections"
            ) {
                state.openedCollectionID = nil
            }
            // 編集モード中は名前を押すとリネームのシートが出る。TextFieldをその場に置く案も
            // あったが、空欄・重複の知らせ方を作成のシートと揃えたいので、同じ部品を使う。
            Group {
                if allowsEditing && state.isEditing {
                    Button {
                        isRenaming = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(collection.name)
                                .font(.headline)
                            Image(systemName: "pencil")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Rename Collection")
                } else {
                    Text(collection.name)
                        .font(.headline)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .panelOutlinedContent()

            Text("\(collection.items.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .panelOutlinedContent()

            Spacer(minLength: 8)

            LibraryPaneControls(
                addHelp: "Add Books…",
                onAdd: {
                    state.addingBooks = .init(
                        collectionID: collection.id, name: collection.name,
                        libraryID: collection.library?.id ?? UUID()
                    )
                },
                isEditing: $state.isEditing,
                sort: $state.itemSort,
                // 本の行には「更新日時」に相当する情報が無い(CollectionStore.items(in:sort:))。
                sortFields: [.name, .dateAdded],
                size: $state.coverSize,
                sizeRange: WelcomeLibraryState.coverSizeRange,
                sizeHelp: "Cover Size",
                allowsEditing: allowsEditing
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: state.coverSize), spacing: Self.spacing)],
                spacing: Self.spacing
            ) {
                ForEach(items, id: \.id) { item in
                    cell(for: item)
                }
            }
            .padding(24)
            .id(cellImageBudget.epoch)
        }
        // 名前のリネームとは別の階層に付ける ―― 同じビューに2つの.sheetを重ねると、
        // 片方しか出ないことがある(SwiftUIの既知の癖)。
        .sheet(item: $metadataTarget) { target in
            BookMetadataSheet(item: target.item, sourceURL: target.url)
        }
    }

    private func cell(for item: CollectionItem) -> some View {
        CollectionCoverThumbnail(
            item: item,
            coverStore: collectionStore.coverStore,
            displayWidth: state.coverSize,
            exists: collectionStore.cachedFileExists(for: item),
            isExtracting: coverExtractor.inFlightItemIDs.contains(item.id),
            onImageRetained: { image in
                cellImageBudget.note(retaining: image, minimumCellCount: 24)
            }
        )
        .contentShape(Rectangle())
        .help(item.title)
        .onTapGesture { open(item) }
        .contextMenu {
            BookOpenContextMenuItems(
                onOpen: { open(item) },
                onOpenIn: { destination in
                    guard let url = collectionStore.resolvedExistingURL(for: item) else {
                        missingItem = item
                        return
                    }
                    BookWindowOpener.open(
                        BookOpenRequest(url), to: destination, from: appState,
                        launchCoordinator: launchCoordinator, openWindow: openWindow
                    )
                }
            )
            if allowsEditing && state.isEditing {
                Divider()
                Button("Edit Metadata…") {
                    guard let url = collectionStore.resolvedExistingURL(for: item) else {
                        missingItem = item
                        return
                    }
                    metadataTarget = MetadataTarget(item: item, url: url)
                }
                Button("Remove from Collection", role: .destructive) {
                    collectionStore.remove(item)
                }
            }
        }
    }

    private var emptyMessage: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Text("No books in this collection")
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
            Text("Drag books here to add them")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .panelOutlinedContent()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ item: CollectionItem) {
        guard let url = collectionStore.resolvedExistingURL(for: item) else {
            missingItem = item
            return
        }
        appState.open(url: url)
    }
}
