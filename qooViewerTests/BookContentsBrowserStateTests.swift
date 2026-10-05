import Foundation
import Testing

@testable import qooViewer

/// サイドパネル下段(本の中身ブラウザ)の状態(ViewModels/BookContentsBrowserState.swift)のうち、画像の行のクリックの解決。
///
/// 一覧は裏で作る(`reload`)ので、行が出そろうまで待つ。
@MainActor
struct BookContentsBrowserStateTests {
    /// 一覧に `names` の行がそろうまで待つ(裏の一覧の作り直しを待つ口が無いので、期限つきで見に行く)。
    private func waitForRows(_ browser: BookContentsBrowserState, _ names: Set<String>) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !names.isSubset(of: Set(browser.entries.map(\.displayName))), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(names.isSubset(of: Set(browser.entries.map(\.displayName))), "一覧が出そろわなかった")
    }

    /// 2026-10-04 の監査 SP-4。以前は同じ「除外したページの行のクリック」が、フォルダの本では何もせず、本そのものの書庫では本を開き直し、
    /// 入れ子の書庫ではその書庫を一時コピーにして新しい本として開いていた(実測: 開いた本は古いブラウザが一時コピーを消して真っ黒になった)。
    @Test("除外したページの画像の行は、フォルダの本でも入れ子の書庫の中でも行き先が無い。今のページの行はそのページへ")
    func excludedPagesHaveNoDestinationAtAnyLevel() async throws {
        // フォルダの本。
        let temporary = try TemporaryDirectory("contents-excluded")
        let directory = temporary.file("book")
        try FixtureFolder.make(at: directory, pages: [
            .init("001.png", number: 1), .init("002.png", number: 2), .init("003.png", number: 3),
        ])
        let folderBook = try await FixtureBook.load(directory)
        let folderBrowser = try #require(await BookContentsBrowserState.make(book: folderBook))
        defer { folderBrowser.releaseResources() }
        try await waitForRows(folderBrowser, ["001.png", "002.png", "003.png"])
        let folderShown = folderBook.pages.filter { !$0.sortKey.hasSuffix("/002.png") }
        let excludedRow = try #require(folderBrowser.entries.first { $0.displayName == "002.png" })
        let keptRow = try #require(folderBrowser.entries.first { $0.displayName == "003.png" })
        #expect(folderBrowser.resolveImageClick(on: excludedRow, bookPages: folderShown) == .excludedPage)
        #expect(folderBrowser.isExcludedPage(excludedRow, bookPages: folderShown))
        #expect(folderBrowser.resolveImageClick(on: keptRow, bookPages: folderShown) == .jumpToPage(1))
        #expect(!folderBrowser.isExcludedPage(keptRow, bookPages: folderShown))

        // 書庫の中の書庫(実測した形)。
        let nestedBook = try await FixtureBook.load(fixture: "nested/nested-zip-in-zip.cbz")
        let nestedBrowser = try #require(await BookContentsBrowserState.make(book: nestedBook))
        defer { nestedBrowser.releaseResources() }
        try await waitForRows(nestedBrowser, ["ch01.cbz", "ch02.cbz"])
        let chapter = try #require(nestedBrowser.entries.first { $0.displayName == "ch01.cbz" })
        nestedBrowser.navigate(chapter)
        try await waitForRows(nestedBrowser, ["001.png", "002.png", "003.png"])
        let nestedShown = nestedBook.pages.filter { $0.sortKey != "ch01.cbz/002.png" }
        let nestedExcluded = try #require(nestedBrowser.entries.first { $0.matchKey == "ch01.cbz/002.png" })
        #expect(nestedBrowser.resolveImageClick(on: nestedExcluded, bookPages: nestedShown) == .excludedPage)
        #expect(nestedBrowser.isExcludedPage(nestedExcluded, bookPages: nestedShown))
        let nestedKept = try #require(nestedBrowser.entries.first { $0.matchKey == "ch01.cbz/003.png" })
        #expect(nestedBrowser.resolveImageClick(on: nestedKept, bookPages: nestedShown) == .jumpToPage(1))
    }

    /// 2026-10-04 の監査 SP-6。以前は踏み込みの失敗も一覧の代わりに出すエラー文にしていて、階層は動いていないのに一覧が消え、
    /// ルートでは戻る手段が無かった。
    @Test("踏み込めない行(読めない EPUB)を押しても、一覧はそのまま残り、知らせだけが出る")
    func aFailedStepInKeepsTheListing() async throws {
        let temporary = try TemporaryDirectory("contents-step-in-failure")
        let root = try FixtureFolder.make(at: temporary.file("book"), pages: [.init("001.png", number: 1)])
        var builder = EpubFixtureBuilder.pages(2)
        builder.omitContainer = true
        try builder.write(to: root.appendingPathComponent("broken.epub"))
        let book = try await FixtureBook.load(root)
        let browser = try #require(BookContentsBrowserState(book: book))
        defer { browser.releaseResources() }
        await browser.waitUntilListed()
        let broken = try #require(browser.entries.first { $0.displayName == "broken.epub" && $0.navigateTarget != nil })
        let listed = browser.entries.map(\.displayName)

        browser.navigate(broken)
        await browser.waitUntilListed()
        #expect(browser.stepInFailure != nil, "失敗を知らせていない")
        #expect(browser.navigationErrorMessage == nil, "一覧をエラー文に置き換えた")
        #expect(browser.entries.map(\.displayName) == listed)
        #expect(!browser.canGoBack)
    }

    /// 2026-10-05 の監査(範囲外の指摘)。書庫・入れ子の書庫を開くこと・入れ子の書庫の書き出しは裏で行い、走っている間は入口が断る。
    @Test("入れ子の書庫を新しい本として開くための書き出しは裏で行い、済んだら知らせる。渡さなかった一時ファイルは手放すと消える")
    func nestedArchivesAreMaterializedInTheBackground() async throws {
        let nestedBook = try await FixtureBook.load(fixture: "nested/nested-zip-in-zip.cbz")
        // 1 章目のページを本のページから外す ―― その画像の行は「本のページでもない画像」になり、押すと章の書庫を新しい本として開く。
        var partial = nestedBook
        partial.pages = nestedBook.pages.filter { !$0.sortKey.hasPrefix("ch01.cbz/") }
        let browser = try #require(await BookContentsBrowserState.make(book: partial))
        try await waitForRows(browser, ["ch01.cbz", "ch02.cbz"])
        let chapter = try #require(browser.entries.first { $0.displayName == "ch01.cbz" })
        browser.navigate(chapter)
        // 開いている最中は、もう一度押しても重ねて開かない(reader を使う仕事は一度に 1 つ)。
        browser.navigate(chapter)
        try await waitForRows(browser, ["001.png"])
        #expect(browser.canGoBack)
        let image = try #require(browser.entries.first { $0.displayName == "001.png" })

        var materialized: URL?
        let result = browser.resolveImageClick(on: image, bookPages: partial.pages) { materialized = $0 }
        #expect(result == .materializingNewBook)
        // 書き出している間は、ほかの画像の行も受け付けない。
        #expect(browser.resolveImageClick(on: image, bookPages: partial.pages) == .unavailable)
        await browser.waitUntilListed()
        let url = try #require(materialized)
        #expect(MangaBook.isTemporaryCopy(url))
        #expect(FileManager.default.fileExists(atPath: url.path))

        // 渡さなかった(開かなかった)一時ファイルは、ブラウザを手放すと消える。
        browser.releaseResources()
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("書庫を開いている最中に手放されたら、結果を当てずに捨てる")
    func releasingWhileOpeningDiscardsTheResult() async throws {
        let nestedBook = try await FixtureBook.load(fixture: "nested/nested-zip-in-zip.cbz")
        let browser = try #require(await BookContentsBrowserState.make(book: nestedBook))
        try await waitForRows(browser, ["ch01.cbz", "ch02.cbz"])
        let chapter = try #require(browser.entries.first { $0.displayName == "ch01.cbz" })
        browser.navigate(chapter)
        browser.releaseResources()
        await browser.waitUntilListed()
        #expect(browser.entries.isEmpty)
        #expect(!browser.canGoBack)
    }
}
