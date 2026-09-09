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
}
