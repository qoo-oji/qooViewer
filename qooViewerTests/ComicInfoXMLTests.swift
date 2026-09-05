import Foundation
import Testing

@testable import qooViewer

/// `ComicInfo.xml` の生成と解析(Services/ComicInfoXML.swift)。
///
/// 方針は「生成は厳密に(v2.0 XSD の `<xs:sequence>` の順)・解析は寛容に(順序も大文字小文字も
/// 問わない)」。ここが崩れると、書き出した CBZ が Komga / Kavita に読まれない、あるいは他アプリの
/// 書いたファイルから読み方向やしおりを取りこぼす。
///
/// XXE の遮断(`nodeLoadExternalEntitiesNever`)も、外すとローカルのファイルの中身が DB へ入り、
/// CBZ 書き出しで外へ出ていく経路なので、実際にファイルを置いて確かめる。
struct ComicInfoXMLTests {
    private func parse(_ xml: String) -> ComicInfo? { ComicInfoXML.parse(Data(xml.utf8)) }

    // MARK: - 解析(寛容に)

    @Test("要素の順序も大文字小文字も問わずに読む")
    func parsingIgnoresOrderAndCase() throws {
        let info = try #require(parse("""
        <?xml version="1.0" encoding="utf-8"?>
        <comicinfo>
          <WRITER>原作者</WRITER>
          <series>シリーズ</series>
          <Number>3</Number>
          <TITLE>題</TITLE>
        </comicinfo>
        """))
        #expect(info.title == "題")
        #expect(info.series == "シリーズ")
        #expect(info.number == "3")
        #expect(info.writer == "原作者")
    }

    @Test("同じ要素が2回書かれていたら、最初のものを採る")
    func theFirstOfDuplicatedElementsWins() throws {
        let info = try #require(parse("<ComicInfo><Title>先</Title><Title>後</Title></ComicInfo>"))
        #expect(info.title == "先")
    }

    @Test("ルート要素が ComicInfo でなければ nil")
    func aForeignRootElementIsRejected() {
        #expect(parse("<Book><Title>題</Title></Book>") == nil)
        #expect(parse("これは XML ではない") == nil)
        #expect(ComicInfoXML.parse(Data()) == nil)
    }

    @Test("値の前後の空白は落とす")
    func valuesAreTrimmed() throws {
        let info = try #require(parse("<ComicInfo><Title>  題  \n</Title></ComicInfo>"))
        #expect(info.title == "題")
    }

    @Test("XSD の「未設定」既定値(-1、PageCount は 0)は書かれていない扱い")
    func unsetSentinelValuesBecomeNil() throws {
        let info = try #require(parse("""
        <ComicInfo><Count>-1</Count><Volume>-1</Volume><Year>-1</Year><PageCount>0</PageCount></ComicInfo>
        """))
        #expect(info.count == nil)
        #expect(info.volume == nil)
        #expect(info.year == nil)
        #expect(info.pageCount == nil)
        // 0 は Count にとっては普通の値。PageCount だけが 0 を未設定として扱う。
        #expect(try #require(parse("<ComicInfo><Count>0</Count></ComicInfo>")).count == 0)
    }

    @Test("数値として読めない値は nil")
    func nonNumericValuesBecomeNil() throws {
        let info = try #require(parse("<ComicInfo><Year>令和</Year><Volume></Volume></ComicInfo>"))
        #expect(info.year == nil)
        #expect(info.volume == nil)
    }

    @Test("列挙型の値も大文字小文字を問わない",
          arguments: ["YesAndRightToLeft", "yesandrighttoleft", "YESANDRIGHTTOLEFT"])
    func enumValuesAreCaseInsensitive(raw: String) throws {
        let info = try #require(parse("<ComicInfo><Manga>\(raw)</Manga></ComicInfo>"))
        #expect(info.manga == .yesAndRightToLeft)
        #expect(info.readingDirection == .rightToLeft)
    }

    @Test("知らない列挙値は nil(捨てる)")
    func unknownEnumValuesBecomeNil() throws {
        let info = try #require(parse("<ComicInfo><Manga>Maybe</Manga><BlackAndWhite>?</BlackAndWhite></ComicInfo>"))
        #expect(info.manga == nil)
        #expect(info.blackAndWhite == nil)
    }

    @Test("CommunityRating は 0〜5 の有限値だけを受け取る",
          arguments: [("3.25", 3.25 as Double?), ("0", 0), ("5", 5), ("5.01", nil), ("-1", nil), ("nan", nil), ("inf", nil)])
    func communityRatingIsRangeChecked(raw: String, expected: Double?) throws {
        // "nan" を取り込むと、CBZ 書き出しの String(format: "%.2f") がそのまま "nan" を書く。
        let info = try #require(parse("<ComicInfo><CommunityRating>\(raw)</CommunityRating></ComicInfo>"))
        #expect(info.communityRating == expected)
    }

    // MARK: - 解析(Pages)

    @Test("Page の属性は大文字小文字を問わず、DoublePage は True/true/1 のいずれも真")
    func pageAttributesAreParsedLeniently() throws {
        let info = try #require(parse("""
        <ComicInfo><Pages>
          <Page Image="0" Type="FrontCover" doublepage="True" ImageSize="1234" ImageWidth="800" ImageHeight="1200" />
          <Page image="1" DoublePage="1" Bookmark="第1章" Key="k" />
          <Page Image="2" DoublePage="false" />
        </Pages></ComicInfo>
        """))
        #expect(info.pages.count == 3)
        #expect(info.pages[0] == ComicInfoPage(
            image: 0, type: .frontCover, doublePage: true, imageSize: 1234,
            imageWidth: 800, imageHeight: 1200
        ))
        #expect(info.pages[1].doublePage == true)
        #expect(info.pages[1].bookmark == "第1章")
        #expect(info.pages[1].key == "k")
        #expect(info.pages[2].doublePage == false)
    }

    @Test("Image が無い/読めない Page 行は読み飛ばす")
    func pagesWithoutAValidImageIndexAreSkipped() throws {
        let info = try #require(parse("""
        <ComicInfo><Pages>
          <Page Type="Story" />
          <Page Image="いち" />
          <Page Image="2" />
          <NotAPage Image="3" />
        </Pages></ComicInfo>
        """))
        #expect(info.pages.map(\.image) == [2])
    }

    @Test("しおりは名前のある Page だけを、ページ番号順で返す")
    func bookmarksAreSortedAndFiltered() throws {
        let info = try #require(parse("""
        <ComicInfo><Pages>
          <Page Image="5" Bookmark="第3章" />
          <Page Image="1" Bookmark="第1章" />
          <Page Image="3" Bookmark="   " />
          <Page Image="4" />
        </Pages></ComicInfo>
        """))
        #expect(info.bookmarks.map(\.pageIndex) == [1, 5])
        #expect(info.bookmarks.map(\.name) == ["第1章", "第3章"])
    }

    // MARK: - 外部実体(XXE)

    @Test("外部実体は読みに行かない")
    func externalEntitiesAreNeverLoaded() throws {
        // 付けていなかった当時は、この形でローカルのファイルの中身が Title に入ることを実測した。
        // 取り込まれた値は DB へ入り、CBZ 書き出しで出力ファイルへ書き戻される。
        let workspace = try TemporaryDirectory("xxe")
        let secretURL = workspace.file("secret.txt")
        try Data("TOP-SECRET-abcdef".utf8).write(to: secretURL)

        let info = ComicInfoXML.parse(Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE ComicInfo [ <!ENTITY xxe SYSTEM "file://\(secretURL.path)"> ]>
        <ComicInfo><Title>&xxe;</Title></ComicInfo>
        """.utf8))
        // 解析に失敗する(nil)か、値が入らないかのどちらでもよい。中身が漏れないことだけが要件。
        #expect(info?.title.contains("TOP-SECRET") != true)
    }

    @Test("定義済み実体は今までどおり解決される")
    func predefinedEntitiesStillResolve() throws {
        let info = try #require(parse("<ComicInfo><Title>A &amp; B &lt;C&gt;</Title></ComicInfo>"))
        #expect(info.title == "A & B <C>")
    }

    // MARK: - 生成

    @Test("空の ComicInfo は要素を1つも書かない")
    func anEmptyComicInfoWritesNoElements() {
        let xml = ComicInfoXML.makeDocument(ComicInfo())
        #expect(ComicInfo().isEmpty)
        #expect(xml.contains("<ComicInfo "))
        #expect(xml.contains("</ComicInfo>"))
        #expect(!xml.contains("<Title>"))
        #expect(xml.hasSuffix("\n"))
    }

    @Test("要素は v2.0 XSD の順序で並ぶ")
    func elementsFollowTheSchemaOrder() {
        var info = ComicInfo()
        info.review = "評"
        info.title = "題"
        info.publisher = "版元"
        info.series = "シリーズ"
        let xml = ComicInfoXML.makeDocument(info)
        let order = ["<Title>", "<Series>", "<Publisher>", "<Review>"]
        let positions = order.map { xml.range(of: $0)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil })
        #expect(positions == positions.compactMap { $0 }.sorted().map { Optional($0) })
    }

    @Test("空文字・nil の項目は要素ごと省略する")
    func emptyValuesAreOmitted() {
        var info = ComicInfo()
        info.title = "題"
        info.series = "   " // 空白だけも空扱い
        let xml = ComicInfoXML.makeDocument(info)
        #expect(xml.contains("<Title>題</Title>"))
        #expect(!xml.contains("<Series>"))
        #expect(!xml.contains("<Volume>"))
    }

    @Test("XML として書けない制御文字は落とし、記号はエスケープする")
    func controlCharactersAreStrippedAndSymbolsEscaped() throws {
        var info = ComicInfo()
        info.title = "A & B <C> \"D\" 'E'\u{0}\u{1}"
        let xml = ComicInfoXML.makeDocument(info)
        #expect(!xml.contains("\u{0}"))
        #expect(xml.contains("&amp;"))
        #expect(xml.contains("&lt;C&gt;"))
        // 書いたものが XML として読み直せることが最終的な要件。
        let parsed = try #require(ComicInfoXML.parse(Data(xml.utf8)))
        #expect(parsed.title == "A & B <C> \"D\" 'E'")
    }

    @Test("CommunityRating はロケールに依らず小数点が \".\"")
    func communityRatingUsesADot() {
        var info = ComicInfo()
        info.communityRating = 3.5
        #expect(ComicInfoXML.makeDocument(info).contains("<CommunityRating>3.50</CommunityRating>"))
    }

    // MARK: - 往復

    @Test("書いたものを読み直すと元の値に戻る")
    func documentRoundTrips() throws {
        var info = ComicInfo()
        info.title = "題 & 副題"
        info.series = "シリーズ"
        info.number = "上"
        info.count = 2
        info.volume = 3
        info.summary = "あらすじ\n2行目"
        info.year = 2026
        info.month = 9
        info.day = 6
        info.writer = "原作, 原作2"
        info.penciller = "作画"
        info.publisher = "版元"
        info.genre = "少年, ギャグ"
        info.web = "https://example.com/a%20b"
        info.pageCount = 12
        info.languageISO = "ja"
        info.blackAndWhite = .yes
        info.manga = .yesAndRightToLeft
        info.communityRating = 4.25
        info.ageRating = "Everyone"
        info.review = "評"
        info.pages = [
            ComicInfoPage(image: 0, type: .frontCover, imageWidth: 800, imageHeight: 1200),
            ComicInfoPage(image: 3, doublePage: true, imageSize: 4096, key: "k", bookmark: "第2章 & 続き"),
        ]

        let parsed = try #require(ComicInfoXML.parse(Data(ComicInfoXML.makeDocument(info).utf8)))
        #expect(parsed == info)
    }

    @Test("しおり付きの Page を往復させても名前が壊れない")
    func bookmarksRoundTrip() throws {
        var info = ComicInfo()
        info.pages = [ComicInfoPage(image: 7, bookmark: "<第3章> & \"おまけ\"")]
        let parsed = try #require(ComicInfoXML.parse(Data(ComicInfoXML.makeDocument(info).utf8)))
        #expect(parsed.bookmarks.map(\.name) == ["<第3章> & \"おまけ\""])
    }
}

