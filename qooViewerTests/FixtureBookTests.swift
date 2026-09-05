import Foundation
import Testing

@testable import qooViewer

/// コミット済みの本のフィクスチャ(qooViewerTests/Fixtures/)を BookLoader で開き、台帳(manifest.json)の
/// 期待と突き合わせる。
///
/// golden は `PageRef.sortKey` の列。DB の pageKey(ブックマーク・レイアウト・読書位置)がこの文字列で
/// ページを指すため(docs/04「ページの識別子」)、ここが動いたら必ず気付きたい。フィクスチャの増やし方は
/// docs/02「テストのフィクスチャ」。
struct FixtureBookTests {
    @Test("台帳に載っている本は、台帳どおりに開ける", arguments: Fixtures.bookPaths)
    func committedBookMatchesManifest(path: String) async throws {
        let expectation = try #require(Fixtures.manifest.fixtures[path]?.book)
        let url = Fixtures.url(path)
        try #require(FileManager.default.fileExists(atPath: url.path), "フィクスチャがバンドルに無い: \(path)")

        if let expectedError = expectation.error {
            await expectOpenFailure(kind: expectedError, opening: url)
            return
        }

        let book = try await FixtureBook.load(url)
        #expect(book.id == url.path)
        #expect(book.sourceURL == url)
        #expect(book.title == url.deletingPathExtension().lastPathComponent)
        #expect(book.origin == .fileSystem)

        if let sortKeys = expectation.sortKeys {
            #expect(book.pages.map(\.sortKey) == sortKeys)
        }
        if let pageCount = expectation.pageCount {
            #expect(book.pages.count == pageCount)
        }
        // id は sortKey が重なる本(a.zip と a.zip/ の同居)でも一意で、本のパスを接頭辞に持つ。
        #expect(Set(book.pages.map(\.id)).count == book.pages.count)
        #expect(book.pages.allSatisfy { $0.id.hasPrefix(url.path + "#") })
        #expect(book.pages.allSatisfy { !isAppleDoubleEntry($0.sortKey) })

        let expectedOrderSource: PageOrderSource = expectation.pageOrderSource == "document" ? .document : .fileName
        #expect(book.pageOrderSource == expectedOrderSource)
        #expect(book.sourceLayoutHint == sourceLayoutHint(from: expectation.layoutHint))
    }

    /// 台帳の `error` どおりに開けないこと。`noPages` は BookLoaderError.noPages、`unreadable` はそれ以外の throw。
    private func expectOpenFailure(kind: String, opening url: URL) async {
        do {
            let book = try await FixtureBook.load(url)
            Issue.record("開けてしまった(\(book.pages.count) ページ): \(url.lastPathComponent)")
        } catch is CancellationError {
            Issue.record("中止されている: \(url.lastPathComponent)")
        } catch let error as BookLoaderError {
            if case .noPages = error {
                #expect(kind == "noPages", "noPages で失敗したが、台帳の期待は \(kind)")
            } else {
                Issue.record("想定外の BookLoaderError: \(error)")
            }
        } catch {
            #expect(kind == "unreadable", "\(type(of: error)) で失敗したが、台帳の期待は \(kind): \(error)")
        }
    }

    private func sourceLayoutHint(from hint: FixtureManifest.LayoutHint?) -> SourceLayoutHint? {
        guard let hint else { return nil }
        let direction: ReadingDirection? = switch hint.direction {
        case "rightToLeft": .rightToLeft
        case "leftToRight": .leftToRight
        default: nil
        }
        let displayMode: DisplayMode? = switch hint.displayMode {
        case "spread": .spread
        case "single": .single
        default: nil
        }
        return SourceLayoutHint(pageProgressionDirection: direction, forcedDisplayMode: displayMode)
    }
}
