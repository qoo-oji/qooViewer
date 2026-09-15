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

    init(collectionStore: CollectionStore) {
        self.collectionStore = collectionStore
        directory = Self.makeDirectory(from: collectionStore)
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
                let next = Self.makeDirectory(from: collectionStore)
                guard next != self.directory else { return }
                MenuBarMenuGate.shared.run("HomeMenuDirectoryStore.directory") { [weak self] in
                    guard let self, self.directory != next else { return }
                    self.directory = next
                }
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
