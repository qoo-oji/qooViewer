import Foundation

/// `ComicInfo`とXMLテキストの相互変換。
///
/// 生成(makeDocument)はv2.0のXSDの`<xs:sequence>`と同じ要素順で書き出す。実運用では要素順を
/// 守らない実装のほうがむしろ多い(ComicTaggerは自身の処理順で書いている)ため順序に依存する
/// 読み手はまず無いが、XSDでの検証を通せる形にしておくほうが安全側のため守っている。
///
/// 解析(parse)は逆に順序も大文字小文字も問わず、書かれている要素を拾えるだけ拾う
/// (他アプリが書いたファイルを読むため。Postelの法則)。
///
/// nonisolated: CbzExporter / ComicInfoResolver(いずれもメインアクター外)から呼ばれるため
/// (詳細はServices/ArchiveReading.swift冒頭のコメント参照)。
nonisolated enum ComicInfoXML {
    /// アーカイブのルート直下に置くファイル名。Komga・Kavitaのどちらも「ルート直下・この名前」を
    /// 要求するため、サブフォルダに入れたり別名にしたりしてはいけない。
    static let fileName = "ComicInfo.xml"

    // MARK: - 生成

    static func makeDocument(_ info: ComicInfo) -> String {
        var lines: [String] = []
        // ComicRack(.NETのXmlSerializer)が出力していたものと同じ2つの名前空間宣言を付ける。
        // 実際には参照されない飾りだが、既存のComicInfo.xmlのほとんどがこの形をしており、
        // 素朴な文字列判定でファイル形式を見分けている読み手に対して最も安全なため踏襲する。
        // スキーマの場所(xsi:noNamespaceSchemaLocation)は書かない — 検証器がネットワークへ
        // 取りに行こうとする実装があり、オフラインで開くファイルに外部依存を持ち込むため。
        lines.append("<?xml version=\"1.0\" encoding=\"utf-8\"?>")
        lines.append(
            "<ComicInfo xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
                + " xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">"
        )

        // 以下、v2.0 XSDの<xs:sequence>と同じ順序。値が空/nilの要素は出力しない
        // (ComicInfoの型コメント参照)。
        appendText(&lines, "Title", info.title)
        appendText(&lines, "Series", info.series)
        appendText(&lines, "Number", info.number)
        appendInt(&lines, "Count", info.count)
        appendInt(&lines, "Volume", info.volume)
        appendText(&lines, "AlternateSeries", info.alternateSeries)
        appendText(&lines, "AlternateNumber", info.alternateNumber)
        appendInt(&lines, "AlternateCount", info.alternateCount)
        appendText(&lines, "Summary", info.summary)
        appendText(&lines, "Notes", info.notes)
        appendInt(&lines, "Year", info.year)
        appendInt(&lines, "Month", info.month)
        appendInt(&lines, "Day", info.day)
        appendText(&lines, "Writer", info.writer)
        appendText(&lines, "Penciller", info.penciller)
        appendText(&lines, "Inker", info.inker)
        appendText(&lines, "Colorist", info.colorist)
        appendText(&lines, "Letterer", info.letterer)
        appendText(&lines, "CoverArtist", info.coverArtist)
        appendText(&lines, "Editor", info.editor)
        appendText(&lines, "Publisher", info.publisher)
        appendText(&lines, "Imprint", info.imprint)
        appendText(&lines, "Genre", info.genre)
        appendText(&lines, "Web", info.web)
        appendInt(&lines, "PageCount", info.pageCount)
        appendText(&lines, "LanguageISO", info.languageISO)
        appendText(&lines, "Format", info.format)
        appendText(&lines, "BlackAndWhite", info.blackAndWhite?.rawValue ?? "")
        appendText(&lines, "Manga", info.manga?.rawValue ?? "")
        appendText(&lines, "Characters", info.characters)
        appendText(&lines, "Teams", info.teams)
        appendText(&lines, "Locations", info.locations)
        appendText(&lines, "ScanInformation", info.scanInformation)
        appendText(&lines, "StoryArc", info.storyArc)
        appendText(&lines, "SeriesGroup", info.seriesGroup)
        appendText(&lines, "AgeRating", info.ageRating)
        appendPages(&lines, info.pages)
        if let rating = info.communityRating {
            // XSDはfractionDigits=2。ロケールに依らず"."を小数点にする。
            appendText(&lines, "CommunityRating", String(format: "%.2f", rating))
        }
        appendText(&lines, "MainCharacterOrTeam", info.mainCharacterOrTeam)
        appendText(&lines, "Review", info.review)

        lines.append("</ComicInfo>")
        // 末尾に改行を1つ付ける(テキストファイルとしての慣習)。
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendText(_ lines: inout [String], _ name: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append("  <\(name)>\(escape(trimmed))</\(name)>")
    }

    private static func appendInt(_ lines: inout [String], _ name: String, _ value: Int?) {
        guard let value else { return }
        lines.append("  <\(name)>\(value)</\(name)>")
    }

    private static func appendPages(_ lines: inout [String], _ pages: [ComicInfoPage]) {
        guard !pages.isEmpty else { return }
        lines.append("  <Pages>")
        for page in pages {
            // 属性の順序もXSDのComicPageInfoの定義順に合わせてある。
            var attributes = ["Image=\"\(page.image)\""]
            if let type = page.type {
                attributes.append("Type=\"\(type.rawValue)\"")
            }
            if let doublePage = page.doublePage {
                // XSDはxs:boolean。ComicRackが書くのと同じ小文字の"true"/"false"にする。
                attributes.append("DoublePage=\"\(doublePage)\"")
            }
            if let imageSize = page.imageSize {
                attributes.append("ImageSize=\"\(imageSize)\"")
            }
            if let key = page.key, !key.isEmpty {
                attributes.append("Key=\"\(escape(key))\"")
            }
            if let bookmark = page.bookmark, !bookmark.isEmpty {
                attributes.append("Bookmark=\"\(escape(bookmark))\"")
            }
            if let width = page.imageWidth {
                attributes.append("ImageWidth=\"\(width)\"")
            }
            if let height = page.imageHeight {
                attributes.append("ImageHeight=\"\(height)\"")
            }
            lines.append("    <Page \(attributes.joined(separator: " ")) />")
        }
        lines.append("  </Pages>")
    }

    /// XMLのテキスト・属性値としての最小限のエスケープに加えて、XML 1.0が文書内に持てない
    /// 制御文字を取り除く。
    ///
    /// 取り除きが必要なのは、ここへ来る文字列にユーザーが自由入力したブックマーク名・
    /// タイトル・著者名が含まれるため。制御文字が1つ混ざっただけでXMLとして壊れ、読み手側は
    /// ComicInfo.xmlどころかファイル全体を開けなくなることがある(EPUB書き出しで、ファイル名の
    /// "&"をエスケープせずに書いてOPFが壊れたのと同じ種類の問題)。
    private static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                guard isAllowedInXML(scalar) else { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// XML 1.0のChar生成規則で許される文字かどうか。
    private static func isAllowedInXML(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD: return true
        case 0x20...0xD7FF: return true
        case 0xE000...0xFFFD: return true
        case 0x10000...0x10FFFF: return true
        default: return false
        }
    }

    // MARK: - 解析

    /// 解析できなければnil(ComicInfo.xmlが無いのと同じ扱いにする)。
    ///
    /// 実装にXMLParser(SAX)ではなくXMLDocument(DOM)を使っているのは、ComicInfo.xmlが
    /// 常に数KB程度で全体をメモリに載せても問題が無く、要素を名前で引くだけの読み取りが
    /// デリゲート実装を書くより圧倒的に短く・読みやすくなるため。XMLDocumentはmacOSの
    /// Foundationに標準で含まれる(本アプリはmacOS専用)。
    ///
    /// ■ nodeLoadExternalEntitiesNever は必須(外すと外部実体を読みに行く)
    /// ここへ渡ってくるのは、ユーザーがどこから入手したか分からない書庫の中身であり、
    /// 完全に信用できない入力である。しかもcbz/cbr/cb7・画像フォルダを**初めて開くたびに
    /// 自動で**この解析が走る(ViewerViewModel.importComicInfoIfNeeded)。
    ///
    /// このオプションを付けずにXMLDocumentへ渡すと、次のような`ComicInfo.xml`を仕込まれた
    /// だけで、ローカルのファイルの中身が要素の値として取り込まれることを実測で確認した:
    ///
    /// ```xml
    /// <!DOCTYPE ComicInfo [ <!ENTITY xxe SYSTEM "file:///…"> ]>
    /// <ComicInfo><Title>&xxe;</Title></ComicInfo>
    /// ```
    ///
    /// 取り込まれた値はそのままDBへ登録され(BookMetadataStore.upsert)、さらにその本をCBZとして
    /// 書き出すと出力ファイルへ書き戻される(CbzExporter.applyMetadata)ため、共有すれば外部へ
    /// 出ていく。実体の展開自体(いわゆるbillion laughs)も同時に無効になる。
    /// `&amp;`のような定義済み実体は引き続き解決されるので、正常なファイルの読み取りには影響しない。
    static func parse(_ data: Data) -> ComicInfo? {
        guard let document = try? XMLDocument(
            data: data, options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]
        ),
              let root = document.rootElement(),
              root.name?.caseInsensitiveCompare("ComicInfo") == .orderedSame
        else { return nil }

        // 大文字小文字・要素順を問わずに引けるようにしておく(他アプリが書いたファイルを
        // 読むため)。同じ要素が複数回書かれている場合は最初のものを採用する。
        var textByName: [String: String] = [:]
        var pagesElement: XMLElement?
        for child in root.children ?? [] {
            guard let element = child as? XMLElement, let name = element.name?.lowercased() else { continue }
            if name == "pages" {
                if pagesElement == nil { pagesElement = element }
                continue
            }
            if textByName[name] == nil {
                textByName[name] = element.stringValue ?? ""
            }
        }

        func text(_ name: String) -> String {
            (textByName[name.lowercased()] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// XSDが「未設定」を表す既定値として-1(PageCountは0)を定めているため、その値は
        /// 「書かれていない」ものとして扱う。
        func int(_ name: String, unsetValue: Int = -1) -> Int? {
            let raw = text(name)
            guard !raw.isEmpty, let value = Int(raw), value != unsetValue else { return nil }
            return value
        }

        var info = ComicInfo()
        info.title = text("Title")
        info.series = text("Series")
        info.number = text("Number")
        info.count = int("Count")
        info.volume = int("Volume")
        info.alternateSeries = text("AlternateSeries")
        info.alternateNumber = text("AlternateNumber")
        info.alternateCount = int("AlternateCount")
        info.summary = text("Summary")
        info.notes = text("Notes")
        info.year = int("Year")
        info.month = int("Month")
        info.day = int("Day")
        info.writer = text("Writer")
        info.penciller = text("Penciller")
        info.inker = text("Inker")
        info.colorist = text("Colorist")
        info.letterer = text("Letterer")
        info.coverArtist = text("CoverArtist")
        info.editor = text("Editor")
        info.publisher = text("Publisher")
        info.imprint = text("Imprint")
        info.genre = text("Genre")
        info.web = text("Web")
        info.pageCount = int("PageCount", unsetValue: 0)
        info.languageISO = text("LanguageISO")
        info.format = text("Format")
        info.blackAndWhite = caseInsensitive(ComicInfoYesNo.self, text("BlackAndWhite"))
        info.manga = caseInsensitive(ComicInfoManga.self, text("Manga"))
        info.characters = text("Characters")
        info.teams = text("Teams")
        info.locations = text("Locations")
        info.scanInformation = text("ScanInformation")
        info.storyArc = text("StoryArc")
        info.seriesGroup = text("SeriesGroup")
        info.ageRating = text("AgeRating")
        // XSDはminInclusive=0 / maxInclusive=5。範囲外の値と、Double(_: String)が受け付けて
        // しまう"nan"/"inf"という綴りは捨てる。取り込んでしまうと、この本をCBZとして書き出す
        // ときにString(format: "%.2f")がそのまま"nan"を出力し、こちらの出力まで不正になる
        // (BookMetadata.numericSeriesIndexで同じ理由の対処をしている)。
        if let rating = Double(text("CommunityRating")), rating.isFinite, (0...5).contains(rating) {
            info.communityRating = rating
        }
        info.mainCharacterOrTeam = text("MainCharacterOrTeam")
        info.review = text("Review")
        info.pages = parsePages(pagesElement)
        return info
    }

    /// 列挙型の値を、大文字小文字を区別せずに引く。
    ///
    /// 要素名・`DoublePage`("True"/"true"/"1")は既に区別せずに照合しているのに、列挙型の値
    /// だけを完全一致にすると、`<Manga>yesandrighttoleft</Manga>`のようなファイルで右開きの
    /// 指定を取りこぼす。「解析は寛容に」という方針(型コメント参照)を列挙型にも通す。
    private static func caseInsensitive<Value: RawRepresentable & CaseIterable>(
        _ type: Value.Type, _ raw: String
    ) -> Value? where Value.RawValue == String {
        guard !raw.isEmpty else { return nil }
        return Value.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
    }

    private static func parsePages(_ element: XMLElement?) -> [ComicInfoPage] {
        guard let element else { return [] }
        var pages: [ComicInfoPage] = []
        for child in element.children ?? [] {
            guard let pageElement = child as? XMLElement,
                  pageElement.name?.caseInsensitiveCompare("Page") == .orderedSame
            else { continue }

            func attribute(_ name: String) -> String? {
                // XMLElement.attribute(forName:)は大文字小文字を区別するため、区別しない
                // 突き合わせを自前で行う(解析側は寛容に、の方針)。
                pageElement.attributes?.first {
                    $0.name?.caseInsensitiveCompare(name) == .orderedSame
                }?.stringValue
            }
            // Imageはuse="required"。壊れた行はページ指定として使いようが無いので読み飛ばす。
            guard let imageRaw = attribute("Image"), let image = Int(imageRaw) else { continue }

            var page = ComicInfoPage(image: image)
            page.type = attribute("Type").flatMap { caseInsensitive(ComicInfoPageType.self, $0) }
            if let doublePage = attribute("DoublePage") {
                // ComicRack由来のファイルには"True"/"true"/"1"のいずれもありうる。
                page.doublePage = ["true", "yes", "1"].contains(doublePage.lowercased())
            }
            page.imageSize = attribute("ImageSize").flatMap(Int64.init)
            page.key = attribute("Key")
            page.bookmark = attribute("Bookmark")
            page.imageWidth = attribute("ImageWidth").flatMap(Int.init)
            page.imageHeight = attribute("ImageHeight").flatMap(Int.init)
            pages.append(page)
        }
        return pages
    }
}
