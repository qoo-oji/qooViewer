import Foundation
import Testing

@testable import qooViewer

/// 「これから1冊として開く対象」の正規化(Services/BookOpenRequest.swift)。
///
/// Finder / Dock / ドロップ / NSOpenPanel の4経路がすべてこの1つのイニシャライザを通る前提で、
/// 分類ルール(全部画像で2件以上なら1冊、それ以外は先頭だけ)と正規化(重複除去+自然順)が
/// 決まっている。正規化が崩れると、`WindowGroup(id:value:)` の重複防止(同じ選択は同じ値)が
/// 効かなくなり、同じ本のウインドウが際限なく開きうる(型コメント参照)。
struct BookOpenRequestTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: - 分類

    @Test("画像が2件以上なら、まとめて1冊になる")
    func multipleImagesBecomeOneBook() throws {
        let request = try #require(BookOpenRequest(
            openingCandidates: [url("/books/002.jpg"), url("/books/001.jpg")]
        ))
        #expect(request.urls.count == 2)
        #expect(request.bundlesMultipleImages)
        #expect(request.opensImageFiles)
    }

    @Test("画像以外が混ざっていたら、先頭の1つだけを開く")
    func mixedSelectionOpensOnlyTheFirst() throws {
        // 書庫を複数選んだときにウインドウが大量に開くのを避けるための、意図的な仕様。
        let request = try #require(BookOpenRequest(
            openingCandidates: [url("/books/a.cbz"), url("/books/001.jpg")]
        ))
        #expect(request.urls == [url("/books/a.cbz")])
        #expect(!request.bundlesMultipleImages)
        #expect(!request.opensImageFiles)
    }

    @Test("書庫を複数選んでも、開くのは先頭だけ")
    func multipleArchivesOpenOnlyTheFirst() throws {
        let request = try #require(BookOpenRequest(
            openingCandidates: [url("/books/b.cbz"), url("/books/a.cbz")]
        ))
        // 並べ替えもしない ―― 先頭は「渡された順の先頭」。
        #expect(request.urls == [url("/books/b.cbz")])
    }

    @Test("1件だけなら、画像でもそのまま1件")
    func singleCandidateStaysSingle() throws {
        let request = try #require(BookOpenRequest(openingCandidates: [url("/books/001.jpg")]))
        #expect(request.urls == [url("/books/001.jpg")])
        #expect(request.opensImageFiles)
        #expect(!request.bundlesMultipleImages)
    }

    @Test("候補が空なら nil")
    func emptyCandidatesGiveNil() {
        #expect(BookOpenRequest(openingCandidates: []) == nil)
    }

    // MARK: - 正規化

    @Test("同じファイルが2回渡されても1ページにする")
    func duplicatesAreRemoved() throws {
        let request = try #require(BookOpenRequest(
            openingCandidates: [url("/books/001.jpg"), url("/books/002.jpg"), url("/books/001.jpg")]
        ))
        #expect(request.urls == [url("/books/001.jpg"), url("/books/002.jpg")])
    }

    @Test("重複を除いて1件になったら、複数枚扱いにはしない")
    func deduplicatingDownToOneFallsBackToASingleBook() throws {
        let request = try #require(BookOpenRequest(
            openingCandidates: [url("/books/001.jpg"), url("/books/001.jpg")]
        ))
        #expect(request.urls == [url("/books/001.jpg")])
        #expect(!request.bundlesMultipleImages)
    }

    @Test("渡された順ではなく、必ず自然順(フォルダごと・数字は数値)に並べ直す")
    func urlsAreSortedInNaturalOrder() throws {
        let request = try #require(BookOpenRequest(openingCandidates: [
            url("/books/vol2/001.jpg"), url("/books/vol1/010.jpg"),
            url("/books/vol1/009.jpg"), url("/books/vol1/002.jpg"),
        ]))
        #expect(request.urls.map(\.path) == [
            "/books/vol1/002.jpg", "/books/vol1/009.jpg", "/books/vol1/010.jpg",
            "/books/vol2/001.jpg",
        ])
    }

    @Test("同じ選択は、渡された順が違っても等値になる")
    func theSameSelectionAlwaysGivesTheSameValue() throws {
        // ここが崩れると `openWindow(id:value:)` の重複防止(最後の砦)が効かなくなる。
        let a = try #require(BookOpenRequest(
            openingCandidates: [url("/books/001.jpg"), url("/books/002.jpg")]
        ))
        let b = try #require(BookOpenRequest(
            openingCandidates: [url("/books/002.jpg"), url("/books/001.jpg")]
        ))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Codable で往復しても同じ値")
    func codableRoundTrip() throws {
        let request = try #require(BookOpenRequest(
            openingCandidates: [url("/books/001.jpg"), url("/books/002.jpg")]
        ))
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(BookOpenRequest.self, from: data) == request)
    }

    // MARK: - 上限

    @Test("上限ちょうどは超えていない、1件多いと超えている")
    func imageSelectionLimitIsExclusive() throws {
        // セキュリティスコープの拡張を使い果たすとアプリ全体が壊れるため、開く前に必ず見る値。
        let limit = BookOpenRequest.maxImageSelectionCount
        let atLimit = try #require(BookOpenRequest(
            openingCandidates: (0..<limit).map { url("/books/\(String(format: "%05d", $0)).jpg") }
        ))
        #expect(atLimit.urls.count == limit)
        #expect(!atLimit.exceedsImageSelectionLimit)

        let overLimit = try #require(BookOpenRequest(
            openingCandidates: (0...limit).map { url("/books/\(String(format: "%05d", $0)).jpg") }
        ))
        #expect(overLimit.urls.count == limit + 1)
        #expect(overLimit.exceedsImageSelectionLimit)
    }

    // MARK: - その他

    @Test("URL 1つの初期化は、履歴に残すかどうかだけを選べる")
    func singleURLInitializer() {
        #expect(BookOpenRequest(url("/books/a.cbz")).recordsInHistory)
        #expect(!BookOpenRequest(url("/books/a.cbz"), recordsInHistory: false).recordsInHistory)
        // 履歴に残すかどうかが違えば別の値(ウインドウの重複判定もそれに従う)。
        #expect(BookOpenRequest(url("/books/a.cbz")) != BookOpenRequest(url("/books/a.cbz"), recordsInHistory: false))
    }

    @Test("primaryURL は先頭の URL")
    func primaryURLIsTheFirst() throws {
        let request = try #require(BookOpenRequest(
            openingCandidates: [url("/books/002.jpg"), url("/books/001.jpg")]
        ))
        #expect(request.primaryURL == url("/books/001.jpg"))
    }
}
