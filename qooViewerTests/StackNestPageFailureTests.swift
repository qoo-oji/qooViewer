import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

@testable import qooViewer

/// 恒久的な失敗(StackNest で施錠を変えた・鍵が取り消された・本が無い など)の後に、ページの要求を繰り返さず、理由を知らせる。
/// これが無いと、施錠を変えた後にキャッシュに無いページが真っ黒のまま案内が無く、ページを送るたびに 1 枚につき寸法・表示・
/// 先読み・サムネイルの要求が重なって出る(すべて 403)。
struct StackNestPageFailureTests {
    private static let locked: StackNestViewerKitTesting.StackNestStubServer.Response =
        .status(403, headers: ["X-Library-Locked": "1"])
    /// StackNest が開き直したときの新しい鍵。
    private static let renewedToken = "renewed-token-0123456789"

    @Test("恒久的な失敗(施錠の 403)の後は、ほかのページも manifest も問い合わせずに同じ失敗を返す(同じ本の reader すべて)")
    func permanentFailureStopsFurtherRequests() async throws {
        let fixture = try StackNestTestBook(pageCount: 6)
        defer { fixture.close() }
        fixture.server.respond(.page(1), with: Self.locked)
        let reader = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        await #expect(throws: StackNestViewerError(.libraryLocked)) {
            try await FileIO.perform { try reader.data(at: "000001.jpg") }
        }
        #expect(reader.book.permanentFailure == StackNestViewerError(.libraryLocked))
        await #expect(throws: StackNestViewerError(.libraryLocked)) {
            try await FileIO.perform { try reader.data(at: "000002.jpg") }
        }
        await #expect(throws: StackNestViewerError(.libraryLocked)) {
            try await FileIO.perform { try reader.manifest(refresh: true) }
        }
        // 同じ参照ファイルから作ったほかの reader(サムネイル・レイアウトの編集)も問い合わせない。
        let other = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        await #expect(throws: StackNestViewerError(.libraryLocked)) {
            try await FileIO.perform { try other.data(at: "000003.jpg") }
        }
        #expect(fixture.pageRequestIndices == [1])
        #expect(fixture.manifestRequestCount == 0)
    }

    @Test("一時的な失敗(500・つながらない)では止めない: 同じページを次に読むときは問い合わせ直す")
    func transientFailureDoesNotStop() async throws {
        let fixture = try StackNestTestBook(pageCount: 6)
        defer { fixture.close() }
        fixture.server.respond(.page(1), with: .status(500))
        fixture.server.respond(.page(2), with: .failure(.cannotConnectToHost))
        let reader = try StackNestReferenceReader(referenceFileURL: fixture.referenceURL)
        await #expect(throws: StackNestViewerError(.httpStatus, statusCode: 500)) {
            try await FileIO.perform { try reader.data(at: "000001.jpg") }
        }
        await #expect(throws: StackNestViewerError(.cannotConnect)) {
            try await FileIO.perform { try reader.data(at: "000002.jpg") }
        }
        #expect(reader.book.permanentFailure == nil)
        fixture.setPageCount(6)
        fixture.server.respond(
            .page(1), with: .status(200, headers: ["Content-Type": "image/png"], body: PageImageFactory.png(number: 2))
        )
        let data = try await FileIO.perform { try reader.data(at: "000001.jpg") }
        #expect(PageColorReader.matches(data, number: 2))
        #expect(fixture.pageRequestIndices == [1, 2, 1])
    }

    @Test("ビューア: 一時的な失敗(500)で読めないページでは知らせを出さない(次にそのページへ来たら問い合わせ直す)")
    @MainActor
    func transientPageFailureShowsNoNotice() async throws {
        let fixture = try StackNestTestBook(pageCount: 8, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.prefetchPageCount = 0
        let viewer = await harness.open(try await FixtureBook.load(fixture.referenceURL))
        fixture.server.respond(.page(6), with: .status(500))
        viewer.jump(toPageIndex: 6)
        await viewer.settle()
        #expect(viewer.stackNestNotice == nil)
        #expect(viewer.stackNestBook?.permanentFailure == nil)
        let before = fixture.pageRequestIndices.filter { $0 == 6 }.count
        viewer.jump(toPageIndex: 0)
        await viewer.settle()
        viewer.jump(toPageIndex: 6)
        await viewer.settle()
        #expect(fixture.pageRequestIndices.filter { $0 == 6 }.count > before)
    }

    @Test("ビューア: 施錠が変わった後は、読めないページを真っ黒のままにせず解錠の案内を 1 度だけ出し、ページを送っても問い合わせない")
    @MainActor
    func lockChangeShowsTheKitMessageOnceAndStopsRetrying() async throws {
        let fixture = try StackNestTestBook(pageCount: 8, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.prefetchPageCount = 2
        let viewer = await harness.open(try await FixtureBook.load(fixture.referenceURL))
        #expect(viewer.stackNestNotice == nil)
        // StackNest でライブラリの施錠が変わった: 以後、どのページも 403 + X-Library-Locked。
        for index in 0..<8 { fixture.server.respond(.page(index), with: Self.locked) }
        viewer.jump(toPageIndex: 5)
        await viewer.settle()
        let expected = StackNestText.message(
            for: StackNestViewerError(.libraryLocked), locale: harness.preferences.effectiveLocale
        )
        let notice = try #require(viewer.stackNestNotice)
        #expect(notice.message == expected)
        #expect(viewer.currentImages.isEmpty)
        let requestsAfterTheFirstFailure = fixture.pageRequestIndices.count
        // さらにページを送る: 問い合わせは増えず、同じ案内を出し直さない。
        viewer.jump(toPageIndex: 3)
        await viewer.settle()
        viewer.jump(toPageIndex: 6)
        await viewer.settle()
        #expect(fixture.pageRequestIndices.count == requestsAfterTheFirstFailure)
        #expect(viewer.stackNestNotice == notice)
    }

    @Test("同じ恒久的な失敗は、ページが先でも位置の書き戻しが先でも、知らせを 1 度だけ出す(種類ごとの 1 度)")
    @MainActor
    func samePermanentFailureIsShownOnceAcrossNoticeKinds() async throws {
        for pageFirst in [true, false] {
            let fixture = try StackNestTestBook(pageCount: 8, startPage: 0)
            defer { fixture.close() }
            let harness = try ViewerHarness()
            defer { harness.close() }
            harness.preferences.prefetchPageCount = 0
            let viewer = await harness.open(try await FixtureBook.load(fixture.referenceURL))
            fixture.server.respond(.progress, with: Self.locked)

            func lockPages() {
                for index in 0..<8 { fixture.server.respond(.page(index), with: Self.locked) }
            }
            func readPage() async {
                viewer.jump(toPageIndex: 5)
                await viewer.settle()
            }
            func reportPosition() async {
                viewer.flushPendingSave()
                await viewer.stackNestProgress?.waitUntilIdle()
            }
            if pageFirst {
                lockPages()
                await readPage()
            } else {
                // 書き戻しが先に見る順序を固定する: ページが読めるうちに 1 ページ進め(書き戻しはまとめ待ちに入る)、
                // 書き戻しが失敗してから、ページも施錠する。ページはまだ失敗していないので、記録したのは書き戻しの役。
                viewer.jump(toPageIndex: 1)
                await viewer.settle()
                #expect(viewer.stackNestBook?.permanentFailure == nil)
                await reportPosition()
                #expect(viewer.stackNestBook?.permanentFailure == StackNestViewerError(.libraryLocked))
                lockPages()
            }
            let first = try #require(viewer.stackNestNotice)
            if pageFirst {
                await reportPosition()
            } else {
                await readPage()
            }
            #expect(viewer.currentImages.isEmpty)
            // 後から来た同じ種類の失敗は、知らせを出し直さない(出し直すと別の id の知らせになる)。
            #expect(viewer.stackNestNotice == first)
        }
    }

    @Test("ビューア: 位置の書き戻しだけが恒久的な失敗を見たときも本に記録し、ページはもう 1 度失敗させずに問い合わせをやめる")
    @MainActor
    func reporterFailureIsRecordedOnTheBook() async throws {
        let fixture = try StackNestTestBook(pageCount: 8, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.prefetchPageCount = 0
        let viewer = await harness.open(try await FixtureBook.load(fixture.referenceURL))
        // 読んだページがキャッシュから出ている間に StackNest で施錠が変わった: 位置の書き戻しが先に 403 を受ける。
        fixture.server.respond(.progress, with: Self.locked)
        viewer.jump(toPageIndex: 1)
        await viewer.settle()
        viewer.flushPendingSave()
        await viewer.stackNestProgress?.waitUntilIdle()
        let notice = try #require(viewer.stackNestNotice)
        #expect(viewer.stackNestBook?.permanentFailure == StackNestViewerError(.libraryLocked))
        for index in 0..<8 { fixture.server.respond(.page(index), with: Self.locked) }
        // まだ読んでいないページ(開いたときと 1 ページ目の寸法の下調べの外)へ送る: 問い合わせずに止まる。
        viewer.jump(toPageIndex: 6)
        await viewer.settle()
        #expect(!fixture.pageRequestIndices.contains(6))
        #expect(viewer.currentImages.isEmpty)
        #expect(viewer.stackNestNotice == notice)
    }

    @Test("ウインドウのビューアを作り直す単位(viewerIdentity): 同じパスでも参照(鍵)が替われば別の本、並べ替え・除外で中身だけ変わった本は同じ本")
    @MainActor
    func viewerIdentityTellsAReopenedReferenceApart() async throws {
        let fixture = try StackNestTestBook(pageCount: 6)
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        var reordered = book
        reordered.pages.reverse()
        #expect(reordered.viewerIdentity == book.viewerIdentity)
        try fixture.writeReference(token: Self.renewedToken, pageCount: 6, startPage: 2)
        let reopened = try await FixtureBook.load(fixture.referenceURL)
        #expect(reopened.id == book.id)
        #expect(reopened.viewerIdentity != book.viewerIdentity)
        // 参照ファイルの本でなければ、パスだけで決まる(以前の `.id(book.id)` と同じ)。
        var plain = book
        plain.stackNestReference = nil
        var plainReopened = reopened
        plainReopened.stackNestReference = nil
        #expect(plain.viewerIdentity == plainReopened.viewerIdentity)
    }

    @Test("ビューア: 恒久的な失敗の後に StackNest から開き直すと(同じパス・新しい鍵)、同じウインドウでも新しいセッションで読み直し、次の恒久的な失敗もまた知らせる")
    @MainActor
    func reopeningFromStackNestInTheSameWindowStartsOver() async throws {
        let fixture = try StackNestTestBook(pageCount: 8, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.prefetchPageCount = 0
        // ContentView と同じく、ウインドウに出す本は ViewerHandoff が受け渡す(AppState.currentBook が替わるたびに update)。
        let handoff = ViewerHandoff()
        defer { handoff.discardPending() }
        func show(_ book: MangaBook) async throws -> ViewerViewModel {
            var made: ViewerViewModel?
            handoff.update(to: book) { book in
                let viewer = harness.makeViewer(book)
                made = viewer
                return viewer
            }
            // 新しいビューモデルを作ったなら、最初の見開きが揃って(ウインドウに出て)から。
            if let made { await made.settle() }
            return try #require(handoff.shown?.model)
        }
        let first = try await show(try await FixtureBook.load(fixture.referenceURL))
        // StackNest でライブラリの施錠が変わった: ページが読めず、案内が出て、この本への問い合わせは止まる。
        for index in 0..<8 { fixture.server.respond(.page(index), with: Self.locked) }
        first.jump(toPageIndex: 5)
        await first.settle()
        let firstNotice = try #require(first.stackNestNotice)
        #expect(first.stackNestBook?.permanentFailure == StackNestViewerError(.libraryLocked))

        // 案内のとおり解錠して StackNest から開き直す: StackNest は同じパスへ新しい鍵で参照ファイルを書き直し、本を
        // 表示しているウインドウ(既定の「今のウインドウで開く」)がその本を読み込み直す(AppState.open → currentBook)。
        for index in 0..<8 {
            fixture.server.respond(
                .page(index),
                with: .status(200, headers: ["Content-Type": "image/png"], body: PageImageFactory.png(number: UInt8(index + 1)))
            )
        }
        try fixture.writeReference(token: Self.renewedToken, pageCount: 8, startPage: 5)
        let reopened = try await FixtureBook.load(fixture.referenceURL)
        #expect(reopened.id == first.book.id)
        let requestsBeforeReopening = fixture.requests.count
        let viewer = try await show(reopened)

        // 新しい鍵のセッションで、参照ファイルの startPage から読み直す。前の本の失敗の記録・止まった書き戻しの役・
        // 「1 度だけ」の控えは引き継がない。
        #expect(viewer.stackNestBook?.reference.token == Self.renewedToken)
        #expect(viewer.stackNestBook?.permanentFailure == nil)
        #expect(viewer.stackNestProgress?.isStopped == false)
        #expect(viewer.stackNestNotice == nil)
        #expect(!viewer.currentImages.isEmpty)
        #expect(viewer.book.pages[viewer.currentIndex].sortKey == "000005.jpg")
        let pageRequests = fixture.requests.dropFirst(requestsBeforeReopening).filter {
            if case .page = $0.route { return true }
            return false
        }
        #expect(!pageRequests.isEmpty)
        #expect(pageRequests.allSatisfy { $0.carriesExpectedToken })

        // 後でまた施錠が変わったら、その失敗も知らせる(前の本の「1 度だけ」に抑えられない)。
        for index in 0..<8 { fixture.server.respond(.page(index), with: Self.locked) }
        viewer.jump(toPageIndex: 0)
        await viewer.settle()
        let notice = try #require(viewer.stackNestNotice)
        #expect(notice != firstNotice)
        #expect(
            notice.message
                == StackNestText.message(for: StackNestViewerError(.libraryLocked), locale: harness.preferences.effectiveLocale)
        )
        #expect(viewer.currentImages.isEmpty)
    }

    @Test("ビューアを作り直す単位(ViewerHandoff.viewIdentity): シークレットフォルダかだけ違う本も、参照(鍵)だけ違う本も別の本、並べ替え・除外で中身だけ変わった本(prepareBook の後)は同じ本")
    @MainActor
    func viewIdentityCombinesTheSecretFolderFlagAndTheReference() async throws {
        let fixture = try StackNestTestBook(pageCount: 4)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.prefetchPageCount = 0
        let book = try await FixtureBook.load(fixture.referenceURL)

        // 同じパス・同じ参照で、シークレットフォルダかだけが違う(ビューモデルの skipsPersistence は作るときに決まる)。
        var secret = book
        secret.isInSecretFolder = true
        #expect(secret.stackNestReference == book.stackNestReference)
        #expect(ViewerHandoff.viewIdentity(of: secret) != ViewerHandoff.viewIdentity(of: book))

        // 並べ替え・除外で中身だけ変わった本(prepareBook の後)は同じ本: パス・シークレットフォルダの印・参照を引き継ぐ。
        let keys = secret.pages.map(\.sortKey)
        harness.library.layouts.setPageLayoutState(for: secret, pageKey: keys[1], state: .excluded)
        harness.library.layouts.setPageOrderOverride(for: secret, [keys[3], keys[2], keys[1], keys[0]])
        let viewer = await harness.open(secret, skipsPersistence: true)
        #expect(viewer.book.pages.map(\.sortKey) == [keys[3], keys[2], keys[0]])
        #expect(ViewerHandoff.viewIdentity(of: viewer.book) == ViewerHandoff.viewIdentity(of: secret))

        // 同じパス・同じシークレットフォルダの印で、参照(鍵)だけが違う(StackNest から開き直した)。
        try fixture.writeReference(token: Self.renewedToken, pageCount: 4, startPage: 0)
        let reopened = try await FixtureBook.load(URL(fileURLWithPath: fixture.referenceURL.path))
        #expect(reopened.id == book.id)
        #expect(reopened.isInSecretFolder == book.isInSecretFolder)
        #expect(reopened.stackNestReference != book.stackNestReference)
        #expect(ViewerHandoff.viewIdentity(of: reopened) != ViewerHandoff.viewIdentity(of: book))
    }
}
