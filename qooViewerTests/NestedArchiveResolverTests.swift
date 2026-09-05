import Foundation
import Testing

@testable import qooViewer

/// 入れ子の書庫を「使うときに、予算の範囲で」開く解決役(`NestedArchiveResolver`)。
///
/// 見るのは、予算からの導出・行き先(メモリか一時ファイルか)・一時ファイルの寿命・LRU の 4 つ。
/// どれも壊れても本は開けてしまい、代わりにディスクとメモリが静かに膨らむ(以前は 8.4GB の残骸が
/// テンポラリに残っていた。型コメント参照)ので、テストで押さえておきたい。
struct NestedArchiveResolverTests {
    /// 中に ch01.cbz / ch02.cbz が入った zip。
    private let nestedFixture = "nested/nested-zip-in-zip.cbz"

    private func locator(_ entryPath: String) -> ArchiveLocator {
        ArchiveLocator(rootURL: Fixtures.url(nestedFixture), nestedPath: [entryPath])
    }

    // MARK: - 予算の導出

    @Test("Limits.standard は環境設定のメモリ上限から他の値を導く")
    func standardLimits() {
        let small = NestedArchiveResolver.Limits.standard(inMemoryBytes: 64 * 1024 * 1024)
        #expect(small.maxOpenReaders == 8)
        #expect(small.maxInMemoryBytes == 64 * 1024 * 1024)
        // 予算に収まる書庫はメモリ、収まらないものだけディスク。線引きは上限そのもの。
        #expect(small.spillToDiskThresholdBytes == small.maxInMemoryBytes)
        // 一時ファイルは「メモリ上限の 2 倍、ただし最低 256MB」。
        #expect(small.maxTemporaryBytes == 256 * 1024 * 1024)
        #expect(small.maxSingleArchiveBytes == 4 * 1024 * 1024 * 1024)

        let large = NestedArchiveResolver.Limits.standard(inMemoryBytes: 512 * 1024 * 1024)
        #expect(large.maxTemporaryBytes == 1024 * 1024 * 1024)

        // 負の値でも破綻しない(0 に丸める)。
        let negative = NestedArchiveResolver.Limits.standard(inMemoryBytes: -1)
        #expect(negative.maxInMemoryBytes == 0)
        #expect(negative.spillToDiskThresholdBytes == 0)
    }

    // MARK: - 行き先

    @Test("予算に収まる入れ子の書庫はメモリに載る(ディスクに出ない)")
    func opensFromMemory() throws {
        let resolver = NestedArchiveResolver(limits: .standard(inMemoryBytes: 64 * 1024 * 1024))
        let opened = try resolver.open(locator("ch01.cbz"))
        #expect(opened.storage == .inMemory)
        #expect(opened.byteCount > 0)
        #expect(try opened.reader.listFilePaths().sorted() == ["001.png", "002.png", "003.png"])

        let stats = resolver.statistics()
        #expect(stats.inMemoryArchiveCount == 1)
        #expect(stats.temporaryArchiveCount == 0)
        #expect(stats.inMemoryBytes == opened.byteCount)
        // ルートの書庫も開いたままになる(親を辿って開くため)。
        #expect(stats.openReaderCount == 2)
    }

