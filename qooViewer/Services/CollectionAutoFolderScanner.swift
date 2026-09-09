import AppKit
import Combine
import Foundation

/// 自動登録フォルダ(`BookCollection.autoFolderPath`)を見に行って、まだ入っていない本を
/// コレクションへ足す(ユーザー要望 2026-09-09)。
///
/// ■ 監視する(2026-09-09に方針変更)
/// 最初は FSEvents を入れず、契機を人の操作(アプリのアクティブ化・画面の表示)だけにしていた。
/// 「見にきたときに走査すれば見え方は同じ」という判断だったが、**ユーザーの要望は「コピーした
/// 瞬間に増えてほしい」**だったので、`FolderChangeWatcher` で実際に監視する形へ変えた。
///
/// 人の操作を契機にする経路は**残してある**。FSEvents はネットワークボリューム(SMB/AFP)では
/// 飛ばず、アプリが止められている間の変更も取りこぼしうるため、監視は「見ている間の即時反映」、
/// 従来の契機は「取りこぼしの回収」という役割分担にする。
///
/// ■ 書き終わっていないファイルを登録しない
/// コピーの途中(まだ書き終わっていない書庫)をその瞬間に登録すると、カバーの抽出が `.failed` の
/// まま固定される(抽出をやり直す契機はカバーの上書きが変わったときだけ ――
/// CollectionCoverExtractor の型コメント参照)。
///
/// 当初は「更新時刻が10秒以内のものは見送る」という一律の待ちにしていたが、**これも撤回した**
/// ―― 即時反映を求められている以上、小さな本まで10秒待たせる理由が無い。代わりに
/// `CollectionAutoFolderScan.isSettled` で「書き込みが止まったか」を見る:
///   ・更新時刻が `quietInterval` より古い → もう書かれていない(同じボリューム内の移動など、
///     元の更新時刻を引き継いだファイルはここで即座に通る)
///   ・そうでなければ、`recheckDelay` を空けた2回の観測で大きさも更新時刻も変わっていない →
///     書き込みが止まった
/// どちらでもないものはその回は見送り、`recheckDelay` 後にもう一度見る。大きな書庫のコピーは
/// 「終わった直後」に入り、小さなファイルは1回の見直し(0.5秒)で入る。
///
/// ■ 棚の判定は増やさない
/// 「そのフォルダに並んでいる本」は ShelfFolderResolver.role(of:order:) の `.shelf(books:)`
/// そのもの ―― **直下だけ**で、ファイルの本と画像を直接持つフォルダが並び順どおりに入る。
/// 編集モード中にそのフォルダをドロップしたときに入る本と、1冊のずれもなく一致する
/// (CollectionDropClassifier も同じ判定を通っている)。
///
/// ■ アクセス権は FolderAccessStore に一本化する
/// フォルダを列挙してよいか(監視してよいか)は `FolderAccessStore.isPathCovered` にだけ訊く。
/// 覆われていなければ**黙って見送る**(設定の面が「アクセスを許可」を出す。
/// BookCollection.autoFolderPath のコメント参照)。
@MainActor
final class CollectionAutoFolderScanner: ObservableObject {
    private let collectionStore: CollectionStore
    private let coverExtractor: CollectionCoverExtractor
    private let folderAccess: FolderAccessStore
    private let preferences: AppPreferences

    private var isScanning = false
    private var needsAnotherScan = false
    /// まだ書き込みが止まっていないファイルの、直前の観測。次の走査で見比べる。
    private var observations: [URL: CollectionAutoFolderScan.Observation] = [:]
    /// 見送ったファイルを見直すために予約した走査(二重に積まない)。
    private var recheckTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var volumeObservers: [NSObjectProtocol] = []
    /// 監視役。**`init`の中では作れない** ―― あそこの`self`はまだ確定しておらず、並行に走る
    /// クロージャへ渡せない(Swift 6 ではエラー)。最初に`scheduleScan()`が呼ばれたときに作る。
    private var watcher: FolderChangeWatcher?
    /// `releaseResources()`を通ったか(**テストのための口**)。通ったあとは監視を作り直さない。
    private var didRelease = false