/// `ComicInfo` から取り出す値(Services/ComicInfoResolver.swift の extension)。
struct ComicInfoDerivationTests {
    @Test("著者は Writer > Penciller > CoverArtist > Editor の順で1つだけ選ぶ")
    func authorFallsBackThroughTheCredits() {
        var info = ComicInfo()
        #expect(info.sourceBookMetadata.author == "")
        info.editor = "編集"
        #expect(info.sourceBookMetadata.author == "編集")
        info.coverArtist = "表紙"
        #expect(info.sourceBookMetadata.author == "表紙")
        info.penciller = "作画"
        #expect(info.sourceBookMetadata.author == "作画")
        info.writer = "原作"
        #expect(info.sourceBookMetadata.author == "原作")
    }

    @Test("複数人が書かれていたら、その文字列のまま入れる(1人目だけを採らない)")
    func multipleCreditsAreKeptVerbatim() {
        var info = ComicInfo()
        info.writer = "原作, 原作2"
        #expect(info.sourceBookMetadata.author == "原作, 原作2")
    }

    @Test("巻数は Number を優先し、空なら Volume から拾う")
    func seriesIndexPrefersNumber() {
        var info = ComicInfo()
        info.volume = 5
        #expect(info.sourceBookMetadata.seriesIndex == "5")
        info.number = "上"
        #expect(info.sourceBookMetadata.seriesIndex == "上")
    }

    @Test("Manga=Yes を左開きと解釈してはいけない")
    func mangaYesDoesNotDecideTheDirection() {
        var info = ComicInfo()
        #expect(info.readingDirection == nil)
        info.manga = .yes
        #expect(info.readingDirection == nil)
        info.manga = .unknown
        #expect(info.readingDirection == nil)
        info.manga = .no
        #expect(info.readingDirection == .leftToRight)
        info.manga = .yesAndRightToLeft
        #expect(info.readingDirection == .rightToLeft)
    }
}
