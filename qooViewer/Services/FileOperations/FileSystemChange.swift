import Combine
import Foundation

/// **アプリ自身が**ファイルシステムを変えた、という知らせ 1 回ぶん(2026-09-19 の監査。docs/plans/fs-ui-consistency-audit.md)。
///
/// ■ なぜ要るか
/// ファイルブラウザができるまで、ファイルを動かすのは必ずアプリの外(Finder)だったので、棚・履歴・サイドパネルは
/// 「アクティブになったら確かめ直す」で足りた。いまはアプリがアクティブなまま自分でファイルを動かす(ファイルブラウザの操作・
/// 取り消し・やり直し・自動リネーム)。それを知るのが操作をしたウインドウの一覧だけだったので、ほかのウインドウ・サイドパネル・
/// 棚・保存データが古いままになった。FSEvents が補えるのはローカルのボリュームの、見張っているフォルダだけ。
///
/// ■ どこから出すか
/// `FileOperationService` の入り口(`changeObserver`)。実行も取り消しもやり直しも自動リネームも必ずそこを通るので、
/// 経路ごとに出し忘れない。**新旧のパスが分かる**(受領書)のが FSEvents との違いで、受け手はパスで覚えている状態
/// (表示中のフォルダ・履歴・よく使う項目・DB の bookID)を付け替えられる。
nonisolated struct FileSystemChange: Sendable, Equatable {
    /// 名前の変更・移動 1 件(別ボリュームへの移動も含む)。
    struct Relocation: Sendable, Equatable {
        let from: URL
        let to: URL
    }

    /// 名前が変わった・移った項目。**起きた順**(A → B、B → C と続いたら、この順に当てはめると A → C になる)。
    var relocations: [Relocation] = []
    /// その場所から無くなった項目(ゴミ箱へ送った・完全に削除した)。
    var removed: [URL] = []
    /// その場所にできた項目(コピー・新規フォルダ・圧縮・展開・ゴミ箱から戻した)。
    var created: [URL] = []

    var isEmpty: Bool { relocations.isEmpty && removed.isEmpty && created.isEmpty }

    mutating func merge(_ other: FileSystemChange) {
        relocations += other.relocations
        removed += other.removed
        created += other.created
    }

    /// 中身が変わったフォルダ(変わった項目の親)のパス。末尾の `/` は持たない(`FileBrowserState.id(for:)` と同じ規則)。
    var affectedFolderPaths: Set<String> {
        var paths = Set<String>()
        for url in relocations.flatMap({ [$0.from, $0.to] }) + removed + created {
            paths.insert(Self.path(of: url.deletingLastPathComponent()))
        }
        return paths
    }

    /// `path`(またはその祖先)が移っていたら、移った先のパス。移っていなければ nil。
    func relocatedPath(for path: String) -> String? {
        var current = MountTable.normalized(path)
        var changed = false
        for relocation in relocations {
            let from = Self.path(of: relocation.from)
            guard MountTable.path(current, isAtOrUnder: from) else { continue }
            current = Self.path(of: relocation.to) + current.dropFirst(from.count)
            changed = true
        }
        return changed ? current : nil
    }

    /// `path`(またはその祖先)がその場所から無くなったか(移った・消えた)。
    func displaces(_ path: String) -> Bool {
        let path = MountTable.normalized(path)
        return (relocations.map(\.from) + removed).contains { MountTable.path(path, isAtOrUnder: Self.path(of: $0)) }
    }

    /// そのフォルダの一覧を読み直す必要があるか: 直下の項目が変わった、直下のフォルダの中身が変わった(そのフォルダの変更日が変わり、
    /// 変更日順の並びも変わる)、またはフォルダ自身か祖先がその場所から無くなった。
    func requiresReload(ofFolderAt path: String) -> Bool {
        let path = MountTable.normalized(path)
        let affected = affectedFolderPaths
        return affected.contains(path)
            || affected.contains { ($0 as NSString).deletingLastPathComponent == path }
            || displaces(path)
    }

    private static func path(of url: URL) -> String {
        MountTable.normalized(url.path)
    }
}

/// `FileSystemChange` を配る(アプリで 1 つ。`shared`)。
///
/// 出す側はどのスレッドからでも `report` する(`FileOperationService` は actor)。続けて届いた知らせは**起きた順のまま 1 つにまとめ**、
/// 少し間を置いてメインアクターで配る(一括リネームは 1 件ごとに届く)。操作を終えた側は `flush()` で待たずに配れる。
///
/// **テストは自分の箱を作って渡す**(`FileBrowserState` / `SidePanelBrowserState` は、テストの中では既定で自分だけの箱を持つ)。
/// `shared` を使うと、並んで走る別のテストの操作で一覧が読み直される。
nonisolated final class FileSystemChangeCenter: @unchecked Sendable {
    static let shared = FileSystemChangeCenter()

    /// まとめる間隔。人の目には即時で、一括リネームの数千件が 1 回になる。
    static let coalescingInterval: Duration = .milliseconds(80)

    private let lock = NSLock()
    private var pending = FileSystemChange()
    private var isScheduled = false
    private let subject = PassthroughSubject<FileSystemChange, Never>()

    init() {}

    /// 知らせの流れ。**メインアクターで届く。**
    var changes: AnyPublisher<FileSystemChange, Never> { subject.eraseToAnyPublisher() }

    /// 状態ごとの既定の箱。テストの中で走るアプリでは、状態ごとに別の箱(型コメント)。
    static func defaultForState() -> FileSystemChangeCenter {
        RuntimeEnvironment.isRunningTests ? FileSystemChangeCenter() : shared
    }

    func report(_ change: FileSystemChange) {
        guard !change.isEmpty else { return }
        lock.lock()
        pending.merge(change)
        let schedules = !isScheduled
        isScheduled = true
        lock.unlock()
        guard schedules else { return }
        Task { @MainActor in
            try? await Task.sleep(for: Self.coalescingInterval)
            self.flush()
        }
    }

    /// 溜まっている知らせを今すぐ配る(操作を終えた直後。テストもこれで待たずに確かめる)。
    @MainActor
    func flush() {
        lock.lock()
        let change = pending
        pending = FileSystemChange()
        isScheduled = false
        lock.unlock()
        guard !change.isEmpty else { return }
        subject.send(change)
    }
}