    @Test("メモリ予算 0 なら一時ファイルへ倒れ、手放すと消える")
    func spillsToTemporaryFile() async throws {
        let resolver = NestedArchiveResolver(limits: .standard(inMemoryBytes: 0))
        let before = temporaryArchiveFileNames()
        var opened: OpenArchive? = try resolver.open(locator("ch01.cbz"))
        #expect(opened?.storage == .temporaryFile)
        #expect(try opened?.reader.listFilePaths().count == 3)
        #expect(resolver.statistics().temporaryArchiveCount == 1)
        // 名前で差を取る(テストは並行に走るので、他のテストの一時ファイルと数で比べない)。
        let added = temporaryArchiveFileNames().subtracting(before)
        #expect(!added.isEmpty, "一時ファイルが作られていない")

        // 一時ファイルの寿命は OpenArchive ただ 1 つに紐づく(TemporaryArchiveFile.deinit)。
        // 削除は deinit から Task.detached へ逃がしてあるので、消えるのを少しだけ待つ。
        resolver.purgeAll()
        opened = nil
        #expect(
            await eventually { temporaryArchiveFileNames().isDisjoint(with: added) },
            "一時ファイルが残っている"
        )
    }

    @Test("1 本で上限を超える書庫は archiveTooLarge")
    func rejectsTooLargeArchive() throws {
        var limits = NestedArchiveResolver.Limits.standard(inMemoryBytes: 64 * 1024 * 1024)
        limits.maxSingleArchiveBytes = 16  // 中の ch01.cbz(数百バイト)より小さくする
        let resolver = NestedArchiveResolver(limits: limits)
        #expect(throws: NestedArchiveResolver.ResolveError.archiveTooLarge) {
            _ = try resolver.open(locator("ch01.cbz"))
        }
    }

    // MARK: - LRU

    @Test("開いたままの reader の数は maxOpenReaders まで(最後の 1 つは必ず残す)")
    func evictsOldestReaders() throws {
        var limits = NestedArchiveResolver.Limits.standard(inMemoryBytes: 64 * 1024 * 1024)
        limits.maxOpenReaders = 2
        let resolver = NestedArchiveResolver(limits: limits)

        _ = try resolver.open(locator("ch01.cbz"))  // ルート + ch01 で 2 つ
        #expect(resolver.statistics().openReaderCount == 2)
        _ = try resolver.open(locator("ch02.cbz"))  // 3 つ目でルート(最も古い)が追い出される
        #expect(resolver.statistics().openReaderCount == 2)

        // 追い出されても開き直せる(結果は変わらない)。
        #expect(try resolver.open(locator("ch01.cbz")).reader.listFilePaths().count == 3)

        resolver.purgeAll()
        #expect(resolver.statistics().openReaderCount == 0)
    }

    @Test("openTransient は LRU に載せない(本を開くときの列挙が使う経路)")
    func transientOpenIsNotCached() throws {
        let resolver = NestedArchiveResolver(limits: .standard(inMemoryBytes: 64 * 1024 * 1024))
        let root = try resolver.openRoot(Fixtures.url(nestedFixture))
        #expect(resolver.statistics().openReaderCount == 0, "openRoot も LRU には載らない")

        let child = try resolver.openTransient(locator("ch01.cbz"), parentReader: root.reader)
        #expect(try child.reader.listFilePaths().count == 3)
        #expect(resolver.statistics().openReaderCount == 0)
        #expect(resolver.statistics().inMemoryArchiveCount == 0)
    }

    // MARK: - 独立した一時ファイル

    @Test("materializeToIndependentFile は解決役の寿命と切り離されたファイルを返す")
    func materializeToIndependentFile() async throws {
        let resolver = NestedArchiveResolver(limits: .standard(inMemoryBytes: 64 * 1024 * 1024))
        let url = try resolver.materializeToIndependentFile(locator("ch01.cbz"))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "cbz")

        // 解決役が全部手放しても、このファイルは消えない(削除の責任は呼び出し側)。
        // 内部の一時ファイルなら deinit の Task.detached がこの間に消しているはずの間隔を置く。
        resolver.purgeAll()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try makeArchiveReader(for: url).listFilePaths().count == 3)

        // 入れ子でない書庫は書き出さず、そのままのパスを返す。
        let rootURL = Fixtures.url(nestedFixture)
        #expect(try resolver.materializeToIndependentFile(ArchiveLocator(rootURL: rootURL)) == rootURL)
    }

    // MARK: - 道具

    /// このプロセスの一時ファイル置き場(`TemporaryFileStore.sessionDirectory`)にあるファイル名。
    private func temporaryArchiveFileNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            at: TemporaryFileStore.sessionDirectory, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)) ?? []
        return Set(names)
    }

    /// `condition` が真になるまで少しだけ待つ(削除は `deinit` から Task.detached へ逃がしてあるため)。
    private func eventually(
        timeout: Duration = .seconds(3), _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
