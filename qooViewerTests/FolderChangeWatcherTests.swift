import Foundation
import Testing

@testable import qooViewer

/// FSEvents の薄い包み(Services/FolderChangeWatcher.swift)。
///
/// 見るのは 1 つ ―― 見張っているフォルダへ本を置くと、知らせが届くこと。中身(何が変わったか)は
/// 渡さない作りなので、届いたかどうかだけを見る。待ち合わせは時間ではなく知らせそのもので行う
/// (`AsyncStream` を 1 回進める)。届かなければ suite の時間制限で落ちる。
@MainActor
struct FolderChangeWatcherTests {
    @Test("見張っているフォルダに本を置くと知らせが届く", .timeLimit(.minutes(1)))
    func aChangeInsideTheWatchedFolderIsReported() async throws {
        let temporary = try TemporaryDirectory("folder-watch")
        let shelf = try temporary.directory("shelf")
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        let watcher = FolderChangeWatcher { continuation.yield() }
        // 生成は待つ(FSEventStreamCreate がブロックしうるので async)。
        await watcher.watch([shelf.path])

        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: 1))
        try builder.write(to: shelf.appendingPathComponent("01.cbz"))

        for await _ in changes { break }
        watcher.tearDown()
    }

    @Test("見張るものが無くなったら、次に張るストリームは止めた時点からの続きを再生しない(2 回目の監査 19)")
    func stoppingForgetsWhereItLeftOff() async throws {
        // 以前は空の組で止めた後も続きの位置を持ち越し、数時間後に戻るとその間の履歴がまとめて届いた。
        let temporary = try TemporaryDirectory("folder-watch-forget")
        let first = try temporary.directory("first")
        let second = try temporary.directory("second")
        let watcher = FolderChangeWatcher {}
        let sinceNow = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        await watcher.watch([first.path])
        await watcher.watch([second.path])
        #expect(watcher.lastEventID != sinceNow, "入れ替える間の空白は埋める")
        await watcher.watch([])
        #expect(watcher.lastEventID == sinceNow)
        await watcher.watch([first.path])
        watcher.tearDown()
        #expect(watcher.lastEventID == sinceNow)
    }

    /// FSEvents は、起点(`sinceWhen`)を渡して張ったストリームへ、まず「履歴」を再生してから生の知らせを送る。`FullHistory` を
    /// 付けていると、起点を含むかたまりに入っている変更は**起点より前のものまで**再生され、最後に見張っている根のパスを持つ
    /// 番兵(`HistoryDone`)が届く。見張るフォルダを入れ替えるたびにそれが受け取り側へ流れ、ファイルブラウザのツリーでは
    /// 行を開閉するたびに、開いているほかの行が読み直されて描き直された(2026-09-29、ユーザー報告)。
    ///
    /// 待ち合わせは知らせそのもので行う ―― 履歴は生の知らせより先に届くので、入れ替えた後に置いた目印が届くまでに
    /// 受け取ったものを全部見る。
    @Test("見張るフォルダを入れ替えても、前からあった変更と番兵は届かない", .timeLimit(.minutes(1)))
    func swappingWatchedFoldersReplaysNoHistory() async throws {
        let temporary = try TemporaryDirectory("folder-watch-swap")
        let first = try temporary.directory("first")
        let second = try temporary.directory("second")
        // 入れ替えの前からある変更(履歴になるもの)。
        #expect(FileManager.default.createFile(atPath: second.appendingPathComponent("old.txt").path, contents: Data()))
        // フォルダを作った知らせが、最初のストリームへ生の知らせとして届かないところまで待つ(履歴には残る)。
        try await Task.sleep(for: .seconds(1))

        let (changes, continuation) = AsyncStream<[String]>.makeStream()
        let watcher = FolderChangeWatcher(onChangedPaths: { continuation.yield($0) })
        await watcher.watch([first.path])
        await watcher.watch([first.path, second.path])
        #expect(FileManager.default.createFile(atPath: first.appendingPathComponent("marker.txt").path, contents: Data()))

        var received: [String] = []
        for await paths in changes {
            received += paths
            if paths.contains(where: { $0.hasSuffix("/marker.txt") }) { break }
        }
        watcher.tearDown()
        let unexpected = received.filter { !$0.hasSuffix("/marker.txt") }.map { ($0 as NSString).lastPathComponent }
        #expect(unexpected.isEmpty, "入れ替えで再生された: \(unexpected)")
    }

    @Test("履歴の再生のうち捨てるのは、番兵と、番兵より前に届いた起点以前の変更だけ")
    func onlyReplayedHistoryBeforeTheStartIsDropped() {
        let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped)
        func admitted(
            _ progress: FolderChangeStreamProgress, _ events: [(id: FSEventStreamEventId, flags: FSEventStreamEventFlags)]
        ) -> [Int] {
            progress.admittedIndices(count: events.count, flags: events.map(\.flags), ids: events.map(\.id))
        }

        let resumed = FolderChangeStreamProgress(sinceWhen: 100)
        // 起点以前(重なりの再生)は捨て、起点より後(入れ替えの間の空白)は渡す。取りこぼしの知らせと ID の無いものは渡す。
        #expect(admitted(resumed, [(90, created), (100, created), (101, created), (95, dropped), (0, created)]) == [2, 3, 4])
        #expect(!resumed.wasCalledBack(within: 0) && resumed.wasCalledBack(within: 60))
        // 番兵そのものは渡さない。番兵の後は生の知らせなので、ID を見ずに渡す。
        #expect(admitted(resumed, [(99, created), (100, historyDone), (99, created)]) == [2])
        #expect(admitted(resumed, [(1, created)]) == [0])

        // SinceNow で張ったストリームは履歴を持たない(何も捨てない)。
        let fresh = FolderChangeStreamProgress(sinceWhen: FSEventStreamEventId(kFSEventStreamEventIdSinceNow))
        #expect(fresh.startedAfter == nil)
        #expect(!fresh.wasCalledBack(within: 60))
        #expect(admitted(fresh, [(1, created), (2, created)]) == [0, 1])
    }

    /// 見張るフォルダの数だけファイル記述子が増えてはいけない。`WatchRoot` を付けていたときは
    /// ルートごとに祖先ディレクトリを1階層ずつ握り(深さ5なら5個)、自動登録フォルダ49個で
    /// GUI アプリの上限256を起動直後に使い切っていた(実機で発覚 2026-09-09。カバーが全部空になり、
    /// ドロップのブックマークも作れなくなった)。数えるのは open されている fd の総数
    /// (`fcntl(F_GETFD)` が通るもの)で、ストリーム自体が要するぶんの余裕だけ見ておく。
    ///
    /// **測るのは1度きりにしない。** fd の総数はプロセス全体の値で、Swift Testing は既定で
    /// テストを**並行に**走らせるため、同じテストホストで動いている別のテストがちょうどこの
    /// 前後でファイルを開くと、その1個2個がこの差分に混ざる(CI で差分9になって落ちた
    /// 2026-09-10。そのときこのテスト自体は 6.459 秒かかっており、手元で単独に走らせると
    /// 0.039 秒・差分1)。見たいのは「見張るたびに増え続けるか」なので、何度か測って**いちばん
    /// 小さい差分**を採る ―― 周りの雑音は測るたびに出たり出なかったりするが、ルートごとに
    /// fd を握る作りへ戻れば毎回同じだけ増えるので、最小値でも必ず引っかかる。
    @Test("見張るフォルダの数だけファイル記述子が増えない", .timeLimit(.minutes(1)))
    func watchingManyRootsDoesNotHoldAFileDescriptorPerRoot() async throws {
        let temporary = try TemporaryDirectory("folder-watch-fds")
        // 実機と同じ深さ(/Volumes/<disk>/<棚>/<ライブラリ>/<作者>)に寄せる。
        var roots: Set<String> = []
        for index in 0..<40 {
            roots.insert(try temporary.directory("shelf/library/author\(index)/books").path)
        }
        var smallestGrowth = Int.max
        var measurements: [String] = []
        for _ in 0..<5 {
            let watcher = FolderChangeWatcher {}
            let before = Self.openFileDescriptorCount()
            await watcher.watch(roots)
            let during = Self.openFileDescriptorCount()
            watcher.tearDown()
            smallestGrowth = min(smallestGrowth, during - before)
            measurements.append("\(before)→\(during)")
        }

        // WatchRoot 付きなら 40 × 5 階層以上増える。ストリーム1本ぶんの余裕(数個)だけ許す。
        #expect(smallestGrowth < 8, "fds \(measurements.joined(separator: ", "))")
    }

    private static func openFileDescriptorCount() -> Int {
        (0..<getdtablesize()).reduce(into: 0) { count, fd in
            if fcntl(fd, F_GETFD) != -1 { count += 1 }
        }
    }
}