    init(
        collectionStore: CollectionStore,
        coverExtractor: CollectionCoverExtractor,
        folderAccess: FolderAccessStore,
        preferences: AppPreferences
    ) {
        self.collectionStore = collectionStore
        self.coverExtractor = coverExtractor
        self.folderAccess = folderAccess
        self.preferences = preferences

        // 取りこぼしの回収。CollectionStore が実体の存在確認をやり直すのと同じ契機
        // (あちらの init と同じ形)。画面側の契機(ウェルカム画面が出た・コレクションを開いた)は
        // scheduleScan() を直に呼ぶ。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification].map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleScan() }
            }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers {
            workspaceCenter.removeObserver(observer)
        }
    }

    /// このオブジェクトが張った購読と監視を外す(**テストのための口**。CollectionStore.
    /// releaseResources と同じ理由・同じ形)。
    func releaseResources() {
        didRelease = true
        recheckTask?.cancel()
        recheckTask = nil
        watcher?.tearDown()
        watcher = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers {
            workspaceCenter.removeObserver(observer)
        }
        volumeObservers = []
    }

    /// 自動登録フォルダを持つコレクションを全部見に行き、監視の対象も今の顔ぶれへ合わせる。
    /// 走査中に重ねて呼ばれたら、いま走っているぶんが終わってからもう一度だけ走る
    /// (CollectionStore.scheduleExistenceRefresh と同じ形)。
    func scheduleScan() {
        // 権限が無いフォルダはここで落とす(走査も監視も始めない)。
        let targets = collectionStore.autoFolderTargets()
            .filter { folderAccess.isPathCovered($0.folder) }
        ensureWatcher()
        watcher?.watch(Set(targets.map(\.folder.path)))

        guard !isScanning else {
            needsAnotherScan = true
            return
        }
        guard !targets.isEmpty else {
            observations = [:]
            return
        }

        isScanning = true
        let order = preferences.siblingBookOrder
        // [weak self]で受けたselfをawaitをまたぐ前に強参照へ変換する
        // (理由はRecentFilesStore.scheduleRefresh()の同種のコメント参照)。
        Task.detached(priority: .utility) { [weak self] in
            var found: [(id: UUID, books: [URL])] = []
            for target in targets {
                let books = CollectionAutoFolderScan.books(in: target.folder, order: order)
                if !books.isEmpty { found.append((id: target.id, books: books)) }
            }
            guard let self else { return }
            await self.finishScan(found)
        }
    }

    /// 監視役を用意する(watcherのコメント参照。`init`ではなくここで作る)。
    private func ensureWatcher() {
        guard watcher == nil, !didRelease else { return }
        watcher = FolderChangeWatcher { [weak self] in
            // `[weak self]`で入る`self`は**var**なので、そのまま中のTaskへ持ち込めない
            // (Swift 6: reference to captured var in concurrently-executing code)。
            // letへ束ね直してから渡す。
            guard let scanner = self else { return }
            Task { @MainActor in scanner.scheduleScan() }
        }
    }

    private func finishScan(_ found: [(id: UUID, books: [URL])]) {
        isScanning = false
        defer {
            if needsAnotherScan {
                needsAnotherScan = false
                scheduleScan()
            }
        }

        let now = Date()
        var stillWriting: [URL: CollectionAutoFolderScan.Observation] = [:]

        for entry in found {
            guard let collection = collectionStore.collection(withID: entry.id) else { continue }
            // 既に入っている本を先に落としてから調べる(unregisteredURLsのコメント参照)。
            let fresh = collectionStore.unregisteredURLs(entry.books, in: collection)
            guard !fresh.isEmpty else { continue }

            var settled: [URL] = []
            for url in fresh {
                guard let snapshot = CollectionAutoFolderScan.snapshot(of: url) else {
                    // 大きさも更新時刻も読めない = 判定の材料が無い。本かどうかは既に
                    // 決まっているので通す。
                    settled.append(url)
                    continue
                }
                let observation = CollectionAutoFolderScan.Observation(snapshot: snapshot, at: now)
                if CollectionAutoFolderScan.isSettled(observation, previous: observations[url]) {
                    settled.append(url)
                } else {
                    stillWriting[url] = observation
                }
            }
            guard !settled.isEmpty else { continue }
            let pending = settled.compactMap(CollectionStore.makePendingItem(for:))
            guard !pending.isEmpty else { continue }
            coverExtractor.enqueue(collectionStore.add(pending, to: collection))
        }

        observations = stillWriting
        if !stillWriting.isEmpty { scheduleRecheck() }
    }

    /// まだ書き込みが止まっていないファイルを、少し待ってからもう一度見る。
    private func scheduleRecheck() {
        guard recheckTask == nil else { return }
        recheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CollectionAutoFolderScan.recheckDelay))
            guard let self, !Task.isCancelled else { return }
            self.recheckTask = nil
            self.scheduleScan()
        }
    }
}

