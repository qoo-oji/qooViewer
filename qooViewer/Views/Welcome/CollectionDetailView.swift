import Combine
import CoreGraphics
import SwiftUI

/// コレクションの中(改善要望5)。登録した本のカバーを並べ、クリックで開く。
///
/// 編集モード中はクリックが**開く**から**選ぶ/選び直す**に変わり、カバーの左上に選択の印
/// (SelectionCheckmarkBadge)が出る。選んだ本は右上のゴミ箱でまとめてコレクションから
/// 削除できる(本の実体は消えない)。編集モード中に開きたいときは右クリックの「開く」から。
///
/// カバーの下に何を書くかは**アプリ全体の設定**(環境設定「外観」→「ウェルカム画面」。
/// `AppPreferences.collectionCoverCaptionStyle`)。既定は**何も書かない** ―― カバーがそのまま
/// 見出しになるうえ、名前を添えると1冊あたりの高さが増えて一覧性が落ちるため。書かない設定でも
/// どの本かはツールチップ(`.help`)で確かめられる。
///
/// ■ 実体が見つからない本
/// 一覧を描くたびにディスクを触ることはせず、CollectionStoreが非同期に更新している
/// 存在確認の結果(cachedFileExists)で淡く描くだけにする。実際に開こうとした瞬間に初めて
/// ブックマークを解決し、そこで見つからなければアラートを出す(お気に入りと同じ流れ)。
struct CollectionDetailView: View {
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var coverExtractor: CollectionCoverExtractor
    @EnvironmentObject private var autoFolderScanner: CollectionAutoFolderScanner
    @EnvironmentObject private var layoutStore: LayoutStore
    /// **値は読まない。**タイトル(caption(for:)と並び順「タイトル」)は
    /// `collectionStore.titleResolver`から取るが、あちらはpublishしないキャッシュなので、
    /// メタデータ/フォーマットが変わったときに描き直すための購読としてここに残す
    /// (外すと、別のウインドウでタイトルを登録してもこの画面の文字と並びが古いまま残る)。
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var formatStore: MetadataFormatStore
    @EnvironmentObject private var preferences: AppPreferences
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
    /// グリッドの見えている大きさ。帳簿の下限セル数(minimumCellCount)を見積もるためだけに持つ。
    @State private var gridSize: CGSize = .zero
    @State private var isRenaming = false
    /// 開こうとしたが実体が見つからなかった本。
    ///
    /// **モデルの参照ではなくidと表示名で持つ**(監査で指摘 2026-09-09)。アラートを出している間に
    /// 別のウインドウがその本を外してsaveすると、`CollectionItem`本体を持ったままでは、次の
    /// 描き直しで消えた行の属性を読んで落ちる(SwiftDataの "model instance was invalidated")。
    /// 削除するときはidから引き直し、無ければ黙って何もしない。
    @State private var missingBook: MissingBook?
    /// メタデータ編集シートを出している本(実体のURLは開く前に解決しておく)。同じ理由でidで持つ。
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

    /// 余白から帯を引いてまとめて選ぶための入れ物(MarqueeSelection参照。`@State`で持つだけで
    /// 購読しない理由はCollectionGridViewの同じ宣言のコメント)。
    @State private var marquee = MarqueeSelection()

    /// メタデータ編集シートの対象。シートを出す時点で本のURLが解決できている必要があるため
    /// (BookMetadataSheetのコメント参照)、行のidとURLを組にして持つ。
    private struct MetadataTarget: Identifiable {
        let id: UUID
        let url: URL
    }

    /// 「本が見つかりません」の対象(missingBookのコメント参照)。
    ///
    /// `reason`は開こうとして失敗した時点で割り出したもの(CollectionStore.location(for:))。
    /// **「見つからない」の理由は1つではない**ので、文言を分けるために持つ ―― 外付けを
    /// 外しているだけなら「削除」を勧めるべきではないし、ブックマークが使えなくなっただけなら
    /// 実体はまだあるかもしれない(BookLocationの型コメント参照)。
    private struct MissingBook {
        let id: UUID
        let title: String
        let reason: BookLocation
    }

