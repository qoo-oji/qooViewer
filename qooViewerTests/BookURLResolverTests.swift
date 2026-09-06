import Foundation
import Testing

@testable import qooViewer

/// bookID から実際に開ける URL を解決する(Services/BookURLResolver.swift)。
///
/// 3 つのストアへの問い合わせの連鎖(ブックマーク → レイアウト → メタデータ)を、メインアクターの
/// 外で回せる 1 つの関数へ写したもの。**優先順位と、素のパスへのフォールバックがどの段階で効くかを
/// 変えないこと**が写した目的そのものなので、そこを固定する。
struct BookURLResolverTests {
    private struct Fixture {
        let temporary: TemporaryDirectory
        /// 実在するフォルダ 2 つ。どちらも本として開ける形にしてある。
        let alpha: URL
        let beta: URL

        init(_ label: String) throws {
            temporary = try TemporaryDirectory(label)
            alpha = temporary.file("alpha")
            beta = temporary.file("beta")
            for url in [alpha, beta] {
                try FixtureFolder.make(at: url, pages: [.init("001.png", number: 1)])
            }
        }

        func bookmark(_ url: URL) throws -> Data {
            try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }

        /// 実在しないパス。素のパスへのフォールバックが効かない状況を作る。
        var missingPath: String { temporary.file("gone").path }
    }

    private func candidates(
        bookID: String, bookmarks: [Data] = [], layout: Data? = nil, metadata: Data? = nil
    ) -> BookURLResolver.Candidates {
        .init(bookID: bookID, bookmarkStoreBookmarks: bookmarks, layoutBookmark: layout, metadataBookmark: metadata)
    }

    // MARK: - 素のパスへのフォールバック

    @Test("候補が 1 つも無くても、bookID のパスが実在すればそれを返す")
    func aBareExistingPathIsEnough() throws {
        let fixture = try Fixture("resolver-bare")
        let url = try #require(BookURLResolver.resolvedURL(candidates(bookID: fixture.alpha.path)))
        #expect(url.path == fixture.alpha.path)
    }

    @Test("候補も無く、パスも実在しなければ nil")
    func nothingResolvesToNil() throws {
        let fixture = try Fixture("resolver-nothing")
        #expect(BookURLResolver.resolvedURL(candidates(bookID: fixture.missingPath)) == nil)
    }

    // MARK: - 優先順位

    @Test("ブックマーク側の候補が、素のパスより優先される(本が移動していても追える)")
    func aBookmarkWinsOverTheBarePath() throws {
        let fixture = try Fixture("resolver-priority")
        // bookID は alpha を指しているが、ブックマークは beta を指している。
        let resolved = try #require(BookURLResolver.resolvedURL(candidates(
            bookID: fixture.alpha.path, bookmarks: [try fixture.bookmark(fixture.beta)]
        )))
        #expect(resolved.path == fixture.beta.path)
    }

    @Test("ブックマーク側は複数を順に試し、最初に解決できたものを使う")
    func theFirstResolvableBookmarkWins() throws {
        let fixture = try Fixture("resolver-first")
        let broken = Data([0x00, 0x01, 0x02])
        let resolved = try #require(BookURLResolver.resolvedURL(candidates(
            bookID: fixture.missingPath,
            bookmarks: [broken, try fixture.bookmark(fixture.beta), try fixture.bookmark(fixture.alpha)]
        )))
        #expect(resolved.path == fixture.beta.path)
    }

    @Test("解決できないブックマークは飛ばして次の段階へ進む")
    func abrokenBookmarkFallsThrough() throws {
        let fixture = try Fixture("resolver-broken")
        let resolved = try #require(BookURLResolver.resolvedURL(candidates(
            bookID: fixture.alpha.path, bookmarks: [Data([0xFF, 0xFF, 0xFF])]
        )))
        #expect(resolved.path == fixture.alpha.path)
    }

    @Test("指している先が消えているブックマークも飛ばす(実在確認まで行う)")
    func aBookmarkToADeletedFileIsSkipped() throws {
        let fixture = try Fixture("resolver-deleted")
        let bookmark = try fixture.bookmark(fixture.beta)
        try FileManager.default.removeItem(at: fixture.beta)

        // beta は消えたので、素のパス(alpha)へ落ちる。
        let resolved = try #require(BookURLResolver.resolvedURL(candidates(
            bookID: fixture.alpha.path, bookmarks: [bookmark]
        )))
        #expect(resolved.path == fixture.alpha.path)
    }

    @Test("レイアウト側のブックマークも、素のパスより優先される")
    func theLayoutBookmarkAlsoWinsOverTheBarePath() throws {
        let fixture = try Fixture("resolver-layout")
        let resolved = try #require(BookURLResolver.resolvedURL(candidates(
            bookID: fixture.alpha.path, layout: try fixture.bookmark(fixture.beta)
        )))
        #expect(resolved.path == fixture.beta.path)
    }

    @Test("ブックマーク側が解決できたら、レイアウト側は見ない")
    func theBookmarkStoreShortCircuitsTheLayoutStore() throws {
        let fixture = try Fixture("resolver-shortcircuit")
        let resolved = try #require(BookURLResolver.resolvedURL(candidates(
            bookID: fixture.missingPath,
            bookmarks: [try fixture.bookmark(fixture.beta)],
            layout: try fixture.bookmark(fixture.alpha)
        )))
        #expect(resolved.path == fixture.beta.path)
    }

    @Test("メタデータ側が使われるのは、素のパスも実在しないときだけ")
    func theMetadataBookmarkIsOnlyReachedWhenTheBarePathIsMissing() throws {
        let fixture = try Fixture("resolver-metadata")
        // レイアウト側は「ブックマーク → 素のパス」の順で、素のパスが実在すればそこで返る。
        // つまりメタデータ側の候補は、bookID のパスが実在しない本にしか効かない。
        let withExistingPath = try #require(BookURLResolver.resolvedURL(candidates(
            bookID: fixture.alpha.path, metadata: try fixture.bookmark(fixture.beta)
        )))
        #expect(withExistingPath.path == fixture.alpha.path)

        let withMissingPath = try #require(BookURLResolver.resolvedURL(candidates(
            bookID: fixture.missingPath, metadata: try fixture.bookmark(fixture.beta)
        )))
        #expect(withMissingPath.path == fixture.beta.path)
    }

    @Test("どの候補も解決できず、パスも実在しなければ nil")
    func everyCandidateFailingYieldsNil() throws {
        let fixture = try Fixture("resolver-all-fail")
        let broken = Data([0x01, 0x02, 0x03])
        #expect(BookURLResolver.resolvedURL(candidates(
            bookID: fixture.missingPath, bookmarks: [broken], layout: broken, metadata: broken
        )) == nil)
    }

    @Test("メインアクターの外から呼べる(一覧の絞り込みがウインドウを止めないための前提)")
    func theResolverRunsOffTheMainActor() async throws {
        let fixture = try Fixture("resolver-detached")
        let path = fixture.alpha.path
        let resolved = await Task.detached { BookURLResolver.resolvedURL(
            BookURLResolver.Candidates(
                bookID: path, bookmarkStoreBookmarks: [], layoutBookmark: nil, metadataBookmark: nil
            )
        ) }.value
        #expect(resolved?.path == path)
    }
}
