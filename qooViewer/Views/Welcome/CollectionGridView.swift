import CoreGraphics
import SwiftUI

/// 選択中のライブラリのコレクションを、タイルで並べる画面(改善要望5)。
///
/// ■ 画面外のカバーを手放す
/// SwiftUIのLazyコンテナは画面外へ出たセルの保持物を解放しない(LazyCellImageBudget参照)。
/// タイル1枚につきカバーを最大6枚持つため、コレクションが多いライブラリでは端まで流すだけで
/// 相応の量が積み上がる。ページ一覧グリッドと同じ帳簿で数え、予算を超えたらグリッドごと
/// 作り直す。1枚あたりは表示に必要な画素数までしか復号していない
/// (CollectionCoverStore.image(for:maxPixelSize:))ので、予算はあちらより小さくてよい。
struct CollectionGridView: View {
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var coverExtractor: CollectionCoverExtractor
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var appState: AppState
    @ObservedObject var state: WelcomeLibraryState
    let library: BookLibrary
    let allowsEditing: Bool

    /// タイルの間隔。
    private static let spacing: CGFloat = 24
    /// 画面外に残ってよいカバーの総量。
    private static let coverByteBudget = 64 * 1024 * 1024

    @State private var cellImageBudget = LazyCellImageBudget(byteBudget: coverByteBudget)
    /// リネーム・削除の対象。**モデルの参照ではなくidで持つ。**`@Model`のクラスは
    /// PersistentModel経由でIdentifiableに適合しており、自前の`id: UUID`と要件が衝突しうるため、
    /// このアプリでは一貫してidを明示して扱う(BookLibrary.swift末尾のコメント参照)。
    @State private var renamingCollectionID: UUID?
    /// 削除の確認を出している対象。空なら出していない。右クリックの「削除…」(1件)と
    /// ゴミ箱(編集モードで選んだぶん)の**両方がここへ集まる** ―― 同じビューに`.alert`を
    /// 2つ重ねると片方しか出ないことがあるため(WelcomeLibraryPaneの`.sheet`と同じ癖)。
    @State private var deletingCollectionIDs: [UUID] = []

