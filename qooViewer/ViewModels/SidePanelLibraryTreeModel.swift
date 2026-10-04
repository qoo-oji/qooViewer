import Combine
import Foundation

/// サイドパネルのライブラリのツリー(SidePanelLibraryTreeSection)が描く行の、**値の写し**の持ち主。ツリー 1 つにつき 1 つ
/// (ツリーの `@StateObject`)。
///
/// ■ なぜ写しを挟むのか(2026-10-04 の監査 §2-4)
/// 以前はツリーが `@EnvironmentObject CollectionStore` を持ち、body の中で `items(in:sort:)` を呼んでいた。CollectionStore は
/// 表紙の抽出 1 枚ごと・存在確認のたびに publish するので、そのたびにツリーが組み直され、開いているコレクションの全冊を
/// 並べ替えていた(`items(in:sort:)` は控えを通らない)。CLAUDE.md の「ビューア・サイドパネルから CollectionStore を observe しない」
/// にも当たる。ツリーは冊ごとの存在(淡く描く)と並びが要るので、名前だけの写し(HomeMenuDirectoryStore)では置き換えられない。
///
/// そこで、ここがストアを**購読せずに**持ち(`CollectionAddingContext` から受け取る弱い参照)、変化の知らせ(`revision`・
/// `libraries`・存在・日付・メタデータ)を受けたら 1 ランループ待って**いま見えている行だけ**を値で作り直し、前と違うときだけ
/// publish する。並べ替えは `CollectionStore.leadingItems(in:sort:limit:)` の控え(並びを変えうる変化が無ければ並べ直さない)を通す。
///
/// ■ 名前(監査 SP-9)
/// 本の行の名前は、ホームのカバーの下の文字と同じ設定(外観「カバーの下に出す文字」)に従う ―― タイトルならタイトル、
/// ファイル名ならファイル名。設定が「表示しない」(既定)のときは並び順に合わせる(「タイトル」順ならタイトル、ほかはファイル名)。
/// 以前は常にファイル名で、「タイトル」順にすると並びと名前がばらばらに見えた。
@MainActor
final class SidePanelLibraryTreeModel: ObservableObject {
    /// ツリーを平らにした 1 行(値)。
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case library(isExpanded: Bool, count: Int)
            case collection(isExpanded: Bool, count: Int)
            /// `exists` はキャッシュ済みの存在確認(`CollectionStore.cachedFileExists`)。ファイルには触らない。
            case book(bookID: String, collectionID: UUID, exists: Bool)
            /// 開いたライブラリ・コレクションが空。
            case empty
        }

        let id: String
        /// ライブラリ・コレクション・本(CollectionItem)の id。空の行は親の id。
        let objectID: UUID
        let depth: Int
        let title: String
        let kind: Kind
    }

    /// 行を決める、ツリーの側の値。
    struct Inputs: Equatable {
        var expandedLibraryIDs: Set<UUID>
        var expandedCollectionIDs: Set<UUID>
        var collectionSort: FavoritesSortOption
        var itemSort: FavoritesSortOption
        var captionStyle: CollectionCoverCaptionStyle
        var language: Locale
        /// 命名規則の中身の印(`MetadataRulesStore.rules.contentHash`)。規則が変わればタイトルも変わるので、ツリーが読んで渡す
        /// (BookTitleResolver は publish しない)。
        var rulesHash: String
    }

    @Published private(set) var rows: [Row] = []

    private weak var store: CollectionStore?
    private var inputs: Inputs?
    private var subscriptions: [AnyCancellable] = []
    private var isRebuildScheduled = false
    /// 行を作り直した回数(**テストのための口**。publish の回数とは別に、作り直しが走ったかを見る)。
    private(set) var rebuildCount = 0

    init() {}

    /// ストアにつなぐ(同じストアなら何もしない)。行はすぐに作る ―― 最初の描画で空のツリーを 1 回挟まない。
    func attach(to store: CollectionStore?, inputs: Inputs) {
        self.inputs = inputs
        guard store !== self.store else {
            rebuild()
            return
        }
        self.store = store
        subscriptions.removeAll()
        if let store {
            // どれも「変わる前」に飛ぶ(@Published)ので、1 ランループ待ってから読む。
            store.$revision.sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRebuild() } }
                .store(in: &subscriptions)
            store.$libraries.sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRebuild() } }
                .store(in: &subscriptions)
            store.$locationByItemID.sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRebuild() } }
                .store(in: &subscriptions)
            store.$fileDatesByItemID.sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRebuild() } }
                .store(in: &subscriptions)
            // メタデータが変わるとタイトル(名前・「タイトル」順)が変わる。BookTitleResolver は publish しないので知らせで起きる
            // (どのストアの知らせかは問わない ―― 作り直して前と同じなら publish しないので、余分に起きても見た目は変わらない)。
            NotificationCenter.default.publisher(for: .bookMetadataDidChange)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRebuild() } }
                .store(in: &subscriptions)
        }
        rebuild()
    }

    /// ツリーの側の値が変わった(開閉・並び順・設定)。開閉はクリックへの返事なので、待たずに作り直す。
    func update(_ inputs: Inputs) {
        guard inputs != self.inputs else { return }
        self.inputs = inputs
        rebuild()
    }

    private func scheduleRebuild() {
        guard !isRebuildScheduled else { return }
        isRebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRebuildScheduled = false
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        rebuildCount += 1
        let next: [Row]
        if let store, let inputs {
            next = Self.makeRows(store: store, inputs: inputs)
        } else {
            next = []
        }
        if next != rows { rows = next }
    }

    /// 本の行の名前にタイトル(BookTitleResolver)を使うか(型コメントの「名前」)。
    nonisolated static func showsMetadataTitle(
        captionStyle: CollectionCoverCaptionStyle, itemSort: FavoritesSortOption
    ) -> Bool {
        switch captionStyle {
        case .title: return true
        case .fileName: return false
        case .none:
            switch itemSort {
            case .titleAscending, .titleDescending: return true
            default: return false
            }
        }
    }

    static func makeRows(store: CollectionStore, inputs: Inputs) -> [Row] {
        let showsTitle = showsMetadataTitle(captionStyle: inputs.captionStyle, itemSort: inputs.itemSort)
        var rows: [Row] = []
        for library in store.libraries {
            let isLibraryExpanded = inputs.expandedLibraryIDs.contains(library.id)
            rows.append(Row(
                id: "library:\(library.id.uuidString)", objectID: library.id, depth: 0,
                title: library.displayName(language: inputs.language),
                kind: .library(isExpanded: isLibraryExpanded, count: library.collections.count)
            ))
            guard isLibraryExpanded else { continue }
            let collections = store.collections(in: library, sort: inputs.collectionSort)
            if collections.isEmpty {
                rows.append(Row(id: "empty:\(library.id.uuidString)", objectID: library.id, depth: 1, title: "", kind: .empty))
            }
            for collection in collections {
                let isCollectionExpanded = inputs.expandedCollectionIDs.contains(collection.id)
                rows.append(Row(
                    id: "collection:\(collection.id.uuidString)", objectID: collection.id, depth: 1, title: collection.name,
                    kind: .collection(isExpanded: isCollectionExpanded, count: collection.items.count)
                ))
                guard isCollectionExpanded else { continue }
                // 控えを通す並べ替え(型コメント)。答えは `items(in:sort:)` と同じ。
                let items = store.leadingItems(in: collection, sort: inputs.itemSort, limit: .max)
                if items.isEmpty {
                    rows.append(Row(
                        id: "empty:\(collection.id.uuidString)", objectID: collection.id, depth: 2, title: "", kind: .empty
                    ))
                }
                for item in items {
                    rows.append(Row(
                        id: "book:\(item.id.uuidString)", objectID: item.id, depth: 2,
                        title: showsTitle ? store.titleResolver.title(forBookID: item.bookID) : item.title,
                        kind: .book(bookID: item.bookID, collectionID: collection.id, exists: store.cachedFileExists(for: item))
                    ))
                }
            }
        }
        return rows
    }
}
