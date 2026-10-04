import QooMetaKit
import SwiftUI

/// サイドパネルのブックマークモードの下段: ライブラリ → コレクション → 本のツリー
/// (ユーザー要望 2026-09-13)。
///
/// ■ 何ができるか
/// - 最初はライブラリだけが並ぶ。行をクリックすると、その中のコレクション、さらにその中の本へと
///   展開する(開閉は「ダブルクリックで開く」の設定に関わらず常にシングルクリック ―― お気に入り
///   ツリーのフォルダ行と同じ判断。SidePanelFavoriteRow.folderRowのコメント)
/// - 本をクリック(設定によってはダブルクリック)で開く
/// - 本の右クリックは、履歴モードの行と同じ「開く / 新規◯◯で開く / Finderで表示」
///   (ユーザー指定: 既存のモードの動作に合わせる)。**ライブラリ・コレクションの右クリックは
///   まだ無い**(ユーザー指定: ひとまず非サポート)。項目の無いcontextMenuは付けない
///
/// ■ 並び順はウェルカム画面と同じ
/// 同じウインドウのウェルカム画面(WelcomeLibraryState)の並び順をそのまま使う。棚を見る場所が
/// 2つあって並びが違うと、同じ本を探すのに2通りの順番を覚えることになる。
///
/// ■ 行はツリーを平らにした1本の配列で並べる
/// SwiftUIの`some View`は自分自身を再帰で呼べないので、お気に入りツリーは行ごとのView構造体を
/// 再帰させている。こちらは階層が2段で固定なので、展開状態から「いま見えている行」の配列を
/// 作って`LazyVStack`へ流す ―― 数千冊のコレクションを開いても、組み立てるのは見えている行だけ。
///
/// ■ 行は値の写し(SidePanelLibraryTreeModel)から描く
/// CollectionStore は購読しない(CLAUDE.md。モデルの型コメント)。開く・Finder で表示などはそのとき行をストアから引き直す。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// 文字とアイコンの行なので`.panelOutlinedContent()`、今開いている本の行の強調は
/// フォルダブラウザの行と同じ`.panelOutlinedAccent(in:)`。
struct SidePanelLibraryTreeSection: View {
    @EnvironmentObject private var preferences: AppPreferences
    /// カバーの下に出す文字の設定(本の行の名前。SidePanelLibraryTreeModel の型コメント「名前」、監査 SP-9)。
    @EnvironmentObject private var appearance: AppearanceSettings
    /// 規則の中身の印だけを読む(タイトルの作り直しの契機。SidePanelLibraryTreeModel.Inputs.rulesHash)。
    @Environment(MetadataRulesStore.self) private var rulesStore
    /// CollectionStore は**購読せずに**持つ(`CollectionAddingContext` の弱い参照。行は `model` の値の写しから描く ――
    /// 2026-10-04 の監査 §2-4。以前は `@EnvironmentObject` で持ち、表紙の抽出のたびに開いているコレクションの全冊を並べ替えていた)。
    @Environment(\.collectionAdding) private var collectionAdding
    @StateObject private var model = SidePanelLibraryTreeModel()
    /// 確かめを待つ間に別の本が頼まれたかを見る(開く意図 `AppState.OpenIntent`。2026-10-04 の監査 SP-10・レビューの R6-1)。
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.revealInFileBrowser) private var revealInFileBrowser
    /// 開く直前の確かめ(ブックマークの解決・存在確認)をメインの外で行う(CollectionItemOpenTracker。2026-09-27、
    /// 表示の切り替えの監査の 11 ―― 以前はここでメインのまま `.userOpen` で解決し、応答しない共有の本だと約 30 秒固まった)。
    @State private var openTracker = CollectionItemOpenTracker()

    @Binding var expandedLibraryIDs: Set<UUID>
    @Binding var expandedCollectionIDs: Set<UUID>
    /// ウェルカム画面の並び順(コレクション・本)。
    let collectionSort: FavoritesSortOption
    let itemSort: FavoritesSortOption
    /// 今開いている本(MangaBook.id = パス)。その本の行を強調する。
    let currentBookPath: String?
    /// 本を開く。要求にはそのコレクションの本の並び(`BookSequence`)が載る ―― 「次の本へ」「前の本へ」がコレクションの
    /// 並びをたどる(2026-09-22、利用者の指示)。
    /// 待ち始めたときの開く意図を添える(項目のブックマークの解決を待ってから開く。AppState.OpenIntent、2026-10-04 のレビューの R6-1)。
    var onOpen: (BookOpenRequest, AppState.OpenIntent?) -> Void
    var onOpenInNewWindow: (BookOpenRequest, BookOpenDestination) -> Void

    private typealias Row = SidePanelLibraryTreeModel.Row

    private var collectionStore: CollectionStore? { collectionAdding.collectionStore }

    private var modelInputs: SidePanelLibraryTreeModel.Inputs {
        SidePanelLibraryTreeModel.Inputs(
            expandedLibraryIDs: expandedLibraryIDs, expandedCollectionIDs: expandedCollectionIDs,
            collectionSort: collectionSort, itemSort: itemSort,
            captionStyle: appearance.collectionCoverCaptionStyle, language: locale,
            rulesHash: rulesStore.rules.contentHash
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // 他の段(ブックマーク・お気に入り)と同じ位置・同じ書式の見出し。
            Text("Libraries")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .panelOutlinedContent()
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                }
            }
            // folderSection/BookContentsSectionViewの同名の.focusable(false)と同じ理由。
            .focusable(false)
        }
        .onAppear { model.attach(to: collectionStore, inputs: modelInputs) }
        .onChange(of: modelInputs) { _, inputs in model.update(inputs) }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row.kind {
        case .library(let isExpanded, let count):
            disclosureRow(
                id: row.objectID, depth: row.depth, isExpanded: isExpanded, expanded: $expandedLibraryIDs,
                icon: "books.vertical", title: row.title, count: count
            )
        case .collection(let isExpanded, let count):
            disclosureRow(
                id: row.objectID, depth: row.depth, isExpanded: isExpanded, expanded: $expandedCollectionIDs,
                icon: "rectangle.stack", title: row.title, count: count
            )
        case .book(let bookID, _, let exists):
            bookRow(row, bookID: bookID, exists: exists)
        case .empty:
            // 親の深さに合わせて字下げする(ライブラリの下なら1段、コレクションの下なら2段)。
            Text("(Empty)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
                .padding(.leading, Self.leadingInset(depth: row.depth) + Self.chevronWidth + 6)
                .padding(.vertical, 4)
        }
    }

    private static let chevronWidth: CGFloat = 10
    private static func leadingInset(depth: Int) -> CGFloat { 8 + CGFloat(depth) * 14 }

    /// 開閉できる行(ライブラリ・コレクション)。
    private func disclosureRow(
        id: UUID, depth: Int, isExpanded: Bool, expanded: Binding<Set<UUID>>, icon: String, title: String, count: Int
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.chevronWidth)
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .panelOutlinedContent()
        .padding(.leading, Self.leadingInset(depth: depth))
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(title)
        .onTapGesture {
            if isExpanded {
                expanded.wrappedValue.remove(id)
            } else {
                expanded.wrappedValue.insert(id)
            }
        }
    }

    private func bookRow(_ row: Row, bookID: String, exists: Bool) -> some View {
        let isCurrent = bookID == currentBookPath
        let itemID = row.objectID
        return HStack(spacing: 6) {
            // 開閉の三角ぶんの幅を空けて、同じ深さの行と名前の開始位置を揃える。
            Color.clear.frame(width: Self.chevronWidth, height: 1)
            Image(systemName: Self.iconName(forBookID: bookID))
                .frame(width: 16)
                .selectionEmphasisForeground(isCurrent, otherwise: .secondary)
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // 開く前の確かめが長引いている本(眠っている共有など)。以前はツリーに何も出ず、押しても何も起きないように見えた
            // (2026-10-04 の監査 SP-10。ホームのコレクションのカバーと同じ回転表示。出すのは CollectionItemOpenTracker が
            // 250ms 待ってから)。小さな部品で地を持たないが、輪郭は下の panelOutlinedContent が文字と一緒に付ける。
            if openTracker.resolvingItemID == itemID {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .panelOutlinedContent()
        .padding(.leading, Self.leadingInset(depth: row.depth))
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        // 実体が見つからない本は、ウェルカム画面のカバーと同じく淡く描く(開こうとすると鳴るだけ)。
        .opacity(exists ? 1 : 0.45)
        .contentShape(Rectangle())
        .background { if isCurrent { SelectionEmphasisHighlight(shape: Rectangle()) } }
        .panelOutlinedAccent(in: Rectangle(), isEnabled: isCurrent)
        .help(bookID)
        .onTapGesture(count: preferences.sidePanelUsesDoubleClick ? 2 : 1) { open(itemID) }
        .sidePanelContextHighlight(rowID: "libraryTreeBook:\(itemID.uuidString)")
        .contextMenu {
            // 履歴モードの行と同じ並び(ユーザー指定)。ブックマークの解決は選ばれた時点で行う
            // (行を描くたびに解決すると、一覧全体でディスクを触ることになる)。
            BookOpenContextMenuItems(
                onOpen: { open(itemID) },
                onOpenIn: { destination in
                    guard let item = collectionStore?.item(withID: itemID) else { return NSSound.beep() }
                    let makeRequest = requestMaker(opening: item)
                    withResolvedURL(item) { url in onOpenInNewWindow(makeRequest(url), destination) }
                }
            )
            Divider()
            Button("Show in Finder") {
                guard let item = collectionStore?.item(withID: itemID) else { return NSSound.beep() }
                withResolvedURL(item) { url in FinderReveal.reveal(url) }
            }
            // 環境設定「ファイルブラウザを有効にする」がOFFの間は出さない(RevealInFileBrowserAction.isFeatureEnabled)。
            if revealInFileBrowser.isFeatureEnabled {
                Button("Show in File Browser") {
                    guard let item = collectionStore?.item(withID: itemID) else { return NSSound.beep() }
                    withResolvedURL(item) { url in
                        // 確かめを待つ間に機能が OFF になっていたら何もしない(await の後は確かめ直す)。
                        guard revealInFileBrowser.isFeatureEnabled else { return }
                        revealInFileBrowser(url)
                    }
                }
            }
        }
    }

    /// 行の本を開く。行は値の写しなので、押した時点の行(モデル)をストアから引き直す ―― 写しの後に外された本は鳴らすだけ。
    private func open(_ itemID: UUID) {
        guard let item = collectionStore?.item(withID: itemID) else { return NSSound.beep() }
        let makeRequest = requestMaker(opening: item)
        // 確かめを待つ間(最長 45 秒)にこの窓で別の本を頼んでいたら、後から置き換えない(2026-10-04 の監査 SP-10。待ち始めるここで
        // 開く意図を進める ―― 後から頼んだ方が勝つ。AppState.OpenIntent、レビューの R6-1)。
        let appState = appState
        let intent = appState.beginOpenIntent()
        withResolvedURL(item, stillWanted: { [weak appState] in appState?.isStillWanted(intent) == true }) { url in
            onOpen(makeRequest(url), intent)
        }
    }

    /// そのコレクションの本の並び(ツリーに見えている並び。ホームのコレクションと同じ並べ替え)を載せた要求を作る。
    /// 並びは押した時点で写し取る(確かめを待った後にモデルを読まない ―― その間に消えていることがある)。
    private func requestMaker(opening item: CollectionItem) -> (URL) -> BookOpenRequest {
        let items = item.collection.flatMap { collection in
            collectionStore?.leadingItems(in: collection, sort: itemSort, limit: .max)
        } ?? []
        let sequence = BookSequence.collection(items, opening: item)
        return { url in BookOpenRequest(url, sequence: sequence) }
    }

    /// 開く直前にブックマークを解決する(メインの外で。`openTracker`)。見つからなければ警告音だけ鳴らす ―― 理由を書き分けた
    /// アラート(「本が見つかりません」)はウェルカム画面のコレクションの中が持っており、細い
    /// パネルの行からは淡く描いてあることで伝える。
    ///
    /// 待った後は、ライブラリ機能が ON のままか(このツリーはライブラリ機能の一部)と、`stillWanted` があればそれを確かめる
    /// (2026-10-04 の監査 SP-10)。
    private func withResolvedURL(
        _ item: CollectionItem, stillWanted: (@MainActor () -> Bool)? = nil,
        perform body: @escaping @MainActor (URL) -> Void
    ) {
        let preferences = preferences
        openTracker.resolve(
            CollectionItemOpenProbe.Material(item),
            stillWanted: { preferences.libraryFeatureEnabled && (stillWanted?() ?? true) },
            onNotFound: { _ in NSSound.beep() },
            body
        )
    }

    /// 本の行のアイコン。コレクションに入るのは書庫・PDF・EPUB・フォルダだけなので、
    /// 本のファイルと分からないものはフォルダとして描く(拡張子の有無では決めない ――
    /// 「Vol.1」のようなフォルダ名は拡張子を持っているように見える)。
    private static func iconName(forBookID bookID: String) -> String {
        let fileName = URL(fileURLWithPath: bookID, isDirectory: false).lastPathComponent
        if isArchiveFile(fileName) || isPDFFile(fileName) || isEpubFile(fileName) {
            return sidePanelFileIconName(fileName: fileName)
        }
        return "folder"
    }
}