/// 自動登録フォルダから拾う本を決めるところ(走査の中核)。
///
/// アクターにもストアにも触らない純粋な判定なので、**メインアクターの外から直に呼べる**形で
/// 切り出してある(テストもこちらを直接叩く。ArchiveReading.swift冒頭のコメント参照)。
nonisolated enum CollectionAutoFolderScan {
    /// 最後の更新からこれだけ経っていれば、もう書かれていないとみなす。
    ///
    /// 同じボリューム内の移動やリネームは元の更新時刻を引き継ぐので、ここで即座に通る。
    /// 別ボリュームからのコピーは書いている間ずっと更新時刻が動くため、下の2回観測へ回る。
    static let quietInterval: TimeInterval = 2

    /// 見送ったファイルをもう一度見るまでの待ち。2回の観測の**最短の間隔**でもある
    /// (間隔を空けずに比べると、たまたま書き込みが一瞬止まっただけのものを通してしまう)。
    static let recheckDelay: TimeInterval = 0.5

    /// ある時点で見たファイルの様子。
    struct Snapshot: Equatable, Sendable {
        var size: Int64
        var modified: Date
    }

    /// 観測1回ぶん(いつ見て、どうだったか)。
    struct Observation: Equatable, Sendable {
        var snapshot: Snapshot
        var at: Date
    }

    /// `folder`の直下に並んでいる本。
    ///
    /// フォルダが棚でない(それ自体が1冊、空、中間フォルダだけ)ときは空を返す ――
    /// **指定そのものは弾かない**。いまは本が無くても、後からそこへ書庫が置かれれば棚になる。
    ///
    /// **書き込み中かどうかはここでは見ない**(isSettled の仕事)。ここが返すのは
    /// 「その棚に並んでいる本」だけで、ドロップの振り分けとまったく同じ結果になる。
    static func books(in folder: URL, order: SiblingBookOrder) -> [URL] {
        guard case .shelf(let books) = ShelfFolderResolver.role(of: folder, order: order) else {
            return []
        }
        return books
    }

    /// 大きさと更新時刻を1回読む。読めなければnil。
    ///
    /// フォルダの本(画像を直接持つフォルダ)では、フォルダ自身の更新時刻が中身の増減で動く。
    /// 大きさは意味を持たないが、更新時刻だけでも「まだ書かれている」は捕まえられる。
    static func snapshot(of url: URL) -> Snapshot? {
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .totalFileSizeKey, .fileSizeKey]
        ), let modified = values.contentModificationDate else { return nil }
        let size = Int64(values.totalFileSize ?? values.fileSize ?? 0)
        return Snapshot(size: size, modified: modified)
    }

    /// もう書き込みが終わっているとみなせるか。
    ///
    /// - 更新時刻が`quietInterval`より古ければ、その場で通す(未来の時刻も通す ―― 時計のずれや
    ///   意図的に先の日付を持つファイルを、永久に登録されないままにしないため)。
    /// - そうでなければ、`recheckDelay`以上空けた前回の観測と**大きさも更新時刻も同じ**ときだけ通す。
    static func isSettled(
        _ observation: Observation, previous: Observation?,
        quietFor quietInterval: TimeInterval = quietInterval,
        minimumGap: TimeInterval = recheckDelay
    ) -> Bool {
        let age = observation.at.timeIntervalSince(observation.snapshot.modified)
        if age < 0 || age >= quietInterval { return true }
        guard let previous, previous.snapshot == observation.snapshot else { return false }
        return observation.at.timeIntervalSince(previous.at) >= minimumGap
    }
}