    private var collections: [BookCollection] {
        collectionStore.collections(in: library, sort: state.collectionSort)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                LibraryPaneControls(
                    addHelp: "New Collection",
                    onAdd: { beginCreatingCollection() },
                    deleteHelp: "Delete Selected Collections",
                    canDelete: !state.selectedCollectionIDs.isEmpty,
                    onDelete: { deletingCollectionIDs = Array(state.selectedCollectionIDs) },
                    isEditing: $state.isEditing,
                    sort: $state.collectionSort,
                    sortFields: FavoritesSortOption.Field.allCases,
                    size: $state.tileSize,
                    sizeRange: WelcomeLibraryState.tileSizeRange,
                    sizeHelp: "Tile Size",
                    library: library,
                    allowsEditing: allowsEditing
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if collections.isEmpty {
                emptyMessage
            } else {
                grid
            }
        }
        .sheet(
            isPresented: Binding(
                get: { renamingCollectionID != nil },
                set: { if !$0 { renamingCollectionID = nil } }
            )
        ) {
            if let collection = renamingCollectionID.flatMap({ collectionStore.collection(withID: $0) }) {
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
            deletionTitle,
            isPresented: Binding(
                get: { !deletingCollectionIDs.isEmpty },
                set: { if !$0 { deletingCollectionIDs = [] } }
            )
        ) {
            Button("Cancel", role: .cancel) { deletingCollectionIDs = [] }
            Button("Delete", role: .destructive) { confirmDeletion() }
        } message: {
            if deletingCollectionIDs.count == 1 {
                Text("The books themselves are not deleted. Only this collection and its cover images are removed.")
            } else {
                Text("The books themselves are not deleted. Only these collections and their cover images are removed.")
            }
        }
    }

    /// 1件のときは従来どおりの文言、まとめて消すときは冊数入りの文言。英語では
    /// 「1 collections」になってしまうので、単数・複数で鍵を分けている。
    private var deletionTitle: Text {
        deletingCollectionIDs.count == 1
            ? Text("Delete Collection?")
            : Text("Delete \(deletingCollectionIDs.count) collections?")
    }

    private func confirmDeletion() {
        // 確認を出している間に別のウインドウが消していることがあるので、idから引き直す。
        let targets = deletingCollectionIDs.compactMap { collectionStore.collection(withID: $0) }
        deletingCollectionIDs = []
        guard !targets.isEmpty else { return }
        collectionStore.delete(targets)
        state.clearSelection()
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: state.tileSize), spacing: Self.spacing)],
                spacing: Self.spacing
            ) {
                ForEach(collections, id: \.id) { collection in
                    tile(for: collection)
                }
            }
            .padding(24)
            // 画面外セルの保持物をまとめて手放すための作り直し(型コメント参照)。
            .id(cellImageBudget.epoch)
        }
    }

    @ViewBuilder
    private func tile(for collection: BookCollection) -> some View {
        let tile = CollectionTile(
            collection: collection,
            items: Array(
                collectionStore.items(in: collection, sort: state.itemSort)
                    .prefix(library.coverAspectRatio.tileCellCount)
            ),
            exists: { collectionStore.cachedFileExists(for: $0) },
            isExtracting: { coverExtractor.inFlightItemIDs.contains($0.id) },
            cropAnchor: { cropAnchor(for: $0) },
            coverStore: collectionStore.coverStore,
            aspectRatio: library.coverAspectRatio,
            size: state.tileSize,
            onImageRetained: { image in
                // 1画面に並ぶタイル数の見積もり(帳簿の下限。LazyCellImageBudget参照)。
                cellImageBudget.note(retaining: image, minimumCellCount: 48)
            },
            isEditing: allowsEditing && state.isEditing,
            isSelected: state.selectedCollectionIDs.contains(collection.id),
            onOpen: { state.openedCollectionID = collection.id },
            onToggleSelection: { state.toggleCollectionSelection(collection.id) }
        )
        // 右クリックのメニューは編集モードのときだけ付ける。**項目が空のcontextMenuは付けない**
        // ―― 空の枠が一瞬出るだけの当たり所になる(WelcomeQuickOpenList.rowの同じ判断)。
        if allowsEditing && state.isEditing {
            tile.contextMenu {
                // 編集モード中はクリックが選択になるので、中へ入る道をここに残す
                // (CollectionTileの型コメント参照)。
                Button("Open") { state.openedCollectionID = collection.id }
                Divider()
                Button("Add Books…") {
                    state.addingBooks = .init(
                        collectionID: collection.id, name: collection.name, libraryID: library.id
                    )
                }
                Divider()
                Button("Rename…") { renamingCollectionID = collection.id }
                Button("Delete…", role: .destructive) { deletingCollectionIDs = [collection.id] }
            }
        } else {
            tile
        }
    }

    /// このカバーで残す位置。本ごとの上書き(BookLayoutSettings)があればそれ、無ければ
    /// ライブラリの既定。`bookLayoutSettings`はbookIDの辞書引きなのでセル単位で呼んでよい
    /// (LayoutStore.settingsByBookID参照)。
    private func cropAnchor(for item: CollectionItem) -> CoverCropAnchor {
        layoutStore.bookLayoutSettings(forBookID: item.bookID)?.coverCropAnchor
            ?? library.coverCropAnchor
    }

    private var emptyMessage: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            if appState.isPrivateWindow {
                // シークレットウインドウであることと、その意味(何も記録されない)を、本を開く前に
                // 明示する。タイトルバーの「(シークレット)」だけでは見落とされるため。
                VStack(spacing: 6) {
                    Label("Private Window", systemImage: "eyeglasses")
                        .font(.headline)
                    Text("Books opened in this window leave no trace: no history, reading position, bookmarks, favorites, layouts, metadata, or thumbnail cache is saved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                // 文字だけの塊なので、面の「文字の影」設定に乗せる(すりガラス面の決まりごと)。
                .panelOutlinedContent()
                .padding(.bottom, 8)
            }
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
            Text("No collections to show")
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
            Text("You can also open by dragging and dropping here")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .panelOutlinedContent()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginCreatingCollection() {
        // 名前だけ先に決める(本はこの後の「本を追加」パネルで入れる)。1冊も入らなければ
        // コレクションの行は作られない(AddBooksPanelの型コメント参照)。
        state.pendingCreations.append(
            .init(defaultName: "", books: [], fromShelf: false)
        )
    }
}
