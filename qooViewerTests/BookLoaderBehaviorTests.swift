import Foundation
import Testing

@testable import qooViewer

/// `BookLoader` の、並び順以外の振る舞い ―― 中止・進み具合の通知・入れ子の書庫に許すメモリ・
/// 直接渡された画像ファイル。並びそのもの(golden)は `FixtureBookTests` / `GeneratedFixtureTests`。
struct BookLoaderBehaviorTests {

    // MARK: - 中止

    /// 「中止」を押したときに、走査が最後まで走り切ってしまわないこと。
    ///
    /// `BookLoader.load` の中身は `Task.detached` で、**キャンセルは継承されない**(Swift の仕様)。
    /// `withTaskCancellationHandler` で手で伝えているので、そこが外れると中止が効かなくなる。
    /// 入れ子を辿るあいだ `Task.checkCancellation` を通るフィクスチャ(3 段の入れ子)を、進み具合の
    /// 通知で待たせながら中止する。
    @Test("読み込み中の中止は CancellationError になる")
    func cancellation() async throws {
        let url = Fixtures.url("nested/nested-depth3.cbz")
        // 進み具合の通知は読み込みのタスクの中で同期的に呼ばれるので、そこで眠らせれば走査も
        // そのぶん止まる。最初の通知(本そのものの書庫を見つけた時点)は列挙より前に必ず来る。
        let task = Task.detached {
            _ = try await FixtureBook.load(url) { _ in Thread.sleep(forTimeInterval: 0.2) }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: - 進み具合

    @Test("onProgress は見つけた書庫と数え終えた書庫を単調に増やして知らせる")
    func progressReports() async throws {
        let reports = ProgressLog()
        let book = try await FixtureBook.load(Fixtures.url("nested/nested-depth3.cbz")) { progress in
            reports.append(progress)
        }
        #expect(book.pages.count == 8)

        let observed = reports.all
        #expect(!observed.isEmpty, "1 度も知らせていない")
        // 間引き(10Hz)があるので回数は決め打ちできない。単調であることと、最後に数え終えた
        // 書庫の名前が本当にこの本の中にあることを見る。
        #expect(zip(observed, observed.dropFirst()).allSatisfy {
            $0.discoveredArchiveCount <= $1.discoveredArchiveCount
                && $0.completedArchiveCount <= $1.completedArchiveCount
        })
        #expect(observed.allSatisfy { $0.completedArchiveCount <= $0.discoveredArchiveCount })
        let names = Set(observed.compactMap(\.currentArchiveName))
        #expect(names.isSubset(of: ["nested-depth3.cbz", "level2.cbz", "level3.cbz"]), "\(names)")
    }

    // MARK: - 入れ子の書庫に許すメモリ

    /// 入れ子の書庫がメモリに載るか一時ファイルへ倒れるかは大きさだけで決まり、**本の中身は
    /// どちらでも同じ**(NestedArchiveResolver)。予算 0 = 必ず一時ファイル経路で、同じ本になること。
    @Test(
        "入れ子の書庫は、メモリ予算 0(=必ず一時ファイル)でも同じ本になる",
        arguments: ["nested/nested-zip-in-zip.cbz", "nested/nested-depth3.cbz", "nested/nested-zip-in-7z.cb7"]
    )
    func nestedArchiveMemoryLimitDoesNotChangeTheBook(path: String) async throws {
        let url = Fixtures.url(path)
        let expected = try #require(Fixtures.manifest.fixtures[path]?.book?.sortKeys)
        let spilled = try await FixtureBook.load(url, nestedArchiveMemoryLimitBytes: 0)
        #expect(spilled.pages.map(\.sortKey) == expected)
        #expect(spilled.pages.allSatisfy { $0.id.hasPrefix(url.path + "#") })
    }

    // MARK: - 直接渡された画像ファイル

    @Test("load(imageFiles:) は自然順に並べ、重複と実在しないファイルを落とす")
    func loadImageFiles() async throws {
        let temp = try TemporaryDirectory("image-files")
        let root = try FixtureFolder.make(
            at: temp.file("pages"),
            pages: [.init("2.png", number: 2), .init("10.png", number: 10), .init("1.png", number: 1)],
            extraFiles: ["notes.txt": "not a page"]
        )
        let page = { (name: String) in root.appendingPathComponent(name) }

        let book = try await BookLoader.load(imageFiles: [
            page("10.png"), page("2.png"), page("2.png"), page("1.png"),
            page("notes.txt"), page("missing.png"),
        ])
        #expect(book.pages.map(\.sortKey) == [page("1.png").path, page("2.png").path, page("10.png").path])
        // その場限りの本(DB・キャッシュ・履歴のどれにも残さない)。
        #expect(book.origin == .imageFiles)
        #expect(book.id.hasPrefix("qooviewer-image-files:"))
        #expect(book.sourceURL == page("1.png"))
        #expect(book.title == "1")
    }

    @Test("load(imageFiles:) に 1 枚だけ渡すと、実在パスを id に持つ 1 ページの本になる")
    func loadSingleImageFile() async throws {
        let temp = try TemporaryDirectory("single-image")
        let root = try FixtureFolder.make(at: temp.file("pages"), pages: [.init("cover.png", number: 1)])
        let cover = root.appendingPathComponent("cover.png")

        // 重複と実在しないファイルを落とした結果 1 枚になる場合も同じ扱い。
        let book = try await BookLoader.load(imageFiles: [cover, cover, root.appendingPathComponent("x.png")])
        #expect(book.id == cover.path)
        #expect(book.origin == .imageFiles)
        #expect(book.pages.map(\.sortKey) == [cover.path])

        // 画像 1 枚をそのまま開く経路(ドロップ)も同じ本になる。
        let dropped = try await FixtureBook.load(cover)
        #expect(dropped.id == cover.path)
        #expect(dropped.origin == .imageFiles)
        #expect(dropped.pages.count == 1)
    }

    @Test("load(imageFiles:) は画像が 1 枚も無ければ notFound")
    func loadImageFilesWithoutImages() async throws {
        let temp = try TemporaryDirectory("no-images")
        let root = try FixtureFolder.make(at: temp.file("pages"), pages: [], extraFiles: ["notes.txt": "x"])
        await #expect(throws: BookLoaderError.notFound) {
            _ = try await BookLoader.load(imageFiles: [root.appendingPathComponent("notes.txt")])
        }
    }

    @Test("存在しないパスは notFound")
    func missingBook() async throws {
        let temp = try TemporaryDirectory("missing")
        await #expect(throws: BookLoaderError.notFound) {
            _ = try await FixtureBook.load(temp.file("nope.cbz"))
        }
    }

    /// `onProgress` はメインアクター外から呼ばれるので、受け取り側で守る。
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var reports: [BookLoadProgress] = []

        func append(_ progress: BookLoadProgress) {
            lock.lock()
            defer { lock.unlock() }
            reports.append(progress)
        }

        var all: [BookLoadProgress] {
            lock.lock()
            defer { lock.unlock() }
            return reports
        }
    }
}
