import CoreGraphics
import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

@testable import qooViewer

/// 参照ファイルの本を PageLoader で読む。網越しの読み出しが actor(協調スレッド)もデコードの枠も塞がないこと、寸法と
/// 表示で同じページを 2 度取らないこと、ComicInfo.xml を探しに行かないこと、サムネイルの鍵が参照ファイルの書き直しで
/// 変わらないことを固定する。
struct StackNestPageLoaderTests {
    @Test("網越しのページを待っているあいだも、PageLoader の actor は塞がらない")
    func remoteFetchDoesNotBlockTheActor() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        let gate = fixture.holdPage(0)
        defer { gate.open() }
        let display = Task { await loader.pageImage(at: 0) }
        // 要求が見立てに届く(= 読み出しが始まった)まで待つ。待つのは FileIO の上で(協調スレッドを塞がない)。
        #expect(await FileIO.perform { gate.waitForArrival() })
        // 応答を止めたまま、同じ actor へ別の用事を頼む。actor が網越しの読み出しで塞がっていれば、ここで時間切れになる。
        // 時間切れでも、止めた読み出しを流して片付けてから(フィクスチャを閉じた後で通信が走らないよう)結果を見る。
        var actorBlocked = false
        do {
            try await FileIO.withDeadline(.seconds(2)) {
                await loader.setImageCacheLimit(bytes: 64 * 1024 * 1024)
            }
        } catch {
            actorBlocked = true
        }
        gate.open()
        let image = await display.value
        #expect(!actorBlocked, "応答を止めている間、actor が塞がった")
        #expect(image.flatMap { PageColorReader.number(in: $0) } == 1)
        await loader.releaseAllResources()
    }

    @Test("応答の止まったページが 2 つあっても、ほかのページの表示はデコードの枠を待たない")
    func stalledPagesDoNotHoldDecodeSlots() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        // 枠は最大 2(PageLoader.maxConcurrentDecodes)。0 番と 1 番の応答を止める(部品の見立ての門はページごと)。
        let gates = [fixture.holdPage(0), fixture.holdPage(1)]
        defer { gates.forEach { $0.open() } }
        let stalled = [Task { await loader.pageImage(at: 0) }, Task { await loader.pageImage(at: 1) }]
        // 止めた要求が届くのを待つ(枠を取ってから取りに行く作りでは、枠が 1 の機で 2 件目は届かないので、届かなくても進む)。
        _ = await FileIO.perform { gates[0].waitForArrival(timeout: 2) }
        _ = await FileIO.perform { gates[1].waitForArrival(timeout: 2) }
        // 2 番は止めていない。枠を握ったまま網越しに待つ作りなら、2 つの枠が 0 番・1 番に握られていてここで時間切れになる。
        let third = Task { await loader.pageImage(at: 2).flatMap { PageColorReader.number(in: $0) } }
        var waitedForSlot = false
        do {
            _ = try await FileIO.withDeadline(.seconds(3)) { await third.value }
        } catch {
            waitedForSlot = true
        }
        // 時間切れでも、止めた読み出しを流して全部片付けてから(フィクスチャを閉じた後で通信が走らないよう)結果を見る。
        gates.forEach { $0.open() }
        for task in stalled { _ = await task.value }
        let number = await third.value
        #expect(!waitedForSlot, "止まったページがデコードの枠を握っていて、ほかのページが表示されなかった")
        #expect(number == 3)
        await loader.releaseAllResources()
    }

    @Test("取り寄せの最中の先読みに表示要求が合流したら、デコードの空き待ちでは先読みの列に並ばない")
    func displayJoiningAFetchingPrefetchQueuesAsDisplay() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        // デコードの枠を塞いでおく(空き待ちの列を見るため。デコードの速さに頼らない)。
        let occupied = await loader.occupyDecodeSlotsForTesting()
        // 0 番だけ応答を止め、先読みを始める(0・1・2 番)。1・2 番は取り終えて枠待ち(先読みの列)に入る。
        let gate = fixture.holdPage(0)
        defer { gate.open() }
        await loader.prefetch(around: 0, radius: 2)
        #expect(await FileIO.perform { gate.waitForArrival() })
        #expect(await Self.waitUntil { await loader.decodeWaiterCountsForTesting.prefetch == 2 })
        // 0 番はまだ取り寄せの最中(枠待ちの列にいない)。ここへ表示要求が合流する。
        #expect(await loader.cancellableInFlightCountForTesting == 3)
        let display = Task { await loader.pageImage(at: 0).flatMap { PageColorReader.number(in: $0) } }
        // 合流した(0 番が「先読みだけが握る読み込み」から外れた)のを見届けてから応答を流す。見届けないと、合流の前に 0 番が
        // 枠を待ち始めて先読みの列に並び、合流の修正を戻してもテストが通ってしまう。
        #expect(await Self.waitUntil { await loader.cancellableInFlightCountForTesting == 2 })
        gate.open()
        // 0 番が取り終えて枠を待つ。表示要求が合流済みなので、先読みの列ではなく表示要求の列に並ぶ。
        #expect(await Self.waitUntil {
            let counts = await loader.decodeWaiterCountsForTesting
            return counts.urgent + counts.prefetch == 3
        })
        let counts = await loader.decodeWaiterCountsForTesting
        #expect(counts.urgent == 1)
        #expect(counts.prefetch == 2)
        await loader.releaseOccupiedDecodeSlotsForTesting(occupied)
        #expect(await display.value == 1)
        // 先読みも片付けてから(フィクスチャを閉じた後で通信が走らないよう)終える。
        #expect(await Self.waitUntil { await !loader.isPrefetching })
        await loader.releaseAllResources()
    }

    /// 条件が成り立つまで(最長 5 秒)待つ。
    private static func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let limit = Date().addingTimeInterval(5)
        while !(await condition()) {
            if Date() >= limit { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test("寸法を読んでから表示しても、そのページを取りに行くのは 1 回")
    func pageSizeThenImageFetchesOnce() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        #expect(await loader.pageSize(at: 1) != nil)
        let image = await loader.pageImage(at: 1)
        #expect(image.flatMap { PageColorReader.number(in: $0) } == 2)
        #expect(fixture.pageRequestIndices == [1])
        await loader.releaseAllResources()
    }

    @Test("網越しの本の寸法の読み取りは、失敗しても取り直さない(nil を返し、取りに行くのは 1 回)")
    func pageSizeDoesNotRetryOnFailure() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        fixture.server.respond(.page(1), with: .status(500))
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        #expect(await loader.pageSize(at: 1) == nil)
        #expect(fixture.pageRequestIndices == [1])
        await loader.releaseAllResources()
    }

    @Test("シークバーのサムネイルも網越しの読み出しを FileIO で待つ(部品の同期の読み手は、メインスレッド・Task の中では Debug で止まる)")
    func remoteThumbnailIsFetchedOffTheActor() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        let thumbnail = await loader.thumbnail(at: 1)
        #expect(thumbnail.flatMap { PageColorReader.number(in: $0) } == 2)
        #expect(fixture.pageRequestIndices == [1])
        await loader.releaseAllResources()
    }

    @Test("1 ページの書き出しは、仮の名前(000001.jpg)ではなく届いた画像の形式の拡張子になる(PNG は png、JPEG は jpg)")
    func exportedPageKeepsItsRealFormat() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        // 0 番は PNG のまま(フィクスチャの既定)、1 番だけ JPEG で応える。
        fixture.server.respond(
            .page(1), with: .status(200, headers: ["Content-Type": "image/jpeg"], body: PageImageFactory.jpeg(number: 2))
        )
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        #expect(try await loader.exportableImageFileExtension(at: 0) == "png")
        #expect(try await loader.exportableImage(at: 0)?.fileExtension == "png")
        #expect(try await loader.exportableImageFileExtension(at: 1) == "jpg")
        #expect(try await loader.exportableImage(at: 1)?.fileExtension == "jpg")
        await loader.releaseAllResources()
    }

    @Test("PageLoader は参照ファイルを読み直さない: 開いた本が持つ参照から reader を作る(actor の上でファイルを読まない)")
    func readerIsBuiltFromTheLoadedReference() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        // 開いた後で参照ファイルが無くなっても(読めば失敗する)、ページは開いた時点の参照で読める。
        try FileManager.default.removeItem(at: fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        let image = await loader.pageImage(at: 0)
        #expect(image.flatMap { PageColorReader.number(in: $0) } == 1)
        await loader.releaseAllResources()
    }

    @Test("網越しの本では ComicInfo.xml を探さない(一覧を問い合わせない)")
    func noComicInfoLookup() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        let before = fixture.manifestRequestCount
        #expect(await loader.sourceComicInfo(bookSourceURL: book.sourceURL) == nil)
        #expect(fixture.manifestRequestCount == before)
        await loader.releaseAllResources()
    }

    @Test("サムネイルのディスクキャッシュの鍵: 渡すたびに変わる本の URL(中継の ID・ポート)では変わらず、参照ファイルのパスと manifest のページ数で決まる")
    func thumbnailKeyIgnoresBookURL() throws {
        let path = "/private/tmp/Sample Book.stacknestbook"
        // 同じ参照ファイルのパス・同じページ数で、本の URL と鍵だけが違う本(別の手渡し)。鍵は PageLoader と同じ道で作る。
        func book(relay: String, port: Int, pageCount: Int = 6, path: String = path) throws -> MangaBook {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/api/v1/relay/\(relay)"))
            let reference = try StackNestBookReference(
                version: 1, title: "t", bookURL: url, token: "token-\(relay)",
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000), pageCount: 6, direction: .rightToLeft, startPage: 0
            )
            var book = MangaBook(id: path, title: "t", sourceURL: URL(fileURLWithPath: path), pages: [])
            book.stackNestReference = reference
            book.stackNestPageCount = pageCount
            return book
        }
        func key(_ book: MangaBook) throws -> String {
            try #require(PageLoader.stackNestThumbnailDiskKey(for: book, contrastCorrectionEnabled: false, maxPixelSize: 160)).fingerprint
        }
        let first = try book(relay: "AAAAAAAA-0000-0000-0000-000000000001", port: 51234)
        let second = try book(relay: "BBBBBBBB-0000-0000-0000-000000000002", port: 51999)
        #expect(first.stackNestReference?.bookURL != second.stackNestReference?.bookURL)
        #expect(try key(first) == key(second))
        // manifest のページ数が変われば別の鍵(参照ファイルに書かれたページ数ではなく)。
        #expect(try key(first) != key(book(relay: "AAAAAAAA-0000-0000-0000-000000000001", port: 51234, pageCount: 7)))
        #expect(try key(first) != key(book(relay: "AAAAAAAA-0000-0000-0000-000000000001", port: 51234, path: "/private/tmp/Other Book.stacknestbook")))
    }

    @Test("サムネイルのディスクキャッシュは、参照ファイルが書き直された(別の鍵・別の中継の URL)本を開き直しても当たる")
    func thumbnailDiskCacheSurvivesAReopenedReference() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        // 作業フォルダの中のディスクキャッシュ(`.shared` は使わない)。注入したサムネイルのキャッシュは既定で無効なので有効にする
        // (DiskCacheInjectionTests と同じ)。
        let caches = BookDiskCaches(directory: fixture.temporary.file("caches"))
        await caches.thumbnails.configure(isEnabled: true, maxTotalBytes: 16 * 1024 * 1024, generation: 1)
        let thumbnails = caches.thumbnails
        let maxPixelSize = ImageDecoder.progressBarThumbnailMaxPixelSize

        let first = try await FixtureBook.load(fixture.referenceURL)
        let firstPageID = first.pages[0].id
        let firstKey = try #require(
            PageLoader.stackNestThumbnailDiskKey(for: first, contrastCorrectionEnabled: false, maxPixelSize: maxPixelSize)
        )
        let writer = PageLoader(book: first, usesThumbnailDiskCache: true, diskCaches: caches)
        let made = try #require(await writer.thumbnail(at: 0))
        #expect(PageColorReader.number(in: made) == 1)
        // 書き込みは待たない作り(PageLoader.thumbnail(at:))なので、見えるまで待つ。PageLoader が参照ファイルの属性で鍵を
        // 作っていれば、ここで別の鍵に書かれていて見えない。
        #expect(await eventually { await thumbnails.hasThumbnail(bookKey: firstKey, pageID: firstPageID) })
        await writer.releaseAllResources()

        // StackNest が開き直したときと同じく、同じパスへ別の鍵・別の中継の URL で書き直す(更新日時と大きさが変わる。鍵の
        // 長さを変えて大きさも確かに変える)。見立ては宛先のホストを見ずに道で応えるので、ポートだけを変える。
        var components = try #require(URLComponents(url: fixture.server.bookURL, resolvingAgainstBaseURL: false))
        components.port = 51999
        let relayedURL = try #require(components.url)
        try fixture.writeReference(
            token: "test-token-reopened-0123456789abcdef", pageCount: 3, startPage: 0, bookURL: relayedURL
        )
        // 開き直しは新しい URL の値で(アプリでも開くたびに別の値が来る)。URL は問い合わせた属性を覚えているので、同じ値を
        // 使い回すと、参照ファイルの属性で鍵を作る道でも書き直しが見えず、ディスクのサムネイルが当たってしまう。
        let reopened = try await FixtureBook.load(URL(fileURLWithPath: fixture.referenceURL.path))
        #expect(reopened.stackNestReference?.bookURL != first.stackNestReference?.bookURL)
        #expect(reopened.pages[0].id == firstPageID)
        let reopenedKey = try #require(
            PageLoader.stackNestThumbnailDiskKey(for: reopened, contrastCorrectionEnabled: false, maxPixelSize: maxPixelSize)
        )
        #expect(await thumbnails.hasThumbnail(bookKey: reopenedKey, pageID: firstPageID))

        // 開き直した本の PageLoader も、StackNest に取りに行かずディスクから返す(0 番の応答を断っておく)。
        fixture.server.respond(.page(0), with: .status(404))
        let reader = PageLoader(book: reopened, usesThumbnailDiskCache: true, diskCaches: caches)
        let fromDisk = await reader.thumbnail(at: 0)
        #expect(fromDisk.flatMap { PageColorReader.number(in: $0) } == 1)
        await reader.releaseAllResources()
    }
}
