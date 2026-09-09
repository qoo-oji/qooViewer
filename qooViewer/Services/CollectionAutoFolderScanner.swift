import AppKit
import Combine
import Foundation

/// 自動登録フォルダ(`BookCollection.autoFolderPath`)を見に行って、まだ入っていない本を
/// コレクションへ足す(ユーザー要望 2026-09-09)。
///
/// ■ なぜFSEventsで監視しないのか
/// 自動登録の結果が意味を持つのは「ウェルカム画面のコレクションを見たとき」だけで、裏で本が
/// 増えた瞬間に知らせる相手がいない。**見る直前に走査する**だけで見え方は同じになる。
/// 常時監視を入れると、
///   ・コピーの途中(まだ書き終わっていない書庫)がその瞬間に登録され、カバーの抽出が
///     `.failed` のまま固定される
///   ・許可済みフォルダのぶんだけストリームを張り、閉じ忘れの面倒を新しく作る
/// という2つを引き受けることになる。契機を「アプリがアクティブになった/画面が出た」に
/// 寄せておけば、どちらも起きない。
///
/// ■ 棚の判定は増やさない
/// 「そのフォルダに並んでいる本」はShelfFolderResolver.role(of:order:)の`.shelf(books:)`
/// そのもの ―― **直下だけ**で、ファイルの本と画像を直接持つフォルダが並び順どおりに入る。
/// 編集モード中にそのフォルダをドロップしたときに入る本と、1冊のずれもなく一致する
/// (CollectionDropClassifierも同じ判定を通っている)。
///
/// ■ アクセス権はFolderAccessStoreに一本化する
/// フォルダを列挙してよいかはFolderAccessStore.isPathCoveredにだけ訊く。覆われていなければ
/// **黙って見送る**(設定の面が「アクセスを許可」を出す。BookCollection.autoFolderPathの
/// コメント参照)。
@MainActor
final class CollectionAutoFolderScanner: ObservableObject {
    private let collectionStore: CollectionStore
    private let coverExtractor: CollectionCoverExtractor
    private let folderAccess: FolderAccessStore
    private let preferences: AppPreferences

    private var isScanning = false
    private var needsAnotherScan = false
    private var activationObserver: NSObjectProtocol?
    private var volumeObservers: [NSObjectProtocol] = []

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

        // 契機はCollectionStoreが実体の存在確認をやり直すのと同じもの(あちらのinitと同じ形)。
        // 画面側の契機(ウェルカム画面が出た・コレクションを開いた)はscheduleScan()を直に呼ぶ。
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

    /// このオブジェクトが張った購読を外す(**テストのための口**。CollectionStore.
    /// releaseResourcesと同じ理由・同じ形)。
    func releaseResources() {
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

    /// 自動登録フォルダを持つコレクションを全部見に行く。走査中に重ねて呼ばれたら、
    /// いま走っているぶんが終わってからもう一度だけ走る(scheduleExistenceRefreshと同じ形)。
    func scheduleScan() {
        guard !isScanning else {
            needsAnotherScan = true
            return
        }
        // 権限が無いフォルダはここで落とす(走査そのものを始めない)。
        let targets = collectionStore.autoFolderTargets()
            .filter { folderAccess.isPathCovered($0.folder) }
        guard !targets.isEmpty else { return }

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

    private func finishScan(_ found: [(id: UUID, books: [URL])]) {
        isScanning = false
        defer {
            if needsAnotherScan {
                needsAnotherScan = false
                scheduleScan()
            }
        }
        for entry in found {
            guard let collection = collectionStore.collection(withID: entry.id) else { continue }
            // 既に入っている本を先に落としてから材料を作る(unregisteredURLsのコメント参照)。
            let fresh = collectionStore.unregisteredURLs(entry.books, in: collection)
            guard !fresh.isEmpty else { continue }
            let pending = fresh.compactMap(CollectionStore.makePendingItem(for:))
            guard !pending.isEmpty else { continue }
            coverExtractor.enqueue(collectionStore.add(pending, to: collection))
        }
    }
}

/// 自動登録フォルダから拾う本を決めるところ(走査の中核)。
///
/// アクターにもストアにも触らない純粋な判定なので、**メインアクターの外から直に呼べる**形で
/// 切り出してある(テストもこちらを直接叩く。ArchiveReading.swift冒頭のコメント参照)。
nonisolated enum CollectionAutoFolderScan {
    /// **落ち着くまで待つ時間。** これより後に更新されたものは、今回は登録を見送る。
    ///
    /// 大きな書庫をフォルダへコピーしている最中に走査が当たると、まだ書き終わっていない
    /// ファイルが本として登録され、カバーの抽出が失敗して`.failed`のまま固定される
    /// (抽出をやり直す契機はカバーの上書きが変わったときだけ ――
    /// CollectionCoverExtractorの型コメント参照)。コピー中のファイルは更新時刻が動き続ける
    /// ので、「最後の更新から少し経っている」ことを条件にすれば、次の走査まで待たされるだけで
    /// 済む。走査の契機自体が人の操作(画面を見にくる)なので、待たされたことは目に見えない。
    static let settlingInterval: TimeInterval = 10

    /// `folder`の直下に並んでいて、登録してよい状態になっている本。
    ///
    /// フォルダが棚でない(それ自体が1冊、空、中間フォルダだけ)ときは空を返す ――
    /// **指定そのものは弾かない**。いまは本が無くても、後からそこへ書庫が置かれれば棚になる。
    static func books(in folder: URL, order: SiblingBookOrder, now: Date = Date()) -> [URL] {
        guard case .shelf(let books) = ShelfFolderResolver.role(of: folder, order: order) else {
            return []
        }
        return books.filter { hasSettled($0, now: now) }
    }

    /// 最後の更新から`settlingInterval`以上経っているか。
    ///
    /// 更新時刻が読めないものは**通す** ―― 判定の材料が無いだけで、本かどうかは既に決まって
    /// いる。未来の時刻(時計のずれ、意図的に先の日付を持つファイル)も通す ―― そうしないと
    /// その本は永久に登録されない。
    static func hasSettled(_ url: URL, now: Date = Date()) -> Bool {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        else { return true }
        let elapsed = now.timeIntervalSince(modified)
        return elapsed < 0 || elapsed >= settlingInterval
    }
}
