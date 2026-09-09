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

    /// 見張るフォルダの数だけファイル記述子が増えてはいけない。`WatchRoot` を付けていたときは
    /// ルートごとに祖先ディレクトリを1階層ずつ握り(深さ5なら5個)、自動登録フォルダ49個で
    /// GUI アプリの上限256を起動直後に使い切っていた(実機で発覚 2026-09-09。カバーが全部空になり、
    /// ドロップのブックマークも作れなくなった)。数えるのは open されている fd の総数
    /// (`fcntl(F_GETFD)` が通るもの)で、ストリーム自体が要するぶんの余裕だけ見ておく。
    @Test("見張るフォルダの数だけファイル記述子が増えない", .timeLimit(.minutes(1)))
    func watchingManyRootsDoesNotHoldAFileDescriptorPerRoot() async throws {
        let temporary = try TemporaryDirectory("folder-watch-fds")
        // 実機と同じ深さ(/Volumes/<disk>/<棚>/<ライブラリ>/<作者>)に寄せる。
        var roots: Set<String> = []
        for index in 0..<40 {
            roots.insert(try temporary.directory("shelf/library/author\(index)/books").path)
        }
        let watcher = FolderChangeWatcher {}
        let before = Self.openFileDescriptorCount()
        await watcher.watch(roots)
        let during = Self.openFileDescriptorCount()
        watcher.tearDown()

        // WatchRoot 付きなら 40 × 5 階層以上増える。ストリーム1本ぶんの余裕(数個)だけ許す。
        #expect(during - before < 8, "fds before=\(before) during=\(during)")
    }

    private static func openFileDescriptorCount() -> Int {
        (0..<getdtablesize()).reduce(into: 0) { count, fd in
            if fcntl(fd, F_GETFD) != -1 { count += 1 }
        }
    }
}
