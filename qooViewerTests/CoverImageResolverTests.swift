import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// 「この本のカバーは何か」の唯一の決定場所(Services/CoverImageResolver.swift)。
///
/// 押さえるのは 2 つ:
/// - どのページが選ばれるか ―― 上書き指定 > 実効1ページ目(除外・並べ替えを反映した後の先頭)。
///   ページ画像の R にページ番号が埋めてあるので、選ばれた**中身**で確かめられる(PageColorReader)。
/// - 枠へ収めるときの切り方 ―― 左右を切るのか上下を切るのか、そして残す位置。
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
        bookAt url: URL?, snapshot: CoverImageResolver.OverrideSnapshot
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

    @Test("利用者が指定した画像があれば、本体を開かずにそれを読む")
    func aChosenImageFileIsUsedAsIs() async throws {
        let temporary = try TemporaryDirectory("cover-external")
        let book = try makeBook(temporary)
        let external = temporary.file("external-cover.png")
        try PageImageFactory.png(number: 9).write(to: external)
        let snapshot = CoverImageResolver.OverrideSnapshot(imageFileURL: external)
        #expect(await coverNumber(bookAt: book, snapshot: snapshot) == 9)
    }

    @Test("指定した画像があれば、本の場所が分からなくても読める")
    func aChosenImageFileNeedsNoBook() async throws {
        let temporary = try TemporaryDirectory("cover-external-nobook")
        let external = temporary.file("external-cover.png")
        try PageImageFactory.png(number: 6).write(to: external)
        let snapshot = CoverImageResolver.OverrideSnapshot(imageFileURL: external)
        #expect(await coverNumber(bookAt: nil, snapshot: snapshot) == 6)
    }

    @Test("本の場所が無く、指定した画像も無ければ nil")
    func noBookAndNoImageYieldsNil() async throws {
        #expect(await coverNumber(bookAt: nil, snapshot: .init()) == nil)
    }

    @Test("開けない本は nil(呼び出し側が failed として記録する)")
    func abrokenBookYieldsNil() async throws {
        let temporary = try TemporaryDirectory("cover-broken")
        let broken = temporary.file("not-a-book.cbz")
        try Data("this is not a zip".utf8).write(to: broken)
        #expect(await coverNumber(bookAt: broken, snapshot: .init()) == nil)
    }

    // MARK: - 枠へ収めるときの切り方

    private static let portrait = CoverAspectRatio.portrait.value
    private static let square = CoverAspectRatio.square.value

    /// 横長の画像。左半分を黒(R=0)、右半分を白(R=255)に塗り分けて、どちら側が残ったかを
    /// 中央の画素の色で見分けられるようにする。CGContext の x はそのまま CGImage の x なので、
    /// 「左に塗ったものは左に残る」で読んでよい。
    private func makeSideBySideImage(width: Int = 40, height: Int = 30) throws -> CGImage {
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

    /// 縦長の画像。**CGImage の上半分**を黒(R=0)、下半分を白(R=255)にする。
    ///
    /// CGContext の y は下から上なので、`y: 0` に塗ったものは CGImage では**下**に来る ――
    /// ここを取り違えると「上端を残したはずが下端だった」に気づけないので、塗り分けの向きを
    /// この関数の中で吸収しておく(判定するテストの側は素直に読めるようにする)。
    private func makeStackedImage(width: Int = 30, height: Int = 40) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // 下半分(CGContext の y = 0 側)を白 = CGImage の下半分。
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return try #require(context.makeImage())
    }

    @Test("比がぴったり合っている画像は切らない")
    func anImageThatAlreadyFitsIsLeftAlone() throws {
        let image = try makeSideBySideImage(width: 40, height: 60)
        let result = CoverImageResolver.cropped(image, to: Self.portrait, anchor: .center)
        #expect(result.width == 40)
        #expect(result.height == 60)
        // `#expect(!f(...))` は展開の都合で判定を取り違えるので、いったん受けてから比べる。
        let crops = CoverImageResolver.cropsAnyEdge(
            imageAspect: 40.0 / 60.0, targetAspect: Self.portrait
        )
        #expect(crops == false)
    }

    @Test("相対的に横長な画像は左右を切る。start は左端、end は右端が残る")
    func awiderImageIsCroppedHorizontally() throws {
        let landscape = try makeSideBySideImage()
        let expectedWidth = Int((CGFloat(landscape.height) * Self.portrait).rounded())

        let start = CoverImageResolver.cropped(landscape, to: Self.portrait, anchor: .start)
        #expect(start.width == expectedWidth)
        #expect(start.height == landscape.height)
        #expect(PageColorReader.number(in: start) == 0)

        let end = CoverImageResolver.cropped(landscape, to: Self.portrait, anchor: .end)
        #expect(end.width == expectedWidth)
        #expect(PageColorReader.number(in: end) == 255)

        // 中央は塗り分けの境目にかかるので、色ではなく寸法と位置で見る。
        let center = CoverImageResolver.cropped(landscape, to: Self.portrait, anchor: .center)
        #expect(center.width == expectedWidth)
        #expect(center.height == landscape.height)
    }

    @Test("相対的に縦長な画像は上下を切る。start は上端、end は下端が残る")
    func atallerImageIsCroppedVertically() throws {
        // 30 × 40(比 0.75)を 1:1 の枠へ。高さだけが 30 に詰まる。
        let tall = try makeStackedImage()
        let start = CoverImageResolver.cropped(tall, to: Self.square, anchor: .start)
        #expect(start.width == 30)
        #expect(start.height == 30)
        // CGImage.cropping(to:) の原点は左上なので、start(y = 0)は**上端**。
        #expect(PageColorReader.number(in: start) == 0)

        let end = CoverImageResolver.cropped(tall, to: Self.square, anchor: .end)
        #expect(end.height == 30)
        #expect(PageColorReader.number(in: end) == 255)
    }

    @Test("2:3 の縦長ページも 1:1 の枠では上下が切られる(1:1 を選ぶ動機の裏返し)")
    func aportraitPageIsCroppedInASquareFrame() throws {
        let page = try makeStackedImage(width: 40, height: 60)
        // `#expect(` の中で呼び出しを複数行に折ると、マクロの展開が「結果が使われていない」
        // 警告を出し、CI(警告=エラー)で落ちる。値を一度受けてから渡す。
        let crops = CoverImageResolver.cropsAnyEdge(imageAspect: 40.0 / 60.0, targetAspect: Self.square)
        #expect(crops)
        let result = CoverImageResolver.cropped(page, to: Self.square, anchor: .center)
        #expect(result.width == 40)
        #expect(result.height == 40)
    }

    @Test("極端に横長(パノラマ)でも、切った後の比は枠と同じ")
    func apanoramaIsCroppedToTheSameAspectRatio() throws {
        let panorama = try makeSideBySideImage(width: 300, height: 30)
        let portrait = CoverImageResolver.cropped(panorama, to: Self.portrait, anchor: .center)
        #expect(portrait.height == 30)
        #expect(portrait.width == Int((CGFloat(30) * Self.portrait).rounded()))

        let square = CoverImageResolver.cropped(panorama, to: Self.square, anchor: .center)
        #expect(square.height == 30)
        #expect(square.width == 30)
    }

    @Test("1:1 のほうが横長画像の横を多く残す(この機能の目的)")
    func thesquareFrameKeepsMoreOfAWideImage() throws {
        let landscape = try makeSideBySideImage(width: 120, height: 60)
        let portrait = CoverImageResolver.cropped(landscape, to: Self.portrait, anchor: .center)
        let square = CoverImageResolver.cropped(landscape, to: Self.square, anchor: .center)
        #expect(square.width > portrait.width)
    }
}
