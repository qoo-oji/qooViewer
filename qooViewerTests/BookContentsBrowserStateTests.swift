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
}
