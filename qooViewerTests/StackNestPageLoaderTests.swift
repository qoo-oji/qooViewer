import CoreGraphics
import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

@testable import qooViewer

/// 参照ファイルの本を PageLoader で読む。網越しの読み出しが actor(協調スレッド)もデコードの枠も塞がないこと、寸法と
/// 表示で同じページを 2 度取らないこと、ComicInfo.xml を探しに行かないこと、取り寄せの同時数の門(StackNestRequestGate)、
/// サムネイルをディスクに残さないこと、リソースモニタへの届け出を固定する。
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

    @Test("シークバーのサムネイルも網越しの読み出しを async の口で待つ(部品の同期の読み手は、メインスレッド・Task の中では Debug で止まる)")
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

    @Test("参照ファイルの本のサムネイルはディスクに残さない(鍵を掛けられるライブラリの絵を、施錠や期限と関係なく残さない)")
    func noThumbnailDiskCache() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        // 作業フォルダの中のディスクキャッシュ(`.shared` は使わない)を有効にしておく(DiskCacheInjectionTests と同じ)。
        let caches = BookDiskCaches(directory: fixture.temporary.file("caches"))
        await caches.thumbnails.configure(isEnabled: true, maxTotalBytes: 16 * 1024 * 1024, generation: 1)
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: true, diskCaches: caches)
        let thumbnail = await loader.thumbnail(at: 0)
        #expect(thumbnail.flatMap { PageColorReader.number(in: $0) } == 1)
        // 書き込みは待たない作りなので、少し待ってから何も書かれていないことを見る。
        try await Task.sleep(for: .milliseconds(300))
        #expect(await caches.thumbnails.totalBytes() == 0)
        await loader.releaseAllResources()
    }

    @Test("先読み・サムネイル・寸法の取り寄せは、本ごとに同時 4 件まで(残りはスレッドを塞がずに門で待つ)")
    func backgroundFetchesAreLimited() async throws {
        let fixture = try StackNestTestBook(pageCount: 8)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        let gates = (0..<8).map { fixture.holdPage($0) }
        defer { gates.forEach { $0.open() } }
        let thumbnails = (0..<8).map { index in Task { await loader.thumbnail(at: index) } }
        let reference = try #require(book.stackNestReference)
        let shared = try StackNestSessions.shared.book(for: reference, at: book.sourceURL)
        #expect(await Self.waitUntil { shared.gate.waiterCount(.background) == 4 })
        #expect(shared.gate.inUseCount(.background) == StackNestRequestGate.backgroundLimit)
        // 門を通った 4 件だけが見立てに届く。
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.pageRequestIndices.count == 4)
        gates.forEach { $0.open() }
        for task in thumbnails { _ = await task.value }
        #expect(Set(fixture.pageRequestIndices) == Set(0..<8))
        #expect(shared.gate.inUseCount(.background) == 0)
        await loader.releaseAllResources()
    }

    @Test("サムネイル・寸法を待つ人が全員取り消したら、門で待っている取り寄せも取り消す(ページ一覧を流し読みしても全ページを取りに行かない)")
    func cancelledThumbnailsLeaveTheGate() async throws {
        let fixture = try StackNestTestBook(pageCount: 12)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        let gates = (0..<12).map { fixture.holdPage($0) }
        defer { gates.forEach { $0.open() } }
        let reference = try #require(book.stackNestReference)
        let shared = try StackNestSessions.shared.book(for: reference, at: book.sourceURL)
        // 8 枚のサムネイルと 2 枚の寸法を頼む(門の背景の枠は 4。残りは門で待つ)。
        let thumbnails = (0..<8).map { index in Task { await loader.thumbnail(at: index) } }
        let sizes = (8..<10).map { index in Task { await loader.pageSize(at: index) } }
        #expect(await Self.waitUntil { shared.gate.waiterCount(.background) == 6 })
        // セルが画面から消えた(呼び出し側の取り消し)。
        thumbnails.forEach { $0.cancel() }
        sizes.forEach { $0.cancel() }
        // 門で待っていた分は抜ける。飛んでいた 4 件も部品の要求ごと取り消される。
        #expect(await Self.waitUntil { shared.gate.waiterCount(.background) == 0 })
        #expect(await Self.waitUntil { shared.gate.inUseCount(.background) == 0 })
        for task in thumbnails { #expect(await task.value == nil) }
        for task in sizes { #expect(await task.value == nil) }
        // 届いた要求は、最初に門を通った 4 件だけ。
        #expect(fixture.pageRequestIndices.count <= StackNestRequestGate.backgroundLimit)
        // 対照: 待つ人が残っていれば取り消さない(同じページを 2 人が待ち、1 人だけ取り消す)。
        let kept = Task { await loader.thumbnail(at: 11) }
        let dropped = Task { await loader.thumbnail(at: 11) }
        #expect(await Self.waitUntil { fixture.pageRequestIndices.contains(11) })
        dropped.cancel()
        try await Task.sleep(for: .milliseconds(100))
        gates[11].open()
        #expect(await kept.value != nil)
        await loader.releaseAllResources()
    }

    @Test("背景の取り寄せが止まって門を埋めていても、表示のページは表示の列で取り寄せる")
    func displayIsNotStuckBehindBackgroundFetches() async throws {
        let fixture = try StackNestTestBook(pageCount: 8)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        let gates = (0..<6).map { fixture.holdPage($0) }
        defer { gates.forEach { $0.open() } }
        let thumbnails = (0..<6).map { index in Task { await loader.thumbnail(at: index) } }
        let reference = try #require(book.stackNestReference)
        let shared = try StackNestSessions.shared.book(for: reference, at: book.sourceURL)
        #expect(await Self.waitUntil { shared.gate.inUseCount(.background) == StackNestRequestGate.backgroundLimit })
        var waited = false
        let display = Task { await loader.pageImage(at: 7).flatMap { PageColorReader.number(in: $0) } }
        do {
            _ = try await FileIO.withDeadline(.seconds(3)) { await display.value }
        } catch {
            waited = true
        }
        gates.forEach { $0.open() }
        for task in thumbnails { _ = await task.value }
        #expect(!waited, "背景の取り寄せの後ろで表示のページが待った")
        #expect(await display.value == 8)
        await loader.releaseAllResources()
    }

    @Test("先読みに合流した表示要求は、背景の列が埋まっていても表示の列で取り寄せる(先読みが門に並ぶ前の合流でも、並んだ後でも)")
    func displayJoiningBeforeTheGateUsesTheDisplayLane() async throws {
        let fixture = try StackNestTestBook(pageCount: 16)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        let gates = (0..<16).map { fixture.holdPage($0) }
        defer { gates.forEach { $0.open() } }
        let reference = try #require(book.stackNestReference)
        let shared = try StackNestSessions.shared.book(for: reference, at: book.sourceURL)
        // 背景の列を埋める(止めたサムネイル 4 件が門を通り、2 件が門で待つ)。
        let thumbnails = (0..<6).map { index in Task { await loader.thumbnail(at: index) } }
        #expect(await Self.waitUntil { shared.gate.waiterCount(.background) == 2 })
        // ビューアと同じ順(StackNest の本は表示の前に先読みを始める ―― ViewerViewModel.loadCurrentSpread)。表示要求は 8 番の
        // 先読みの読み込みへ合流する。その読み込みが門に並ぶ前に合流したか(acquire の時に表示の列を選ぶ)、並んだ後か(promote)は
        // actor の順番しだいで、ここでは選べない(2026-10-19 の実機の計測では前者で、表示するページが背景の列で 0.9 秒待っていた)。
        // どちらでも表示の列で通ることを押さえる。
        let display = Task {
            await loader.prefetch(around: 8, radius: 6)
            return await loader.pageImage(at: 8).flatMap { PageColorReader.number(in: $0) }
        }
        // 背景の列のまま並んだら、止めたサムネイルが終わるまで 8 番は届かない。
        #expect(await Self.waitUntil { fixture.pageRequestIndices.contains(8) }, "表示するページが、先読みとして背景の列で待った")
        gates.forEach { $0.open() }
        for task in thumbnails { _ = await task.value }
        #expect(await display.value == 9)
        #expect(await Self.waitUntil { await !loader.isPrefetching })
        await loader.releaseAllResources()
    }

    @Test("表示のページも、待つ人が全員取り消したら取り寄せを取り消す(続けて飛んでも、通り過ぎたページが門の枠を握らない)")
    func cancelledDisplayLeavesTheGate() async throws {
        let fixture = try StackNestTestBook(pageCount: 6)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        let gates = (0..<6).map { fixture.holdPage($0) }
        defer { gates.forEach { $0.open() } }
        let reference = try #require(book.stackNestReference)
        let shared = try StackNestSessions.shared.book(for: reference, at: book.sourceURL)
        let displays = (0..<3).map { index in Task { await loader.pageImage(at: index) } }
        #expect(await Self.waitUntil { fixture.pageRequestIndices.count == 3 })
        #expect(shared.gate.inUseCount(.display) == 3)
        // 別のページへ飛んだ(ビューアは前の表示の要求を取り消す)。応答は止めたまま。
        displays.forEach { $0.cancel() }
        #expect(await Self.waitUntil { shared.gate.inUseCount(.display) == 0 }, "取り消した表示の要求が門の枠を握ったまま")
        for task in displays { #expect(await task.value == nil) }
        // 対照: 先読みも同じページを待っていれば、表示の要求を取り消しても取り寄せは続く。
        await loader.prefetch(around: 4, radius: 0)
        let kept = Task { await loader.pageImage(at: 4) }
        #expect(await Self.waitUntil { fixture.pageRequestIndices.contains(4) })
        kept.cancel()
        try await Task.sleep(for: .milliseconds(100))
        gates[4].open()
        #expect(await Self.waitUntil { await loader.cachedPageImage(at: 4) != nil })
        await loader.releaseAllResources()
    }

    @Test("リソースモニタ: 部品が持つ直近のページを、同じセッションを使う PageLoader のうち 1 つだけが届ける")
    func memoryItemsAreReportedOnce() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let first = PageLoader(book: book, usesThumbnailDiskCache: false)
        let second = PageLoader(book: book, usesThumbnailDiskCache: false)
        _ = await first.pageImage(at: 0)
        _ = await second.pageImage(at: 1)
        let firstItems = await first.memoryUsageItems().filter { $0.kind == .stackNestPages }
        let secondItems = await second.memoryUsageItems().filter { $0.kind == .stackNestPages }
        #expect(firstItems.count + secondItems.count == 1)
        let item = try #require((firstItems + secondItems).first)
        #expect(item.count == 2)
        #expect(item.usedBytes > 0)
        // 届けていた側が手放したら、もう一方が届ける。
        let reporter = firstItems.isEmpty ? second : first
        let other = firstItems.isEmpty ? first : second
        await reporter.releaseAllResources()
        #expect(await other.memoryUsageItems().filter { $0.kind == .stackNestPages }.count == 1)
        await other.releaseAllResources()
    }

    @Test("手放した後の PageLoader は、参照ファイルの本の reader を作り直さない(セッションを握り直さない)")
    func releasedLoaderDoesNotRecreateTheReader() async throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        await loader.releaseAllResources()
        #expect(try await loader.exportableImage(at: 0) == nil)
        #expect(await loader.pageSize(at: 1) == nil)
        #expect(fixture.pageRequestIndices.isEmpty)
    }
}