    /// 「本が見つかりません」の本文。理由ごとに書き分ける(MissingBook.reason参照)。
    @ViewBuilder
    private var missingBookMessage: some View {
        let name = Text(missingBook?.title ?? "")
        switch missingBook?.reason {
        case .volumeUnavailable:
            Text("The volume that holds “") + name
                + Text("” is not connected. Connect it and try again — nothing has been lost.")
        case .unreachable:
            Text("qooViewer could not work out where “") + name
                + Text("” is. The file may still be there: open it once from its current location and the collection will catch up.")
        default:
            // .missing(ボリュームは付いているのに実体に届かない)と、確認が間に合って
            // いない場合。移動と削除は区別できないので、どちらとも言わない。
            Text("The file or folder for “") + name
                + Text("” could not be found. It may have been moved or deleted.")
        }
    }

    private var items: [CollectionItem] {
        collectionStore.items(in: collection, sort: state.itemSort)
    }

    /// いま出ている本が残らず選ばれているか。空のときは false(押せる先が無い)。
    private var isEveryItemSelected: Bool {
        let shown = items
        return !shown.isEmpty && shown.allSatisfy { state.selectedItemIDs.contains($0.id) }
    }

    /// 全選択 / 全選択解除。**いま出ているぶんだけ**を入れ替える(CollectionGridViewと同じ)。
    private func toggleSelectAll() {
        if isEveryItemSelected {
            state.clearSelection()
        } else {
            state.selectedItemIDs = Set(items.map(\.id))
        }
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
                    onCommit: { name, _ in collectionStore.rename(collection, to: name) }
                )
            }
        }
        .alert(
            "Book Not Found",
            isPresented: Binding(
                get: { missingBook != nil },
                set: { if !$0 { missingBook = nil } }
            )
        ) {
            Button("OK") { missingBook = nil }
            // 削除はDBへの書き込みなので、シークレットウインドウでは出さない
            // (ContentViewの「お気に入りが見つかりません」と同じ判断)。
            if allowsEditing {
                Button("Remove from Collection", role: .destructive) {
                    // 確認を出している間に別のウインドウが消していることがあるので、idから引き直す。
                    if let item = missingBook.flatMap({ collectionStore.item(withID: $0.id) }) {
                        collectionStore.remove(item)
                    }
                    missingBook = nil
                }
            }
        } message: {
            missingBookMessage
        }
        .onReceive(NotificationCenter.default.publisher(for: .layoutDataDidChange)) { _ in
            layoutRevision &+= 1
        }
        // 自動登録フォルダを見に行く契機のひとつ(CollectionAutoFolderScannerの型コメント参照)。
        // ウェルカム画面のonAppearは一覧から中へ入るときには走らないため、ここでも呼ぶ ――
        // 開いた棚がその場で埋まるのが、この機能のいちばん見えるところなので。
        .onAppear { autoFolderScanner.scheduleScan() }
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
                isAllSelected: isEveryItemSelected,
                canSelectAll: !items.isEmpty,
                onToggleSelectAll: { toggleSelectAll() },
                deleteHelp: "Remove Selected Books",
                canDelete: !state.selectedItemIDs.isEmpty,
                onDelete: { removingItemIDs = Array(state.selectedItemIDs) },
                isEditing: $state.isEditing,
                sort: $state.itemSort,
                // 本の行には「更新日時」に相当する情報が無い(CollectionStore.items(in:sort:))。
                // 「タイトル」を出すのはこの画面だけ(ユーザー要望 2026-09-10。
                // FavoritesSortOptionの型コメント参照)。ファイル名と並べて見せるため、
                // 同じ文字の基準どうしを隣に置く。
                sortFields: [.name, .title, .dateAdded],
                size: $state.coverSize,
                sizeRange: WelcomeLibraryState.coverSizeRange,
                sizeHelp: "Cover Size",
                library: library,
                collection: collection,
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

    /// 帳簿の下限セル数: 画面内に収まりうるカバーの数(列数 × 見えている行数 + 先読み分)の3倍
    /// (CollectionGridView.minimumCellCountと同じ理由・同じ見積もり方。以前は定数24だった)。
    private var minimumCellCount: Int {
        LazyCellImageBudget.minimumCellCount(
            visibleSize: gridSize,
            cellWidth: state.coverSize,
            cellHeight: state.coverSize / library.coverAspectRatio.value + captionHeight,
            spacing: Self.spacing, padding: 24
        )
    }

    /// カバーの下の文字のぶんの高さ(出さない設定なら0)。1行ぶんの概算 + VStackの間隔で、
    /// 見えている行数の見積もり(上のminimumCellCount)にだけ使う
    /// (ThumbnailGridViewがキャプションのぶんを見込むのとまったく同じ式)。
    private var captionHeight: CGFloat {
        guard preferences.collectionCoverCaptionStyle != .none else { return 0 }
        return (preferences.collectionCoverCaptionFontSize * 1.3).rounded(.up) + 4
    }

    /// グリッドの作り直しの鍵(下の`.id`とマーキーの控えの捨て方の両方が使う)。
    private var gridID: String {
        "\(collection.id.uuidString)-\(cellImageBudget.epoch)"
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: state.coverSize), spacing: Self.spacing)],
                spacing: Self.spacing
            ) {
                ForEach(items, id: \.id) { item in
                    cell(for: item)
                        // 帯の当たり判定に使う矩形を知らせる(MarqueeSelection参照)。
                        .marqueeCell(item.id, in: marquee)
                }
            }
            .padding(24)
            // 編集モード中は、余白(カバーの隙間・外周・最後の行より下)から帯を引いて
            // まとめて選べる。カバーの上で押し始めたドラッグは従来どおりカバーのもの。
            .marqueeSelectable(
                marquee,
                isEnabled: allowsEditing && state.isEditing,
                minimumHeight: gridSize.height,
                selection: $state.selectedItemIDs,
                shownIDs: Set(items.map(\.id))
            )
            // コレクションが変わったときも作り直して、前のコレクションのカバーを手放す
            // (CollectionGridViewの同じ`.id`のコメント参照)。
            .id(gridID)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            gridSize = size
        }
        // 並ぶものが総入れ替えになったら、帯が覚えている矩形を捨てる(コレクションの
        // 切り替え・グリッドの作り直し)。`.id`より外に付ける理由はCollectionGridView参照。
        .onChange(of: gridID) { marquee.forgetFrames() }
        // 名前のリネームとは別の階層に付ける ―― 同じビューに2つの.sheetを重ねると、
        // 片方しか出ないことがある(SwiftUIの既知の癖)。
        .sheet(item: $metadataTarget) { target in
            BookMetadataSheet(itemID: target.id, sourceURL: target.url, library: library)
        }
    }

    private func cell(for item: CollectionItem) -> some View {
        let isEditing = allowsEditing && state.isEditing
        let isSelected = state.selectedItemIDs.contains(item.id)
        let shape = RoundedRectangle(
            cornerRadius: CollectionCoverThumbnail.cornerRadius(forWidth: state.coverSize),
            style: .continuous
        )
        return VStack(spacing: 4) {
            CollectionCoverThumbnail(
                item: item,
                coverStore: collectionStore.coverStore,
                aspectRatio: library.coverAspectRatio,
                anchor: cropAnchor(for: item),
                displayWidth: state.coverSize,
                exists: collectionStore.cachedFileExists(for: item),
                isExtracting: coverExtractor.inFlightItemIDs.contains(item.id),
                onImageRetained: { image in
                    cellImageBudget.note(retaining: image, minimumCellCount: minimumCellCount)
                }
            )
            // 選択中の枠と印(CollectionTileと同じ形・同じ理由。輪郭の扱いは
            // SelectionCheckmarkBadgeの型コメント参照)。**カバーにだけ掛ける** ――
            // 下の文字まで枠で囲むと、選んだ範囲がカバー1枚に見えなくなる。
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

            // カバーの下の文字(設定が「表示しない」なら行ごと出さない)。すりガラス面に
            // 直接置く文字なので輪郭が要る(CLAUDE.mdの表)。
            if let caption = caption(for: item) {
                Text(caption)
                    .font(.system(size: preferences.collectionCoverCaptionFontSize))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .panelOutlinedContent()
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
            let targets = contextTargets(for: item)
            // 1冊を相手にする操作は、複数選んでいる間は**選べないようにする**(ユーザー指摘
            // 2026-09-09)。押せてしまうと、右クリックした1冊だけに効くのか選んだ全部に効くのかが
            // 画面から読めない。まとめてできるのは「コレクションから削除」だけ。
            let isSingle = targets.count == 1
            BookOpenContextMenuItems(
                onOpen: { open(item) },
                onOpenIn: { destination in
                    guard let url = collectionStore.resolvedExistingURL(for: item) else {
                        missingBook = MissingBook(
                        id: item.id, title: item.title,
                        reason: collectionStore.location(for: item)
                    )
                        return
                    }
                    BookWindowOpener.open(
                        BookOpenRequest(url), to: destination, from: appState,
                        launchCoordinator: launchCoordinator, openWindow: openWindow
                    )
                }
            )
            .disabled(!isSingle)
            Divider()
            // 「Finderで開く」(ユーザー要望 2026-09-09)。**編集モードを条件にしない** ――
            // 棚をいじる操作ではなく、その本がどこにあるかを見るだけの操作なので。
            //
            // 実体のURLはここで解決する。コレクションが持っているのはセキュリティスコープ付きの
            // ブックマークで、`isDirectory`を控えてはいない(履歴と違う点)。解決したURLを
            // そのまま渡せば`FinderReveal`の既定の経路が種別を判定できる
            // (FinderReveal.reveal(_:isDirectory:)のコメント参照)。
            Button("Show in Finder") {
                guard let url = collectionStore.resolvedExistingURL(for: item) else {
                    missingBook = MissingBook(
                        id: item.id, title: item.title,
                        reason: collectionStore.location(for: item)
                    )
                    return
                }
                FinderReveal.reveal(url)
            }
            .disabled(!isSingle)

            // 「メタデータの編集」は**編集モードを条件にしない**(ユーザー指摘 2026-09-09)。
            // 棚から本を出し入れする操作ではなく、その1冊の中身を整える操作なので、モードの
            // 奥に置く理由が無い(帯のリネームと同じ判断。WelcomeTopBar.canEditLibraries参照)。
            if allowsEditing {
                Divider()
                Button("Edit Metadata…") {
                    guard let url = collectionStore.resolvedExistingURL(for: item) else {
                        missingBook = MissingBook(
                        id: item.id, title: item.title,
                        reason: collectionStore.location(for: item)
                    )
                        return
                    }
                    metadataTarget = MetadataTarget(id: item.id, url: url)
                }
                .disabled(!isSingle)
            }
            // コレクションから外すのは取り消せない削除なので、ゴミ箱と同じく編集モードの中に置く。
            //
            // **「別のコレクションへ移す」は置かない**(2026-09-09に一度入れて同日に撤回した)。
            // 自動登録フォルダを持つコレクションから本を移しても、次の走査でそのまま戻ってくる
            // ―― 移動が成立したりしなかったりする操作は、右クリックの一項目としては読めない。
            // 移したいときは、移す先へ本を足してから元から外す。
            if allowsEditing && state.isEditing {
                Divider()
                Button("Remove from Collection", role: .destructive) {
                    // 1冊でも確認は出す(ゴミ箱と同じ扱い。取り消せない書き込みなので、
                    // 入り口によって確認の有無が変わらないようにする)。
                    removingItemIDs = targets.map(\.id)
                }
            }
        }
    }

    /// カバーの下に出す文字。設定が「表示しない」(既定)ならnilで、行そのものを出さない。
    private func caption(for item: CollectionItem) -> String? {
        switch preferences.collectionCoverCaptionStyle {
        case .none: return nil
        case .fileName: return item.title
        case .title: return metadataTitle(for: item)
        }
    }

    /// 「メタデータの編集」がこの本に出すのと同じタイトル(登録済みならDBの値、未登録なら
    /// ファイル名からの推測値。決め方はBookTitleResolverの型コメント参照)。
    ///
    /// 以前はここで毎回その場で推測していた ―― 1冊ぶんならメインアクター上でも一瞬で終わり、
    /// LazyVGridが組み立てるのは見えているセルだけだったため。並び順に「タイトル」が増えて
    /// (ユーザー要望 2026-09-10)、見えていない本ぶんも要るようになったので、覚えておく役を
    /// BookTitleResolverへ移した。**表示と並べ替えが同じ関数を通る**ようにもなる。
    private func metadataTitle(for item: CollectionItem) -> String {
        collectionStore.titleResolver.title(forBookID: item.bookID)
    }

    /// この右クリックが相手にする本(Finderと同じ規則。CollectionGridView.contextTargetsと同じ)。
    ///
    /// **選んである本を右クリックしたなら、選んだぶん全部。選択の外を右クリックしたなら、
    /// その1冊だけ**(選択は変えない)。これでゴミ箱と右クリックの「コレクションから削除」が
    /// 同じものを相手にする ―― 以前は右クリックだけが常に1冊きりだった。
    private func contextTargets(for item: CollectionItem) -> [CollectionItem] {
        guard state.selectedItemIDs.count > 1,
              state.selectedItemIDs.contains(item.id)
        else { return [item] }
        return items.filter { state.selectedItemIDs.contains($0.id) }
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
            missingBook = MissingBook(
                        id: item.id, title: item.title,
                        reason: collectionStore.location(for: item)
                    )
            return
        }
        appState.open(url: url)
    }
}
