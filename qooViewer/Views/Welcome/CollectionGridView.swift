import Combine
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
    @Environment(\.locale) private var locale
    @ObservedObject var state: WelcomeLibraryState
    let library: BookLibrary
    let allowsEditing: Bool

    /// タイルの間隔。
    private static let spacing: CGFloat = 24
    /// 画面外に残ってよいカバーの総量。
    private static let coverByteBudget = 64 * 1024 * 1024

    @State private var cellImageBudget = LazyCellImageBudget(byteBudget: coverByteBudget)
    /// グリッドの見えている大きさ。帳簿の下限セル数(minimumCellCount)を見積もるためだけに持つ。
    @State private var gridSize: CGSize = .zero
    /// リネーム・削除の対象。**モデルの参照ではなくidで持つ。**`@Model`のクラスは
    /// PersistentModel経由でIdentifiableに適合しており、自前の`id: UUID`と要件が衝突しうるため、
    /// このアプリでは一貫してidを明示して扱う(BookLibrary.swift末尾のコメント参照)。
    @State private var renamingCollectionID: UUID?
    /// 削除の確認を出している対象。空なら出していない。右クリックの「削除…」(1件)と
    /// ゴミ箱(編集モードで選んだぶん)の**両方がここへ集まる** ―― 同じビューに`.alert`を
    /// 2つ重ねると片方しか出ないことがあるため(WelcomeLibraryPaneの`.sheet`と同じ癖)。
    @State private var deletingCollectionIDs: [UUID] = []

    /// `.layoutDataDidChange` が届くたびに増やすだけの数。**この値自体は読まない。**
    ///
    /// カバーの切り出し位置は本ごとの上書き(BookLayoutSettings)から読んでいるが、LayoutStoreは
    /// その変更で`objectWillChange`を出さない ―― レイアウトの読み取りは頻繁なので、published を
    /// 「レイアウト情報を持つ本の集合が変わったとき」だけに絞ってある(LayoutStore.
    /// refreshLayoutBookID のコメント)。そのため、通知を自分で拾って body を組み直す必要がある。
    /// 拾わないと、メタデータ編集で位置を変えても**次に何かをクリックするまで絵が変わらない**
    /// (ユーザー指摘 2026-09-09)。
    @State private var layoutRevision = 0

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
                    onCommit: { name, _ in collectionStore.rename(collection, to: name) }
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
        .onReceive(NotificationCenter.default.publisher(for: .layoutDataDidChange)) { _ in
            layoutRevision &+= 1
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

    /// 帳簿の下限セル数: 画面内に収まりうるカバーの数(列数 × 見えている行数 + 先読み分、
    /// × 札1枚のセル数)の3倍。これ未満で作り直すと、画面内ぶんの読み直しだけで再び予算へ達して
    /// 作り直しがループしかねない(LazyCellImageBudgetの型コメント参照。ThumbnailGridViewと
    /// 同じ見積もり方)。
    ///
    /// 以前は定数48(札8枚ぶん)だった(監査で指摘 2026-09-09)。どのウインドウでも1画面に
    /// 収まる札の数より少なく下限として効いておらず、27インチ5Kで札を最大・横長画像中心の
    /// ライブラリでは、画面内の168セルだけで64MBを超えてループする計算だった。
    private var minimumCellCount: Int {
        let tileWidth = state.tileSize
        // 札の高さ = 絵(ほぼ正方形。CoverAspectRatio.tileColumnsの計算)+ 名前の1行。
        let tileHeight = tileWidth + 24
        let columns = max(1, Int((gridSize.width - 48 + Self.spacing) / (tileWidth + Self.spacing)))
        let rows = Int((gridSize.height / max(tileHeight + Self.spacing, 1)).rounded(.up)) + 2
        let visibleCellEstimate = columns * rows * library.coverAspectRatio.tileCellCount
        return max(visibleCellEstimate * 3, 64)
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
            // 作り直しの鍵は2つ。
            //
            // - `epoch` … 画面外セルの保持物をまとめて手放すため(型コメント参照)
            // - `library.id` … ライブラリを切り替えたときに、**前のライブラリのカバーを手放す**
            //   ため。Lazyコンテナは ForEach の中身が総入れ替えになっても前に作ったセルを
            //   解放しない(型コメントと同じ話)ので、切り替えるたびに前の棚のぶんが
            //   `cellImageBudget` に乗ったまま積み上がる。並ぶものが全部変わる場面なので、
            //   ここで作り直して失うものは無い。
            .id("\(library.id.uuidString)-\(cellImageBudget.epoch)")
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            gridSize = size
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
            backgroundColor: library.coverBackgroundColor?.color ?? Color.primary.opacity(0.07),
            size: state.tileSize,
            onImageRetained: { image in
                cellImageBudget.note(retaining: image, minimumCellCount: minimumCellCount)
            },
            isEditing: allowsEditing && state.isEditing,
            isSelected: state.selectedCollectionIDs.contains(collection.id),
            onOpen: { state.openedCollectionID = collection.id },
            onToggleSelection: { state.toggleCollectionSelection(collection.id) }
        )
        // 右クリックのメニューは編集モードのときだけ付ける。**項目が空のcontextMenuは付けない**
        // ―― 空の枠が一瞬出るだけの当たり所になる(WelcomeQuickOpenList.rowの同じ判断)。
        if allowsEditing && state.isEditing {
            let targets = contextTargets(for: collection)
            // 1つを相手にする操作は、複数選んでいる間は**選べないようにする**(ユーザー指摘
            // 2026-09-09)。押せてしまうと、右クリックした1つだけに効くのか選んだ全部に効くのかが
            // 画面から読めない。
            let isSingle = targets.count == 1
            tile.contextMenu {
                // 編集モード中はクリックが選択になるので、中へ入る道をここに残す
                // (CollectionTileの型コメント参照)。
                Button("Open") { state.openedCollectionID = collection.id }
                    .disabled(!isSingle)
                Divider()
                Button("Add Books…") {
                    state.addingBooks = .init(
                        collectionID: collection.id, name: collection.name, libraryID: library.id
                    )
                }
                .disabled(!isSingle)
                Divider()
                moveMenu(for: targets)
                Divider()
                Button("Rename…") { renamingCollectionID = collection.id }
                    .disabled(!isSingle)
                Button("Delete…", role: .destructive) {
                    deletingCollectionIDs = targets.map(\.id)
                }
            }
        } else {
            tile
        }
    }

    /// この右クリックが相手にするコレクション(Finderと同じ規則)。
    ///
    /// **選んであるタイルを右クリックしたなら、選んだぶん全部。選択の外を右クリックしたなら、
    /// その1つだけ**(選択は変えない)。こうしておくと、ゴミ箱で消せるものと右クリックで消せる
    /// ものが食い違わない ―― 以前は右クリックの「削除」だけが常に1つきりで、3つ選んだ状態から
    /// 右クリックしても1つしか消えなかった。
    private func contextTargets(for collection: BookCollection) -> [BookCollection] {
        guard state.selectedCollectionIDs.count > 1,
              state.selectedCollectionIDs.contains(collection.id)
        else { return [collection] }
        return collections.filter { state.selectedCollectionIDs.contains($0.id) }
    }

    /// 選んだコレクションを別のライブラリへ移す(ユーザー要望 2026-09-09)。
    ///
    /// **まとめて動かせる操作**(ユーザー指摘 2026-09-09)。複数選んで右クリックしたら、選んだ
    /// ぶんが1回で移る ―― 棚をライブラリ間で整理するのに、1つずつ動かさせる理由が無い。
    ///
    /// ライブラリが1つしか無いときは項目ごと出さない ―― 行き先が存在しないメニューを開けても
    /// 意味が無い(「項目が空のcontextMenuは付けない」と同じ判断)。
    ///
    /// 移す先に同じ名前のコレクションがあるときは**選べないようにし、理由を名前に添える**。
    /// 押しても何も起きない項目にするより、なぜ選べないかがその場で分かるほうがよい
    /// (CollectionStore.canMove参照)。まとめて動かすときは**1つでも名前が衝突したらその
    /// 行き先ごと選べない** ―― 選んだうちのどれが動いてどれが残ったのかが読めない状態を作らない
    /// ため(CollectionStore.move(_ collections:to:)参照)。
    @ViewBuilder
    private func moveMenu(for targets: [BookCollection]) -> some View {
        let others = collectionStore.libraries.filter { $0.id != library.id }
        if !others.isEmpty {
            Menu("Move to Library") {
                ForEach(others, id: \.id) { target in
                    let canMove = targets.allSatisfy { collectionStore.canMove($0, to: target) }
                    Button {
                        collectionStore.move(targets, to: target)
                        // 移した先は今見えていないので、選択に残さない
                        // (見えていないものをゴミ箱が消さないための決まり)。
                        state.clearSelection()
                    } label: {
                        if canMove {
                            Text(target.displayName(language: locale))
                        } else {
                            Text("\(target.displayName(language: locale)) (name already used)")
                        }
                    }
                    .disabled(!canMove)
                }
            }
        }
    }

    /// このカバーで残す位置。本ごとの上書き(BookLayoutSettings)があればそれ、無ければ
    /// ライブラリの既定。`bookLayoutSettings`はbookIDの辞書引きなのでセル単位で呼んでよい
    /// (LayoutStore.settingsByBookID参照)。
    private func cropAnchor(for item: CollectionItem) -> CoverCropAnchor {
        layoutStore.bookLayoutSettings(forBookID: item.bookID)?.coverCropAnchor
            ?? library.coverCropAnchor
    }

    /// いまこの画面へのドロップが「登録」になるか(閲覧中は「開く」)。
    /// シークレットウインドウは編集モードに入れないので常にfalse。
    private var isRegisteringDrops: Bool { allowsEditing && state.isEditing }

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
            // ドロップの意味は編集モードで変わる(閲覧中は開く / 編集モード中は登録する。
            // WelcomeView.handleDrop参照)ので、**案内も一緒に変える**。編集モードに入っても
            // 「落とせば開けます」と出したままだったのは間違い(ユーザー指摘 2026-09-09)。
            Text(
                isRegisteringDrops
                    ? "Drop books or folders here to make a collection"
                    : "You can also open by dragging and dropping here"
            )
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
