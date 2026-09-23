import QooMetaKit
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
    /// 右クリックの「本の書き出し」(2026-09-23)。
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    /// **値は読まない。**タイトル(caption(for:)と並び順「タイトル」)は
    /// `collectionStore.titleResolver`から取るが、あちらはpublishしないキャッシュなので、
    /// メタデータ/フォーマットが変わったときに描き直すための購読としてここに残す
    /// (外すと、別のウインドウでタイトルを登録してもこの画面の文字と並びが古いまま残る)。
    @EnvironmentObject private var metadataStore: BookMetadataStore
    /// 規則(qooMeta)も同じ理由で読む(`body` で中身の印を読んで、変わったら描き直させる)。
    @Environment(MetadataRulesStore.self) private var rulesStore
    @EnvironmentObject private var preferences: AppPreferences
    /// 外観タブの設定。本のウインドウではそのウインドウの揃い(ノーマル/シークレット。ContentView が渡す)。
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @Environment(\.openWindow) private var openWindow
    /// 右クリックの「ファイルブラウザで開く」(改善要望7 段階 8)。本を開いていないウインドウなので、このウインドウの
    /// ウェルカム画面がファイルブラウザに切り替わる(FileBrowserReveal)。
    @Environment(\.revealInFileBrowser) private var revealInFileBrowser
    @Environment(\.locale) private var locale
    @ObservedObject var state: WelcomeLibraryState
    let collection: BookCollection
    /// このコレクションが属するライブラリ。`collection.library`からも辿れるが、カバーの
    /// 縦横比のように**必ず要る**値の出どころがOptionalだと描き分けが増えるため、
    /// 帯で選択中のものを呼び出し側(WelcomeLibraryPane)から渡してもらう。
    let library: BookLibrary
    let allowsEditing: Bool

    private static let spacing: CGFloat = 16
    /// グリッドの外周の余白。
    private static let gridPadding: CGFloat = 24
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
    /// 検索欄の焦点(メニューバーの「検索」⌘Fで入れる)。
    @FocusState private var isSearchFocused: Bool
    /// グリッドがキーの行き先か(「編集」▸「コピー」⌘C を受ける。2026-09-23)。カバーを押す・選び直すと入る。
    @FocusState private var isGridFocused: Bool
    /// このコレクションそのものの削除の確認を出しているか(メニューバーの「ホーム」▸「コレクションを削除…」。
    /// 一覧の右クリックと違い、中にいるときは開いているコレクションが相手)。
    @State private var isDeletingCollection = false
    /// コレクションの設定のポップオーバー(LibraryPaneControls.isShowingSettingsのコメント)。
    @State private var isShowingSettings = false
    /// 出している「本の書き出し」のシート(2026-09-23)。
    @State private var exportRequest: HomeBookExportRequest?

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

    /// 検索欄の文字列を照合できる形にしたもの。空欄ならnil(絞り込まない)。
    private var searchQuery: LibrarySearchQuery? {
        LibrarySearchQuery(state.searchText)
    }

    /// いま出ている本(検索で絞り込んだ後)。全選択・マーキー・右クリックの対象はすべてこれ
    /// (見えていないものに手を出さない決まり。WelcomeLibraryState.searchText参照)。
    private var items: [CollectionItem] {
        collectionStore.items(in: collection, sort: state.itemSort, matching: searchQuery)
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
        // 規則が変わったら描き直す(未登録の本のタイトルは規則で決まる。上の rulesStore のコメント)。
        let _ = rulesStore.rules.contentHash
        VStack(spacing: 0) {
            header
            if items.isEmpty {
                if searchQuery != nil, !collection.items.isEmpty {
                    WelcomeNoMatchesMessage(textKey: "No books match the search.")
                } else {
                    emptyMessage
                }
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
        // メニューバーの「ホーム」メニューから(WelcomeLibraryState.menuRequestのコメント)。右クリック・ゴミ箱と同じ経路で開く。
        .onChange(of: state.menuRequest) { _, _ in
            handleMenuRequest()
        }
    }

    private func handleMenuRequest() {
        guard let kind = state.takeMenuRequest(where: {
            switch $0 {
            case .renameCollection(let id): id == collection.id
            case .deleteCollections(let ids): ids == [collection.id]
            case .removeItems, .focusSearch, .showSettings, .showItemInFinder, .showItemInFileBrowser: true
            default: false
            }
        }) else { return }
        switch kind {
        case .showSettings where allowsEditing:
            isShowingSettings = true
        case .renameCollection where allowsEditing:
            isRenaming = true
        case .deleteCollections where allowsEditing:
            isDeletingCollection = true
        case .removeItems(let ids) where allowsEditing:
            removingItemIDs = ids
        case .focusSearch:
            isSearchFocused = true
        case .showItemInFinder(let id):
            withExistingURL(ofItemWithID: id) { FinderReveal.reveal($0) }
        case .showItemInFileBrowser(let id):
            withExistingURL(ofItemWithID: id) { revealInFileBrowser($0) }
        default:
            break
        }
    }

    /// 本の実体のURLを解決して渡す。見つからなければ「本が見つかりません」を出す(右クリックの各項目と同じ)。
    private func withExistingURL(ofItemWithID id: UUID, perform: (URL) -> Void) {
        guard let item = collectionStore.item(withID: id) else { return }
        guard let url = collectionStore.resolvedExistingURL(for: item) else {
            missingBook = MissingBook(id: item.id, title: item.title, reason: collectionStore.location(for: item))
            return
        }
        perform(url)
    }

    private var header: some View {
        // 左に戻るボタンと名前、中央に検索欄、右に操作列(WelcomePaneHeaderLayout参照)。
        //
        // 左と上下の余白は**戻るボタンが自分の押せる範囲として持つ**(backButtonのコメント)ので、
        // 行の余白は右だけ。検索欄の中央は、持たせた左の余白ぶんを勘定に入れて求める
        // (leadingInset)。
        WelcomePaneHeaderLayout(leadingInset: Self.backButtonHitSlop.width) {
            titleArea

            WelcomeSearchField(text: $state.searchText, prompt: "Search Books", focus: $isSearchFocused)

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
                // 同じ文字の基準どうしを隣に置く。本のファイルの「作成日」「変更日」
                // (ユーザー要望 2026-09-13。Finderと同じ値)も、日付の基準として追加日の後ろに。
                sortFields: [.name, .title, .dateAdded, .dateCreated, .dateModified],
                size: $state.coverSize,
                sizeRange: WelcomeLibraryState.coverSizeRange,
                sizeHelp: "Cover Size",
                library: library,
                collection: collection,
                allowsEditing: allowsEditing,
                isShowingSettings: $isShowingSettings
            )
        }
        .padding(.trailing, 16)
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

    /// 見出しの左側: 戻るボタン・コレクション名・冊数。
    private var titleArea: some View {
        HStack(spacing: 8) {
            backButton
                // ボタンが右に持った4ptぶん、名前との間隔を詰める(見た目の間隔は従来の8pt)。
                .padding(.trailing, -4)
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

            // 冊数。検索で絞り込んでいる間は「出ている数 / 全体」にする ―― 絞り込みが効いて
            // いることと、どれだけ残っているかが見出しだけで読める。
            Group {
                if searchQuery != nil {
                    Text("\(items.count) / \(collection.items.count)")
                } else {
                    Text("\(collection.items.count)")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .panelOutlinedContent()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 「本が見つかりません」(body)・本の削除(header)とは別の階層に付ける ―― 同じビューに`.alert`を2つ
        // 重ねると片方しか出ないことがある。文言は一覧の右クリックの「削除…」と同じ(CollectionGridView)。
        .alert("Delete Collection?", isPresented: $isDeletingCollection) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                // 先に一覧へ戻す(WelcomeLibraryPaneは消えたコレクションなら黙って一覧を出すが、消した行を
                // この画面が描き直しで読まないよう、idを先に外しておく)。
                let id = collection.id
                state.openedCollectionID = nil
                // 確認を出している間に別のウインドウが消していることがあるので、idから引き直す。
                if let target = collectionStore.collection(withID: id) {
                    collectionStore.delete([target])
                }
            }
        } message: {
            Text("The books themselves are not deleted. Only this collection and its cover images are removed.")
        }
    }

    /// 一覧へ戻るボタン(ユーザー要望 2026-09-13: 見た目はそのままで、押せる範囲を広げる)。
    ///
    /// 見た目はSidePanelNavButton(32×28のアイコンボタン)と同じ。押せる範囲だけを、見出しの
    /// 行の高さいっぱい(上下の余白ぶん)と左の余白、名前との間まで広げてある ―― 画面の左上の角へ
    /// 向かってポインタを投げたとき、少し外れても押せるように(Fittsの法則。端に近いものほど
    /// 外れにくい)。広げたぶんは透明な余白で、描画は1ptも変えない。
    ///
    /// **余白はレイアウト上の大きさとして持たせる。** 最初は余白を足して`contentShape`を掛け、
    /// 負の余白で元の大きさへ戻す形にしたが、実物では広げたところを押しても何も起きなかった
    /// (実測 2026-09-13)。SwiftUIの当たり判定はビューの枠の外まで伸びない。そのため見出しの行は
    /// 左と上下の余白を持たず、このボタンがその余白ぶん大きくなっている(header参照)。
    /// ホバーの淡い地は出さない ―― 他のアイコンボタンと同じく、押せることは形とツールチップで伝える。
    private var backButton: some View {
        Button {
            state.openedCollectionID = nil
        } label: {
            Image(systemName: "chevron.backward")
                .panelIconButtonLabel()
                .padding(.vertical, Self.backButtonHitSlop.height)
                .padding(.leading, Self.backButtonHitSlop.width)
                .padding(.trailing, 4)
                .contentShape(Rectangle())
        }
        // `.borderless`はAppKitのボタンとして描かれ、当たり判定がボタンの枠に閉じる(contentShapeで
        // 外へ広げても効かない)。SwiftUI側で判定させるため、押している間だけ淡くする自前の
        // スタイルにする。
        .buttonStyle(PressDimmingButtonStyle())
        .help("Back to Collections")
    }

    /// 戻るボタンの当たり判定を外へ広げる量(一覧側の見出しの余白 横16・縦8 と同じ)。
    private static let backButtonHitSlop = CGSize(width: 16, height: 8)

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
            spacing: Self.spacing, padding: Self.gridPadding
        )
    }

    /// カバーの下の文字のぶんの高さ(出さない設定なら0)。1行ぶんの概算 + VStackの間隔で、
    /// 見えている行数の見積もり(上のminimumCellCount)にだけ使う
    /// (ThumbnailGridViewがキャプションのぶんを見込むのとまったく同じ式)。
    private var captionHeight: CGFloat {
        guard appearance.collectionCoverCaptionStyle != .none else { return 0 }
        return (appearance.collectionCoverCaptionFontSize * 1.3).rounded(.up) + 4
    }

    /// グリッドの作り直しの鍵(下の`.id`とマーキーの控えの捨て方の両方が使う)。
    private var gridID: String {
        "\(collection.id.uuidString)-\(cellImageBudget.epoch)"
    }

    private var grid: some View {
        // 列はスライダーの値ちょうどの幅で並べる(CollectionGridView.gridと同じ理由・同じ作り。
        // WelcomeGridColumns参照)。
        GeometryReader { proxy in
            let columns = WelcomeGridColumns(
                availableWidth: proxy.size.width, itemWidth: state.coverSize,
                spacing: Self.spacing, padding: Self.gridPadding
            )
            ScrollView {
                LazyVGrid(columns: columns.gridItems(alignment: .top), spacing: Self.spacing) {
                    ForEach(items, id: \.id) { item in
                        cell(for: item)
                            // 帯の当たり判定に使う矩形を知らせる(MarqueeSelection参照)。
                            .marqueeCell(item.id, in: marquee)
                    }
                }
                // 列数ぶんに絞って中央へ(CollectionGridView.gridの同じ箇所のコメント参照)。
                .frame(width: columns.contentWidth)
                .frame(maxWidth: .infinity)
                .padding(Self.gridPadding)
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
        }
        // ピンチでカバーの大きさを変える(ユーザー要望 2026-09-13。welcomeGridPinch参照)。
        .welcomeGridPinch(scrollBox: marquee.scrollBox) { [weak state] magnification in
            state?.resizeCovers(byMagnification: magnification)
        }
        // 物理マウスホイール1ノッチで「設定したグリッドの行数」ぶん動かす(ユーザー要望 2026-09-23。
        // HomeWheelScroll)。1行ぶん = カバーの高さ + 下の文字 + 行間(高さの式は minimumCellCount と同じ)。
        .homeGridWheelScroll(
            scrollBox: marquee.scrollBox,
            distancePerNotch: (state.coverSize / library.coverAspectRatio.value + captionHeight + Self.spacing)
                * CGFloat(appearance.homeGridWheelScrollRows)
        )
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            gridSize = size
        }
        // 「編集」▸「コピー」(⌘C。2026-09-23、利用者の指示)。選んでいる本(編集モードの選択)をコピーする。
        // 焦点の枠は描かない(選択の枠がある。スマートライブラリのグリッドと同じ)。
        .focusable()
        .focusEffectDisabled()
        .focused($isGridFocused)
        .onCommand(#selector(NSText.copy(_:))) {
            copySelectedItems()
        }
        // 選び直したら(帯でまとめて選ぶ・「すべてを選択」のボタンも)、そのまま ⌘C が効くようにグリッドへ焦点を移す。
        .onChange(of: state.selectedItemIDs) { _, selection in
            if !selection.isEmpty { isGridFocused = true }
        }
        // 並ぶものが総入れ替えになったら、帯が覚えている矩形を捨てる(コレクションの
        // 切り替え・グリッドの作り直し)。`.id`より外に付ける理由はCollectionGridView参照。
        .onChange(of: gridID) { marquee.forgetFrames() }
        // 名前のリネームとは別の階層に付ける ―― 同じビューに2つの.sheetを重ねると、
        // 片方しか出ないことがある(SwiftUIの既知の癖)。
        .sheet(item: $metadataTarget) { target in
            BookMetadataSheet(itemID: target.id, sourceURL: target.url, library: library)
        }
        // 右クリックの「本の書き出し」(2026-09-23)。ほかのシートとは別の階層に付ける(上のコメントと同じ理由)。
        .background {
            Color.clear.homeBookExportSheet($exportRequest, allowsCoverSelection: allowsEditing)
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
                coverRevision: collectionStore.coverRevision(for: item),
                onImageRetained: { image in
                    cellImageBudget.note(retaining: image, minimumCellCount: minimumCellCount)
                }
            )
            // 選択中の枠と印(CollectionTileと同じ形・同じ理由。輪郭の扱いは
            // SelectionCheckmarkBadgeの型コメント参照)。**カバーにだけ掛ける** ――
            // 下の文字まで枠で囲むと、選んだ範囲がカバー1枚に見えなくなる。
            .overlay {
                SelectionEmphasisBorder(shape: shape)
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
                    .font(.system(size: appearance.collectionCoverCaptionFontSize))
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
                isGridFocused = true
                state.toggleItemSelection(item.id)
            } else {
                open(item)
            }
        }
        // Finder などへ運ぶと本がコピーされる(2026-09-23、利用者の指示。HomeBookTransfer.swift の冒頭)。
        .homeBookDragSource { beginDrag(from: item) }
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
                        BookOpenRequest(url, sequence: BookSequence.collection(items, opening: item)),
                        to: destination, from: appState,
                        launchCoordinator: launchCoordinator, openWindow: openWindow
                    )
                }
            )
            .disabled(!isSingle)
            openWithMenu(for: item, isEnabled: isSingle)
            Divider()
            // 「コピー」(2026-09-23、利用者の指示)。選んだ本をまとめてコピーできる(Finder へ貼るとコピーになる)。
            // 編集モードを条件にしない(棚をいじる操作ではない)。シークレットウインドウでも使える(何も記録しない)。
            Button("Copy") { copy(targets) }
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
            // 環境設定「ファイルブラウザを有効にする」がOFFの間は出さない(RevealInFileBrowserAction.isFeatureEnabled)。
            if revealInFileBrowser.isFeatureEnabled {
                Button("Show in File Browser") {
                    guard let url = collectionStore.resolvedExistingURL(for: item) else {
                        missingBook = MissingBook(
                            id: item.id, title: item.title,
                            reason: collectionStore.location(for: item)
                        )
                        return
                    }
                    revealInFileBrowser(url)
                }
                .disabled(!isSingle)
            }

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
            // 「本の書き出し」(2026-09-23、ファイルブラウザ・ビューアの右クリックと同じ)。書き出し自体は何も記録しないので、
            // シークレットウインドウでも使える(カバーの選択だけ出さない)。
            BookExportMenu(isEnabled: isSingle && exportRequest == nil) { format in startExport(item.id, format: format) }
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

    // MARK: - このアプリケーションで開く

    /// 「このアプリケーションで開く」(2026-09-14、ユーザー要望。ファイルブラウザの右クリックと同じ中身)。
    ///
    /// **候補は名前だけで引く**(`.contextMenu` の中身はセルの本体評価の一部として組まれるので、ここでディスクに触らない。
    /// BookOpenContextMenuItems の型コメント)。本は書庫・PDF・EPUB のファイルか、画像のフォルダのどちらかなので、
    /// 記録してあるパスの拡張子で見分ける。ブックマークの解決は選ばれてから。
    /// 複数選んでいる間は押せない(ほかの 1 冊向けの項目と同じ)。`.contextMenu` の中の `Menu` には `.disabled` が
    /// 効かないので、押せない `Button` で描く(FileBrowserDisabledSubmenu の型コメント)。
    @ViewBuilder
    private func openWithMenu(for item: CollectionItem, isEnabled: Bool) -> some View {
        let title = String(localized: "Open With", language: locale)
        if isEnabled {
            let path = item.bookID
            let name = (path as NSString).lastPathComponent
            let isFile = isArchiveFile(name) || isPDFFile(name) || isEpubFile(name)
            let applications = OpenWithApplications.shared.applications(
                for: URL(fileURLWithPath: path), isDirectory: !isFile, isPackage: false
            )
            let itemID = item.id
            Menu(title) {
                FileBrowserMenuNodeItems(nodes: OpenWithApplications.shared.menuNodes(
                    for: applications, locale: locale,
                    open: { application in openItem(itemID, withApplicationAt: application) },
                    chooseOther: {
                        guard let application = OpenWithApplications.chooseApplication(locale: locale) else { return }
                        openItem(itemID, withApplicationAt: application)
                    }
                ))
            }
        } else {
            FileBrowserDisabledSubmenu(title: title)
        }
    }

    /// 選んだアプリで本を開く。コレクションが持つのはセキュリティスコープ付きのブックマークなので、スコープを開けたまま
    /// 渡し、アプリが受け取り終えてから閉じる(開けていないと、サンドボックスが相手のアプリへ読み取りの許可を渡せない)。
    /// 失敗はアラートで知らせる(HomeBookOpenWith.open。スマートライブラリの右クリックと共有)。
    private func openItem(_ itemID: UUID, withApplicationAt application: URL) {
        guard let item = collectionStore.item(withID: itemID) else { return }
        guard let url = collectionStore.resolvedExistingURL(for: item) else {
            missingBook = MissingBook(id: item.id, title: item.title, reason: collectionStore.location(for: item))
            return
        }
        HomeBookOpenWith.open(url, withApplicationAt: application, scoped: true, locale: locale)
    }

    /// 「本の書き出し」▸ 形式。保存先の決め方はファイルブラウザ・ビューアの右クリックと同じ(FileBrowserBookSheet.Export.make)。
    /// 本はブックマークから解決した URL で渡す(書き出しがスコープを開けて読む。BookExportViewModel.exportOne)。
    private func startExport(_ itemID: UUID, format: BookExportFormat) {
        guard exportRequest == nil, let item = collectionStore.item(withID: itemID) else { return }
        guard let url = collectionStore.resolvedExistingURL(for: item) else {
            missingBook = MissingBook(id: item.id, title: item.title, reason: collectionStore.location(for: item))
            return
        }
        let name = url.lastPathComponent
        guard let export = FileBrowserBookSheet.Export.make(
            url: url, bookID: item.bookID, isDirectory: !(isArchiveFile(name) || isPDFFile(name) || isEpubFile(name)),
            format: format, preferences: preferences, bookmarkStore: bookmarkStore, layoutStore: layoutStore,
            metadataStore: metadataStore, collectionStore: collectionStore
        ) else { return }
        exportRequest = HomeBookExportRequest(export: export)
    }

    // MARK: - コピー・ドラッグ(2026-09-23)

    /// 「編集」▸「コピー」(⌘C)。選んでいる本(いま出ているぶん)。選んでいなければ鳴らす。
    private func copySelectedItems() {
        let targets = items.filter { state.selectedItemIDs.contains($0.id) }
        guard !targets.isEmpty else {
            NSSound.beep()
            return
        }
        copy(targets)
    }

    /// 本の実体をペーストボードへ(HomeBookPasteboard)。ブックマークの解決と在るかの確かめは FileIO の上で(何冊もあり、
    /// ボリュームへの問い合わせになる。CollectionStore.existingURL のコメント)。見つかった本だけを載せ、1冊も無ければ
    /// 「本が見つかりません」。
    private func copy(_ targets: [CollectionItem]) {
        let requests = targets.map { (id: $0.id, bookmark: $0.bookmarkData) }
        Task { @MainActor in
            let resolved = await FileIO.perform {
                requests.map { (id: $0.id, url: CollectionStore.existingURL(fromBookmark: $0.bookmark)) }
            }
            let urls = resolved.compactMap(\.url)
            guard !urls.isEmpty else {
                if let item = requests.first.flatMap({ collectionStore.item(withID: $0.id) }) {
                    missingBook = MissingBook(id: item.id, title: item.title, reason: collectionStore.location(for: item))
                }
                return
            }
            // コレクションの本の許可はブックマークが持つので、書くあいだスコープを開けておく。
            HomeBookPasteboard.copy(urls, scopedURLs: urls, fileBrowser: appState.fileBrowser)
        }
    }

    /// カバーを引きずり始めた。右クリックと同じく、選んでいる本を掴んだなら選んだ本の全部を運ぶ(contextTargets)。
    ///
    /// **ここではファイルに触らない**(2026-09-23 の 3 回目の監査の中 8)。ドラッグは出来事の中で始めるので待てず、以前はここで
    /// 選んだ全冊のブックマークの解決と実在確認をメインで行い、1 冊も見つからないとマウスが動くたびにやり直した(寝ている NAS の
    /// 本を選んで引きずると固まった)。いまは実在確認(`CollectionStore.scheduleExistenceRefresh`。メインの外)が控えた場所を使う:
    /// 見つかっている本はその URL(ブックマークを解いた URL なので、スコープを開ける)、まだ確かめていない本は記録したパス、
    /// 見つからない・繋がっていないボリュームの本は運ばない。
    private func beginDrag(from item: CollectionItem) {
        guard !HomeBookDragSource.isDragging else { return }
        let urls = contextTargets(for: item).compactMap { target -> URL? in
            guard let location = collectionStore.cachedLocation(for: target) else { return URL(fileURLWithPath: target.bookID) }
            return location.url
        }
        HomeBookDragSource.begin(
            books: urls.map { url in
                let name = url.lastPathComponent
                return (url, !(isArchiveFile(name) || isPDFFile(name) || isEpubFile(name)))
            },
            scopedURLs: urls, appState: appState
        )
    }

    /// カバーの下に出す文字。設定が「表示しない」(既定)ならnilで、行そのものを出さない。
    private func caption(for item: CollectionItem) -> String? {
        switch appearance.collectionCoverCaptionStyle {
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
        // 見えている並び(検索・並べ替えの後)を渡す ―― 「次の本へ」「前の本へ」がこの並びをたどる(BookSequence)。
        appState.open(request: BookOpenRequest(url, sequence: BookSequence.collection(items, opening: item)))
    }
}

/// 押している間だけ淡く描く、地を持たないボタンのスタイル(戻るボタン用。backButtonのコメント参照)。
private struct PressDimmingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
