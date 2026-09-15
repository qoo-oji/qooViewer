import Combine
import Foundation

/// メニューバーの「ホーム」メニューが読む、ライブラリとコレクションの名前の写し(HomeMenuDirectory)の持ち主。
/// アプリ全体で 1 つ(AppStores)。
///
/// `CollectionStore` そのものはメニューバーにつながない(AppStores.collectionStore のコメント)。代わりにここが
/// `CollectionStore` の変化を拾い、**名前・並び・所属が変わったときだけ** publish する。表紙の抽出や存在確認の
/// ように名前に関わらない変化では、写しが前と同じなので何も起きない。
///
/// 反映は `MenuBarMenuGate` を通す(メニューを開いている間は保留)。同じランループの中の変化はまとめて 1 回にする。
/// 写しを作るのはメインアクターの上で、コレクションの数に比例する(並べ替え 1 回ぶん)。
@MainActor
final class HomeMenuDirectoryStore: ObservableObject {
    @Published private(set) var directory = HomeMenuDirectory()

    private weak var collectionStore: CollectionStore?
    private var subscriptions: [AnyCancellable] = []
    private var isRefreshScheduled = false
    /// 最後に写しを作ったときの、並びと名前を決める材料(`Fingerprint`)。
    private var lastFingerprint: Fingerprint?
    /// 写しを作り直した回数(**テストのための口**。名前に関わらない変化で並べ替えないことを確かめる)。
    private(set) var rebuildCount = 0

    init(collectionStore: CollectionStore) {
        self.collectionStore = collectionStore
        directory = Self.makeDirectory(from: collectionStore)
        lastFingerprint = Fingerprint(collectionStore)
        // `revision` はライブラリ・コレクション・本のどれかを保存するたびに進む(CollectionStore.saveAndNotify)。
        // `libraries` は読み直し(reload)で差し替わる。どちらも「変わる前」に飛ぶので、1 ランループ待ってから読む。
        collectionStore.$revision
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRefresh() } }
            .store(in: &subscriptions)
        collectionStore.$libraries
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRefresh() } }
            .store(in: &subscriptions)
    }

    private func scheduleRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRefreshScheduled = false
                guard let collectionStore = self.collectionStore else { return }
                // **並べ替える前に、並びと名前を決める材料が変わったかを見る**(2026-09-15 の 4 回目の監査)。`revision` は表紙の抽出
                // 1 枚ごとにも進むので、以前はそのたびに全ライブラリのコレクションを `localizedStandardCompare` で並べ替えていた。
                let fingerprint = Fingerprint(collectionStore)
                guard fingerprint != self.lastFingerprint else { return }
                self.lastFingerprint = fingerprint
                self.rebuildCount += 1
                let next = Self.makeDirectory(from: collectionStore)
                // 今の値と同じでも保留へ渡す(メニューを開いている間に「変わる → 戻る」が起きたとき、保留した古い値が後で当たらないように。
                // 同じ鍵の保留は後のものが勝ち、当てる側でも同じなら何もしない)。
                MenuBarMenuGate.shared.run("HomeMenuDirectoryStore.directory") { [weak self] in
                    guard let self, self.directory != next else { return }
                    self.directory = next
                }
            }
        }
    }

    /// 写しの中身(名前・並び・所属)を決める材料だけを、並べ替えずに集めたもの。コレクションの並び順は名前と「常に先頭/末尾」で決まる。
    /// 関連の配列の並びは保存のたびに揺れうるので、コレクションは集合で持つ。
    private struct Fingerprint: Equatable {
        struct Library: Equatable {
            let id: UUID
            let name: String
            let usesDefaultName: Bool
            let pinnedFirst: UUID?
            let pinnedLast: UUID?
            let collections: Set<Collection>
        }

        struct Collection: Hashable {
            let id: UUID
            let name: String
        }

        let libraries: [Library]

        init(_ store: CollectionStore) {
            libraries = store.libraries.map { library in
                Library(
                    id: library.id, name: library.name, usesDefaultName: library.usesDefaultName,
                    pinnedFirst: library.pinnedFirstCollectionID, pinnedLast: library.pinnedLastCollectionID,
                    collections: Set(library.collections.map { Collection(id: $0.id, name: $0.name) })
                )
            }
        }
    }

    static func makeDirectory(from store: CollectionStore) -> HomeMenuDirectory {
        HomeMenuDirectory(libraries: store.libraries.map { library in
            HomeMenuDirectory.Library(
                id: library.id, name: library.name, usesDefaultName: library.usesDefaultName,
                collections: store.collections(in: library, sort: .nameAscending).map {
                    HomeMenuDirectory.Collection(id: $0.id, name: $0.name)
                }
            )
        })
    }
}
