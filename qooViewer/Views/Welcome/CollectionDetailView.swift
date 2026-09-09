import Combine
import CoreGraphics
import SwiftUI

/// コレクションの中(改善要望5)。登録した本のカバーを並べ、クリックで開く。
///
/// 編集モード中はクリックが**開く**から**選ぶ/選び直す**に変わり、カバーの左上に選択の印
/// (SelectionCheckmarkBadge)が出る。選んだ本は右上のゴミ箱でまとめてコレクションから
/// 削除できる(本の実体は消えない)。編集モード中に開きたいときは右クリックの「開く」から。
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
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
    @ObservedObject var state: WelcomeLibraryState
    let collection: BookCollection
    /// このコレクションが属するライブラリ。`collection.library`からも辿れるが、カバーの
    /// 縦横比のように**必ず要る**値の出どころがOptionalだと描き分けが増えるため、
    /// 帯で選択中のものを呼び出し側(WelcomeLibraryPane)から渡してもらう。
    let library: BookLibrary
    let allowsEditing: Bool

    private static let spacing: CGFloat = 16
    private static let coverByteBudget = 96 * 1024 * 1024

    @State private var cellImageBudget = LazyCellImageBudget(byteBudget: coverByteBudget)
    @State private var isRenaming = false
    /// 開こうとしたが実体が見つからなかった本。
    @State private var missingItem: CollectionItem?
    /// メタデータ編集シートを出している本(実体のURLは開く前に解決しておく)。
    @State private var metadataTarget: MetadataTarget?
    /// コレクションから外す確認を出している本。空なら出していない。右クリックの
    /// 「コレクションから削除」(1冊)とゴミ箱(選んだぶん)の両方がここへ集まる
    /// (CollectionGridView.deletingCollectionIDsと同じ理由)。
    @State private var removingItemIDs: [UUID] = []

    /// `.layoutDataDidChange` が届くたびに増やすだけの数。**この値自体は読まない。**
    ///
    /// カバーの切り出し位置は本ごとの上書き(BookLayoutSettings)から読んでいるが、LayoutStoreは
    /// その変更で`objectWillChange`を出さない ―― レイアウトの読み取りは頻繁なので、published を
    /// 「レイアウト情報を持つ本の集合が変わったとき」だけに絞ってある(LayoutStore.
    /// refreshLayoutBookID のコメント)。そのため、通知を自分で拾って body を組み直す必要がある。
    /// 拾わないと、メタデータ編集で位置を変えても**次に何かをクリックするまで絵が変わらない**
    /// (ユーザー指摘 2026-09-09)。
    @State private var layoutRevision = 0

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

    /// このカバーで残す位置(本ごとの上書き ?? ライブラリの既定。CollectionGridViewと同じ)。
    private func cropAnchor(for item: CollectionItem) -> CoverCropAnchor {
        layoutStore.bookLayoutSettings(forBookID: item.bookID)?.coverCropAnchor
            ?? library.coverCropAnchor
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
        .onReceive(NotificationCenter.default.publisher(for: .layoutDataDidChange)) { _ in
            layoutRevision &+= 1
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
                deleteHelp: "Remove Selected Books",
                canDelete: !state.selectedItemIDs.isEmpty,
                onDelete: { removingItemIDs = Array(state.selectedItemIDs) },
                isEditing: $state.isEditing,
                sort: $state.itemSort,
                // 本の行には「更新日時」に相当する情報が無い(CollectionStore.items(in:sort:))。
                sortFields: [.name, .dateAdded],
                size: $state.coverSize,
                sizeRange: WelcomeLibraryState.coverSizeRange,
                sizeHelp: "Cover Size",
                library: library,
                allowsEditing: allowsEditing
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // 「本が見つかりません」のalertとは別の階層に付ける ―― 同じビューに`.alert`を2つ
        // 重ねると片方しか出ないことがある(`.sheet`と同じSwiftUIの癖)。
        .alert(
            removalTitle,
            isPresented: Binding(
                get: { !removingItemIDs.isEmpty },
                set: { if !$0 { removingItemIDs = [] } }
            )
        ) {
            Button("Cancel", role: .cancel) { removingItemIDs = [] }
            Button("Delete", role: .destructive) { confirmRemoval() }
        } message: {
            Text("The books themselves are not deleted. Only their entries in this collection and their cover images are removed.")
        }
    }

    /// 1冊のときと複数のときで鍵を分ける(英語で「1 books」にしないため。
    /// CollectionGridView.deletionTitleと同じ判断)。
    private var removalTitle: Text {
        removingItemIDs.count == 1
            ? Text("Remove this book from the collection?")
            : Text("Remove \(removingItemIDs.count) books from the collection?")
    }

    private func confirmRemoval() {
        // 確認を出している間に別のウインドウが消していることがあるので、idから引き直す。
        let targets = removingItemIDs.compactMap { collectionStore.item(withID: $0) }
        removingItemIDs = []
        guard !targets.isEmpty else { return }
        collectionStore.remove(targets)
        state.clearSelection()
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
            BookMetadataSheet(item: target.item, sourceURL: target.url, library: library)
        }
    }

    private func cell(for item: CollectionItem) -> some View {
        let isEditing = allowsEditing && state.isEditing
        let isSelected = state.selectedItemIDs.contains(item.id)
        let shape = RoundedRectangle(
            cornerRadius: CollectionCoverThumbnail.cornerRadius(forWidth: state.coverSize),
            style: .continuous
        )
        return CollectionCoverThumbnail(
            item: item,
            coverStore: collectionStore.coverStore,
            aspectRatio: library.coverAspectRatio,
            anchor: cropAnchor(for: item),
            displayWidth: state.coverSize,
            exists: collectionStore.cachedFileExists(for: item),
            isExtracting: coverExtractor.inFlightItemIDs.contains(item.id),
            onImageRetained: { image in
                cellImageBudget.note(retaining: image, minimumCellCount: 24)
            }
        )
        // 選択中の枠と印(CollectionTileと同じ形・同じ理由。輪郭の扱いは
        // SelectionCheckmarkBadgeの型コメント参照)。
        .overlay {
            shape.strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(isSelected ? 1 : 0)
        }
        .panelOutlinedAccent(in: shape, isEnabled: isSelected)
        .overlay(alignment: .topLeading) {
            if isEditing {
                SelectionCheckmarkBadge(isSelected: isSelected, size: state.coverSize)
            }
        }
        .contentShape(Rectangle())
        .help(item.title)
        // 編集モード中は「開く」ではなく「選ぶ/選び直す」。
        .onTapGesture {
            if isEditing {
                state.toggleItemSelection(item.id)
            } else {
                open(item)
            }
        }
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
            // 「メタデータの編集」は**編集モードを条件にしない**(ユーザー指摘 2026-09-09)。
            // 棚から本を出し入れする操作ではなく、その1冊の中身を整える操作なので、モードの
            // 奥に置く理由が無い(帯のリネームと同じ判断。WelcomeTopBar.canEditLibraries参照)。
            if allowsEditing {
                Divider()
                Button("Edit Metadata…") {
                    guard let url = collectionStore.resolvedExistingURL(for: item) else {
                        missingItem = item
                        return
                    }
                    metadataTarget = MetadataTarget(item: item, url: url)
                }
            }
            // コレクションから外すのは取り消せない削除なので、ゴミ箱と同じく編集モードの中に置く。
            // 別のコレクションへ移すのも棚をいじる操作なので、同じ側に置く。
            if allowsEditing && state.isEditing {
                Divider()
                moveMenu(for: item)
                Divider()
                Button("Remove from Collection", role: .destructive) {
                    // 1冊でも確認は出す(ゴミ箱と同じ扱い。取り消せない書き込みなので、
                    // 入り口によって確認の有無が変わらないようにする)。
                    removingItemIDs = [item.id]
                }
            }
        }
    }

    /// この本を別のコレクションへ移す(ユーザー要望 2026-09-09)。
    ///
    /// ライブラリが1つしかなければ、そのライブラリのコレクションを**直に**並べる ―― 行き先が
    /// 1つの入れ子を毎回開かせない。2つ以上あればライブラリごとの入れ子にする(コレクション名は
    /// ライブラリをまたぐと重複しうるので、どの棚のものか分かる必要がある)。
    ///
    /// 移す先が1つも無いとき(コレクションがこれ1つだけ)は項目ごと出さない。
    @ViewBuilder
    private func moveMenu(for item: CollectionItem) -> some View {
        let libraries = collectionStore.libraries
        let targetsByLibrary = libraries.map { target in
            (
                library: target,
                collections: collectionStore.collections(in: target, sort: .nameAscending)
                    .filter { $0.id != collection.id }
            )
        }
        .filter { !$0.collections.isEmpty }

        if !targetsByLibrary.isEmpty {
            Menu("Move to Collection") {
                if targetsByLibrary.count == 1, let only = targetsByLibrary.first {
                    ForEach(only.collections, id: \.id) { target in
                        moveButton(for: item, to: target)
                    }
                } else {
                    ForEach(targetsByLibrary, id: \.library.id) { entry in
                        Menu(entry.library.displayName(language: locale)) {
                            ForEach(entry.collections, id: \.id) { target in
                                moveButton(for: item, to: target)
                            }
                        }
                    }
                }
            }
        }
    }

    private func moveButton(for item: CollectionItem, to target: BookCollection) -> some View {
        Button(target.name) {
            collectionStore.move(item, to: target)
            // 移した先は今見えていないので、選択に残さない
            // (見えていないものをゴミ箱が消さないための決まり)。
            state.clearSelection()
        }
    }

    private var emptyMessage: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Text("No books in this collection")
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
            // 一覧側と同じ理由で、案内はドロップの意味に合わせる
            // (CollectionGridView.isRegisteringDropsのコメント参照)。ここも編集モードの
            // 外では、落とした本は**コレクションに入らず開く**。
            Text(
                allowsEditing && state.isEditing
                    ? "Drag books here to add them"
                    : "You can also open by dragging and dropping here"
            )
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
