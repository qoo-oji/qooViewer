import Foundation

/// 固定レイアウト(画像だけ)の EPUB をテストの中で組み立てる。
///
/// container.xml → OPF(manifest / spine / metadata)→ 各ページの XHTML(または画像そのもの)→
/// nav.xhtml を ZipFixtureBuilder で zip にする。mimetype は先頭・無圧縮。既定値はよくある
/// コミック EPUB(Kindle Comic Creator / calibre の出力)の形に寄せてあり、フラグで崩し方を選ぶ。
nonisolated struct EpubFixtureBuilder {
    struct Page {
        var number: UInt8
        var wide = false
        /// spine の itemref の `properties`(例: "page-spread-left"、"rendition:page-spread-center")。
        var spineProperties: String? = nil
        /// XHTML を挟まず、spine が画像そのものを指す形にする。
        var imageInSpine = false
        /// XHTML の中身を `<img>` ではなく `<svg><image xlink:href>` にする。
        var svg = false
        /// 画像ファイルをわざと入れない(その spine 項目はページにならない)。
        var imageMissing = false

        init(number: UInt8) { self.number = number }
    }

    var pages: [Page]
    /// spine の `page-progression-direction`(rtl / ltr / nil)。
    var pageProgressionDirection: String? = nil
    /// `<meta property="rendition:spread">`(none / both / auto / landscape / nil)。
    var renditionSpread: String? = nil
    var title = "Fixture Book"
    var author: String? = nil
    var language = "ja"
    /// calibre 形式のシリーズ(`<meta name="calibre:series">` / `calibre:series_index`)。
    var calibreSeries: String? = nil
    var calibreSeriesIndex: String? = nil
    /// EPUB3 形式のシリーズ(belongs-to-collection + collection-type + group-position)。
    var collection: (name: String, position: String, type: String?)? = nil
    /// manifest を spine と逆順に書く(順序が spine で決まることを確かめる)。
    var manifestReversed = false
    /// `<opf:package>` のように接頭辞付きで書く(名前空間の書き方が違っても読めること)。
    var namespacePrefixed = false
    /// manifest の `media-type` を省く(拡張子で推測する経路)。
    var omitMediaType = false
    var includeNav = true
    var omitContainer = false
    var contentDirectory = "OEBPS"

    init(pages: [Page]) { self.pages = pages }

    /// 番号 1〜count のページ。
    static func pages(_ count: Int) -> EpubFixtureBuilder {
        EpubFixtureBuilder(pages: (1...count).map { Page(number: UInt8($0)) })
    }

    // MARK: - 名前

    func imageHref(_ index: Int) -> String { String(format: "Images/p%03d.png", index + 1) }
    func xhtmlHref(_ index: Int) -> String { String(format: "Text/p%03d.xhtml", index + 1) }
    func imageEntryPath(_ index: Int) -> String { "\(contentDirectory)/\(imageHref(index))" }

    /// EpubStructureResolver が返すはずの、画像のエントリパスの列(spine 順、画像の無い項目は除く)。
    var expectedEntryPaths: [String] {
        pages.indices.filter { !pages[$0].imageMissing }.map(imageEntryPath)
    }

    // MARK: - 書く

    func write(to url: URL) throws {
        var zip = ZipFixtureBuilder()
        zip.add("mimetype", text: "application/epub+zip", stored: true)
        if !omitContainer {
            zip.add("META-INF/container.xml", text: containerXML)
        }
        zip.add("\(contentDirectory)/content.opf", text: packageDocument)
        for (index, page) in pages.enumerated() {
            if !page.imageMissing {
                zip.add(imageEntryPath(index), PageImageFactory.png(number: page.number, wide: page.wide))
            }
            if !page.imageInSpine {
                zip.add("\(contentDirectory)/\(xhtmlHref(index))", text: pageXHTML(index))
            }
        }
        if includeNav {
            zip.add("\(contentDirectory)/nav.xhtml", text: navXHTML)
        }
        try zip.write(to: url)
    }

    private var containerXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="\(contentDirectory)/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    private var packageDocument: String {
        let p = namespacePrefixed ? "opf:" : ""
        let namespaceDeclaration = namespacePrefixed
            ? "xmlns:opf=\"http://www.idpf.org/2007/opf\""
            : "xmlns=\"http://www.idpf.org/2007/opf\""

        var metadata: [String] = [
            "<dc:identifier id=\"uid\">urn:uuid:qooviewer-fixture</dc:identifier>",
            "<dc:title>\(escape(title))</dc:title>",
            "<dc:language>\(escape(language))</dc:language>",
            "<\(p)meta property=\"rendition:layout\">pre-paginated</\(p)meta>",
            "<\(p)meta property=\"dcterms:modified\">2026-01-01T00:00:00Z</\(p)meta>",
        ]
        if let author {
            metadata.append("<dc:creator>\(escape(author))</dc:creator>")
        }
        if let renditionSpread {
            metadata.append("<\(p)meta property=\"rendition:spread\">\(renditionSpread)</\(p)meta>")
        }
        if let calibreSeries {
            metadata.append("<\(p)meta name=\"calibre:series\" content=\"\(escape(calibreSeries))\"/>")
        }
        if let calibreSeriesIndex {
            metadata.append("<\(p)meta name=\"calibre:series_index\" content=\"\(escape(calibreSeriesIndex))\"/>")
        }
        if let collection {
            metadata.append("<\(p)meta property=\"belongs-to-collection\" id=\"c1\">\(escape(collection.name))</\(p)meta>")
            if let type = collection.type {
                metadata.append("<\(p)meta refines=\"#c1\" property=\"collection-type\">\(escape(type))</\(p)meta>")
            }
            metadata.append("<\(p)meta refines=\"#c1\" property=\"group-position\">\(escape(collection.position))</\(p)meta>")
        }

        var manifest: [String] = []
        for index in pages.indices {
            let page = pages[index]
            let imageType = omitMediaType ? "" : " media-type=\"image/png\""
            manifest.append("<\(p)item id=\"img\(index)\" href=\"\(imageHref(index))\"\(imageType)/>")
            if !page.imageInSpine {
                let xhtmlType = omitMediaType ? "" : " media-type=\"application/xhtml+xml\""
                manifest.append("<\(p)item id=\"page\(index)\" href=\"\(xhtmlHref(index))\"\(xhtmlType)/>")
            }
        }
        if includeNav {
            manifest.append("<\(p)item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        }
        if manifestReversed { manifest.reverse() }

        var spine: [String] = []
        for index in pages.indices {
            let page = pages[index]
            let idref = page.imageInSpine ? "img\(index)" : "page\(index)"
            let properties = page.spineProperties.map { " properties=\"\($0)\"" } ?? ""
            spine.append("<\(p)itemref idref=\"\(idref)\"\(properties)/>")
        }
        let direction = pageProgressionDirection.map { " page-progression-direction=\"\($0)\"" } ?? ""

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <\(p)package \(namespaceDeclaration) version="3.0" unique-identifier="uid" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
          <\(p)metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(metadata.joined(separator: "\n    "))
          </\(p)metadata>
          <\(p)manifest>
            \(manifest.joined(separator: "\n    "))
          </\(p)manifest>
          <\(p)spine\(direction)>
            \(spine.joined(separator: "\n    "))
          </\(p)spine>
        </\(p)package>
        """
    }

    private func pageXHTML(_ index: Int) -> String {
        let page = pages[index]
        let width = page.wide ? PageImageFactory.wideWidth : PageImageFactory.width
        let height = PageImageFactory.height
        let body: String
        if page.svg {
            body = """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 \(width) \(height)">
                  <image xlink:href="../\(imageHref(index))" width="\(width)" height="\(height)"/>
                </svg>
            """
        } else {
            body = "<img src=\"../\(imageHref(index))\" alt=\"\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head>
            <title>p\(index + 1)</title>
            <meta name="viewport" content="width=\(width), height=\(height)"/>
          </head>
          <body>
            \(body)
          </body>
        </html>
        """
    }

    /// 目次: 第1章(1 ページ目)の下に 1.1 節(2 ページ目)、第2章(最後のページ)。ページが足りなければ
    /// あるぶんだけ。
    private var navXHTML: String {
        func link(_ index: Int, _ title: String) -> String {
            let page = pages[index]
            let href = page.imageInSpine ? imageHref(index) : xhtmlHref(index)
            return "<a href=\"\(href)\">\(escape(title))</a>"
        }
        var items: [String] = []
        if !pages.isEmpty {
            var first = "<li>\(link(0, "第1章"))"
            if pages.count > 1 {
                first += "<ol><li>\(link(1, "1.1 節"))</li></ol>"
            }
            first += "</li>"
            items.append(first)
        }
        if pages.count > 2 {
            items.append("<li>\(link(pages.count - 1, "第2章"))</li>")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>目次</title></head>
          <body>
            <nav epub:type="toc" id="toc">
              <ol>
                \(items.joined(separator: "\n        "))
              </ol>
            </nav>
          </body>
        </html>
        """
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
