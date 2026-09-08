import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// 「この本のカバーは何か」の唯一の決定場所(Services/CoverImageResolver.swift)。
///
/// 押さえるのは 2 つ:
/// - どのページが選ばれるか ―― 上書き指定 > 実効1ページ目(除外・並べ替えを反映した後の先頭)。
///   ページ画像の R にページ番号が埋めてあるので、選ばれた**中身**で確かめられる(PageColorReader)。
/// - 横長のカバーの切り方 ―― 読み方向(自動)と、ユーザーが選んだ位置。
///
/// `cachesPageList: false` は固定。既定のままだと実物のアプリのページ一覧キャッシュへ
/// テスト用の本が残る(InMemoryLibrary の同じ注意書きと同じ話)。
struct CoverImageResolverTests {
    private static let maxPixelSize: CGFloat = 64

    /// 001…004 の 4 ページが並んだフォルダの本。
    private func makeBook(_ temporary: TemporaryDirectory, named name: String = "book") throws -> URL {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: (1...4).map {
            .init(String(format: "%03d.png", $0), number: UInt8($0))
        })
        return directory
    }

    private func coverNumber(
        bookAt url: URL, snapshot: CoverImageResolver.OverrideSnapshot
    ) async -> Int? {
        guard let image = await CoverImageResolver.coverImage(
            bookAt: url, snapshot: snapshot, maxPixelSize: Self.maxPixelSize, cachesPageList: false
        ) else { return nil }
        return PageColorReader.number(in: image)
    }

    private func sortKey(_ bookURL: URL, page: String) -> String {
        // フォルダの本の sortKey は絶対パス(PageRef.sortKey)。
        bookURL.appendingPathComponent(page).path
    }

    // MARK: - どのページが選ばれるか

    @Test("上書きが無ければ、実効1ページ目(先頭)が選ばれる")
    func theDefaultCoverIsTheFirstPage() async throws {
        let temporary = try TemporaryDirectory("cover-default")
        let book = try makeBook(temporary)
        #expect(await coverNumber(bookAt: book, snapshot: .init()) == 1)
    }

    @Test("先頭ページを除外していれば、その次のページがカバーになる")
    func excludingTheFirstPageMovesTheCover() async throws {
        let temporary = try TemporaryDirectory("cover-excluded")
        let book = try makeBook(temporary)
        let snapshot = CoverImageResolver.OverrideSnapshot(
            excludedKeys: [sortKey(book, page: "001.png")]
        )
        #expect(await coverNumber(bookAt: book, snapshot: snapshot) == 2)
    }

    @Test("並べ替えの結果の先頭がカバーになる")
    func theCoverFollowsThePageOrderOverride() async throws {
        let temporary = try TemporaryDirectory("cover-reordered")
        let book = try makeBook(temporary)
        let snapshot = CoverImageResolver.OverrideSnapshot(
            pageOrderOverride: ["003.png", "001.png", "002.png", "004.png"]
                .map { sortKey(book, page: $0) }
        )
        #expect(await coverNumber(bookAt: book, snapshot: snapshot) == 3)
    }

    @Test("ページを指定していれば、そのページがカバーになる")
    func anExplicitPageWins() async throws {
        let temporary = try TemporaryDirectory("cover-page-key")
        let book = try makeBook(temporary)
        let snapshot = CoverImageResolver.OverrideSnapshot(
            coverPageKey: sortKey(book, page: "004.png")
        )
        #expect(await coverNumber(bookAt: book, snapshot: snapshot) == 4)
    }

    @Test("指定したページが本から消えていたら、既定(実効1ページ目)へ落ちる")
    func aStalePageKeyFallsBackToTheFirstPage() async throws {
        let temporary = try TemporaryDirectory("cover-stale-key")
        let book = try makeBook(temporary)
        let snapshot = CoverImageResolver.OverrideSnapshot(
            coverPageKey: sortKey(book, page: "099.png")
        )
        #expect(await coverNumber(bookAt: book, snapshot: snapshot) == 1)
    }

    @Test("本に含まれない専用ファイルを指定していれば、本体を開かずにそれを読む")
    func anExternalCoverFileIsUsedAsIs() async throws {
        let temporary = try TemporaryDirectory("cover-external")
        let book = try makeBook(temporary)
        let external = temporary.file("external-cover.png")
        try PageImageFactory.png(number: 9).write(to: external)
        let snapshot = CoverImageResolver.OverrideSnapshot(externalCoverURL: external)
        #expect(await coverNumber(bookAt: book, snapshot: snapshot) == 9)
    }

    @Test("開けない本は nil(呼び出し側が failed として記録する)")
    func abrokenBookYieldsNil() async throws {
        let temporary = try TemporaryDirectory("cover-broken")
        let broken = temporary.file("not-a-book.cbz")
        try Data("this is not a zip".utf8).write(to: broken)
        #expect(await coverNumber(bookAt: broken, snapshot: .init()) == nil)
    }

    // MARK: - 横長カバーの切り方

    /// 4:3 の横長画像。左半分を黒(R=0)、右半分を白(R=255)に塗り分けて、どちら側が
    /// 残ったかを中央の画素の色で見分けられるようにする。
    private func makeLandscapeImage(width: Int = 40, height: Int = 30) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try #require(context.makeImage())
    }

    @Test("縦長・正方形のカバーは切らない")
    func portraitCoversAreLeftAlone() throws {
        let portrait = PageImageFactory.cgImage(number: 1)
        let result = CoverImageResolver.croppedForGrid(
            portrait, readingDirection: .rightToLeft, anchor: nil
        )
        #expect(result.cropSide == .none)
        #expect(result.image.width == portrait.width)
        #expect(result.image.height == portrait.height)
    }

    @Test("自動のとき、右開きは左端・左開きは右端を残す(表紙にあたる側)")
    func theAutomaticCropFollowsTheReadingDirection() throws {
        let landscape = try makeLandscapeImage()
        let expectedWidth = Int((CGFloat(landscape.height) * CoverImageResolver.gridAspectRatio).rounded())

        let rightToLeft = CoverImageResolver.croppedForGrid(
            landscape, readingDirection: .rightToLeft, anchor: nil
        )
        #expect(rightToLeft.cropSide == .left)
        #expect(rightToLeft.image.width == expectedWidth)
        #expect(rightToLeft.image.height == landscape.height)
        #expect(PageColorReader.number(in: rightToLeft.image) == 0)

        let leftToRight = CoverImageResolver.croppedForGrid(
            landscape, readingDirection: .leftToRight, anchor: nil
        )
        #expect(leftToRight.cropSide == .right)
        #expect(PageColorReader.number(in: leftToRight.image) == 255)
    }

    @Test("位置を明示したら、読み方向に関わらずその位置で切る")
    func anExplicitAnchorOverridesTheReadingDirection() throws {
        let landscape = try makeLandscapeImage()
        let expectedWidth = Int((CGFloat(landscape.height) * CoverImageResolver.gridAspectRatio).rounded())

        // 右開き(自動なら左端)でも、右端を指定すれば右端が残る。
        let right = CoverImageResolver.croppedForGrid(
            landscape, readingDirection: .rightToLeft, anchor: .right
        )
        #expect(right.cropSide == .right)
        #expect(PageColorReader.number(in: right.image) == 255)

        let center = CoverImageResolver.croppedForGrid(
            landscape, readingDirection: .rightToLeft, anchor: .center
        )
        #expect(center.cropSide == .center)
        #expect(center.image.width == expectedWidth)

        let left = CoverImageResolver.croppedForGrid(
            landscape, readingDirection: .leftToRight, anchor: .left
        )
        #expect(left.cropSide == .left)
        #expect(PageColorReader.number(in: left.image) == 0)
    }

    @Test("極端に横長(パノラマ)でも、幅は高さ × 2/3 になる")
    func aPanoramaIsCroppedToTheSameAspectRatio() throws {
        let panorama = try makeLandscapeImage(width: 300, height: 30)
        let result = CoverImageResolver.croppedForGrid(
            panorama, readingDirection: .rightToLeft, anchor: nil
        )
        #expect(result.image.height == 30)
        #expect(result.image.width == Int((CGFloat(30) * CoverImageResolver.gridAspectRatio).rounded()))
    }
}
