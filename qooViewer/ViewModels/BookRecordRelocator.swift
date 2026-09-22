import Foundation
import SwiftData

/// アプリ自身が移した・名前を変えた本の保存データを付け替える窓口(アプリで 1 つ。AppStores)。段取りと決まりは `BookRelocationPlan`。
///
/// `FileSystemChange` を受けるたびに、(1) どれかのストアに行のある `bookID` を集め、(2) **メインアクターの外で**移った先を求めて
/// (別ボリュームなら手がかりも取り直して)、(3) 5 つのストアと読書位置(`BookReadingState`)へ当てはめる。知らせは起きた順に
/// 1 つずつ片付ける(A → B、B → C と続いたとき、先の付け替えが済んでから次を当てる)。
@MainActor
final class BookRecordRelocator {
    private weak var favoritesStore: FavoritesStore?
    private weak var bookmarkStore: BookmarkStore?
    private weak var layoutStore: LayoutStore?
    private weak var metadataStore: BookMetadataStore?
    private weak var collectionStore: CollectionStore?
    /// ライブラリ機能が OFF の間に表紙の指定が変わった本の控え(中身はパス)を持っている。本が移ったら控えも付け替える(`apply`)。
    private weak var coverExtractor: CollectionCoverExtractor?
    private let modelContext: ModelContext
    private var tail: Task<Void, Never>?

    init(
        favoritesStore: FavoritesStore?, bookmarkStore: BookmarkStore?, layoutStore: LayoutStore?,
        metadataStore: BookMetadataStore?, collectionStore: CollectionStore?, modelContext: ModelContext,
        coverExtractor: CollectionCoverExtractor? = nil
    ) {
        self.coverExtractor = coverExtractor
        self.favoritesStore = favoritesStore
        self.bookmarkStore = bookmarkStore
        self.layoutStore = layoutStore
        self.metadataStore = metadataStore
        self.collectionStore = collectionStore
        self.modelContext = modelContext
    }

    /// 付け替える。返す Task は付け替えが済むまで(呼び出し側はその後で実体確認をやり直す。テストも待つ)。
    @discardableResult
    func apply(_ change: FileSystemChange) -> Task<Void, Never> {
        let previous = tail
        // 付け替えが済むまで自分を持っておく(途中で手放されると、知らせを受けたのに付け替えが消える)。
        let task = Task { @MainActor [self] in
            await previous?.value
            // 「置き換える」で置き換えられた本の保存データは、先に消す(2026-09-22 の監査)。残すと、置き換えた新しい本がそのパスで
            // 古い本の読書位置・ブックマーク・メタデータを引き継ぎ、移してきた本の保存データは「移った先に行がある」で付け替わらず
            // 実在しないパスに取り残された。置き換えられた本はゴミ箱へ行っている(ゴミ箱の中の本は「無い」扱い ――
            // BookLocationResolver.isInTrash)ので、その保存データを持ち続ける先が無い。
            self.eraseReplaced(change.replaced)
            guard !change.relocations.isEmpty else { return }
            let known = self.knownBookIDs()
            guard !known.isEmpty else { return }
            let plan = await Task.detached(priority: .utility) {
                BookRelocationPlan.make(knownBookIDs: known, change: change)
            }.value
            guard !plan.isEmpty else { return }
            self.favoritesStore?.applyBookRelocation(plan)
            self.bookmarkStore?.applyBookRelocation(plan)
            self.layoutStore?.applyBookRelocation(plan)
            self.metadataStore?.applyBookRelocation(plan)
            self.collectionStore?.applyBookRelocation(plan)
            self.relocateReadingStates(plan)
            // 保存データではないが、パスで本を覚えているもの(2026-09-21 の監査 docs/plans/feature-toggle-audit.md の D2)。
            self.coverExtractor?.relocateBooksChangedWhileDisabled(plan.bookIDs)
        }
        tail = task
        return task
    }

    private func eraseReplaced(_ replaced: [URL]) {
        guard !replaced.isEmpty, let favoritesStore, let collectionStore, let bookmarkStore, let layoutStore, let metadataStore
        else { return }
        let paths = replaced.map { MountTable.normalized($0.path) }
        let targets = knownBookIDs().filter { bookID in
            let path = MountTable.normalized(bookID)
            return paths.contains { MountTable.path(path, isAtOrUnder: $0) }
        }
        guard !targets.isEmpty else { return }
        BookSavedDataEraser(
            favoritesStore: favoritesStore, collectionStore: collectionStore, bookmarkStore: bookmarkStore,
            layoutStore: layoutStore, metadataStore: metadataStore, modelContext: modelContext
        ).deleteAllData(forBookIDs: targets.sorted())
    }

    private func knownBookIDs() -> Set<String> {
        var ids = Set<String>()
        ids.formUnion(favoritesStore?.knownBookIDs ?? [])
        ids.formUnion(bookmarkStore?.knownBookIDs ?? [])
        ids.formUnion(layoutStore?.knownBookIDs ?? [])
        ids.formUnion(metadataStore?.knownBookIDs ?? [])
        ids.formUnion(collectionStore?.knownBookIDs ?? [])
        ids.formUnion(allReadingStates().map(\.bookID))
        return ids
    }

    /// 読書位置はストアを持たない(ViewerViewModel が本を開くときに全件から引く)ので、ここで直に付け替える。
    /// 絞り込み無しで取ってから Swift の側で仕分ける(`#Predicate` の絞り込みが 0 件を返す不具合を避ける。ViewerViewModel のコメント)。
    private func allReadingStates() -> [BookReadingState] {
        (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
    }

    private func relocateReadingStates(_ plan: BookRelocationPlan) {
        Self.relocateReadingStates(plan.bookIDs, in: modelContext)
    }

    /// 読書位置を `bookIDs`(古い → 新しい)のとおり付け替える。新しいパスに読書位置が既にあれば付け替えない。
    /// 本を開いたときの付け替え(AppState。ほかの 5 つのストアの `reconcileBookIDIfMoved` が見つけた元のパスから)も使う ――
    /// 以前は開いたときに読書位置だけ付け替えず、アプリの外で名前を変えた本は 1 ページ目から始まり、古い読書位置が残り続けた
    /// (2026-09-22、利用者の報告)。
    static func relocateReadingStates(_ bookIDs: [String: String], in modelContext: ModelContext) {
        guard !bookIDs.isEmpty else { return }
        let states = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        let occupied = Set(states.map(\.bookID))
        var changed = false
        for state in states {
            guard let new = bookIDs[state.bookID], !occupied.contains(new) else { continue }
            // フォルダの本はページの鍵も付け替える(PageKeyRelocation の型コメント)。
            if let key = state.lastPageKey.flatMap({ PageKeyRelocation.relocated($0, fromBookID: state.bookID, toBookID: new) }) {
                state.lastPageKey = key
            }
            state.bookID = new
            changed = true
        }
        if changed { try? modelContext.save() }
    }
}
