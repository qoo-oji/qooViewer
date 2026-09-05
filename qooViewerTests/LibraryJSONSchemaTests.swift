import Foundation
import Testing

@testable import qooViewer

/// 保存データの書き出し / 読み込みのファイル形式(Services/LibraryJSONSchema.swift)。
///
/// このファイルは利用者が別のマシンへ持ち運ぶもので、**古い版で書き出したファイルが今の版で
/// 読めなくなったら、そこで保存データが失われる**。版 2(書誌メタデータとフォーマット定義が
/// 無い)で書き出したものが今も読めることと、読み方向・見開き・ページ状態が
/// **表示用の文字列ではない安定した識別子**で書かれていることを固定する。
///
/// 旧版の JSON はここに直接書く。中身が読めるテキストなので、バイナリのフィクスチャのように
/// 別ファイルにして台帳へ由来を書くより、期待値の隣に置くほうが分かりやすい。
struct LibraryJSONSchemaTests {
    private func decode(_ json: String) throws -> QooLibraryExportFile {
        try JSONDecoder().decode(QooLibraryExportFile.self, from: Data(json.utf8))
    }

    // MARK: - 安定した識別子

    @Test("読み方向・見開きは、表示用の文字列ではない安定した識別子で書く")
    func stableIdentifiersAreNotTheDisplayStrings() {
        // rawValue は "Right-to-Left" のような表示用文字列で、UI の文言を変えると壊れる。
        #expect(ReadingDirection.rightToLeft.stableID == "rightToLeft")
        #expect(ReadingDirection.leftToRight.stableID == "leftToRight")
        #expect(DisplayMode.single.stableID == "single")
        #expect(DisplayMode.spread.stableID == "spread")

        #expect(ReadingDirection(stableID: "rightToLeft") == .rightToLeft)
        #expect(DisplayMode(stableID: "spread") == .spread)
        // 知らない値は nil(=「未設定」として扱う)。
        #expect(ReadingDirection(stableID: "Right-to-Left") == nil)
        #expect(DisplayMode(stableID: "") == nil)
    }

    @Test("安定した識別子は往復する", arguments: ReadingDirection.allCases)
    func readingDirectionRoundTrips(direction: ReadingDirection) {
        #expect(ReadingDirection(stableID: direction.stableID) == direction)
    }

    @Test("ページ状態は PageLayoutState.rawValue をそのまま使う")
    func pageStateUsesTheLayoutStateRawValue() {
        #expect(PageLayoutState(rawValue: ExportedPageState(state: "spreadLeft").state) == .spreadLeft)
        #expect(PageLayoutState(rawValue: "excluded") == .excluded)
    }

    // MARK: - 往復

    @Test("いま書き出す形は、そのまま読み戻せる")
    func theCurrentShapeRoundTrips() throws {
        let file = QooLibraryExportFile(
            favorites: ExportedFavorites(
                folders: [ExportedFavoriteFolder(id: "f1", name: "作者A", parentId: nil),
                          ExportedFavoriteFolder(id: "f2", name: "続き", parentId: "f1")],
                books: [ExportedFavoriteBook(
                    bookID: "/books/a.cbz", inodeNumber: 12345, volumeDeviceNumber: 16777220,
                    title: "本 A", folderId: "f2"
                )]
            ),
            bookmarks: [ExportedBookmarkEntry(
                bookID: "/books/a.cbz", inodeNumber: 12345, volumeDeviceNumber: 16777220,
                bookmarks: [ExportedBookmark(page: "003.jpg", name: "第1章")]
            )],
            layouts: [ExportedBookLayoutEntry(
                bookID: "/books/a.cbz", inodeNumber: 12345, volumeDeviceNumber: 16777220,
                layout: ExportedBookLayout(
                    readingDirection: ReadingDirection.rightToLeft.stableID,
                    forcedDisplayMode: DisplayMode.spread.stableID,
                    pageOrder: ["002.jpg", "001.jpg"],
                    pages: ["002.jpg": ExportedPageState(state: "single")]
                )
            )],
            metadata: [ExportedBookMetadataEntry(
                bookID: "/books/a.cbz", inodeNumber: 12345, volumeDeviceNumber: 16777220,
                author: "作者", title: "本 A", series: "シリーズ", seriesIndex: "3"
            )],
            metadataFormats: ExportedMetadataFormats(
                filenameFormats: ["[@author] @title"],
                volumeNumberPatterns: [#"第([0-9]+)巻"#],
                seriesSeparatorPatterns: ["上巻|下巻"],
                exclusionPatterns: [#"\(20[0-9]{2}\)"#]
            )
        )

        let decoded = try JSONDecoder().decode(
            QooLibraryExportFile.self, from: try JSONEncoder().encode(file)
        )
        #expect(decoded.formatVersion == 3)
        #expect(decoded.favorites?.folders.map(\.id) == ["f1", "f2"])
        #expect(decoded.favorites?.folders.last?.parentId == "f1")
        #expect(decoded.favorites?.books.first?.folderId == "f2")
        #expect(decoded.favorites?.books.first?.fileNodeIdentifier
            == FileNodeIdentifier(inodeNumber: 12345, volumeDeviceNumber: 16777220))
        #expect(decoded.bookmarks?.first?.bookmarks.map(\.page) == ["003.jpg"])
        #expect(decoded.layouts?.first?.layout.pageOrder == ["002.jpg", "001.jpg"])
        #expect(decoded.layouts?.first?.layout.pages?["002.jpg"]?.state == "single")
        #expect(decoded.metadata?.first?.seriesIndex == "3")
        #expect(decoded.metadataFormats?.filenameFormats == ["[@author] @title"])
    }

    @Test("既定の formatVersion は 3")
    func theDefaultFormatVersionIsThree() {
        #expect(QooLibraryExportFile().formatVersion == 3)
    }

    // MARK: - 旧版のファイル

    @Test("版 2(メタデータの無い形)のファイルもそのまま読める")
    func aVersionTwoFileStillDecodes() throws {
        let file = try decode("""
        {
          "formatVersion": 2,
          "favorites": {
            "folders": [{"id": "f1", "name": "作者A"}],
            "books": [{"bookID": "/books/a.cbz", "title": "本 A", "folderId": "f1"}]
          },
          "bookmarks": [
            {"bookID": "/books/a.cbz", "bookmarks": [{"page": "003.jpg", "name": "第1章"}]}
          ],
          "layouts": [
            {"bookID": "/books/a.cbz",
             "layout": {"readingDirection": "rightToLeft",
                        "pages": {"002.jpg": {"state": "spreadLeft"}}}}
          ]
        }
        """)
        #expect(file.formatVersion == 2)
        #expect(file.favorites?.books.count == 1)
        // iノードを持たない版なので、照合はパスへ落ちる(呼び出し側の最終手段)。
        #expect(file.favorites?.books.first?.fileNodeIdentifier == nil)
        #expect(file.bookmarks?.first?.fileNodeIdentifier == nil)
        #expect(file.layouts?.first?.layout.forcedDisplayMode == nil)
        #expect(file.layouts?.first?.layout.pageOrder == nil)
        // 版 3 で足したキーは「含まれていない」= そのカテゴリは一切変更しない、という扱い。
        #expect(file.metadata == nil)
        #expect(file.metadataFormats == nil)
    }

    @Test("チェックを外した種類はキーごと無い(含まれていない、と読める)")
    func omittedCategoriesAreAbsentKeys() throws {
        let file = try decode(#"{"formatVersion": 3, "bookmarks": []}"#)
        #expect(file.favorites == nil)
        #expect(file.layouts == nil)
        #expect(file.metadata == nil)
        // 空配列は「含まれているが 1 件も無い」―― nil とは別の意味。
        #expect(file.bookmarks?.isEmpty == true)
    }

    @Test("書き出すときも、値の無い種類はキーを作らない")
    func encodingOmitsEmptyCategories() throws {
        var file = QooLibraryExportFile()
        file.bookmarks = []
        let json = try #require(String(data: try JSONEncoder().encode(file), encoding: .utf8))
        #expect(json.contains("\"bookmarks\""))
        #expect(!json.contains("\"favorites\""))
        #expect(!json.contains("\"metadata\""))
        #expect(!json.contains("\"metadataFormats\""))
    }

    @Test("ルールの id(UUID)は書き出さない")
    func metadataFormatsCarryOnlyThePatterns() throws {
        let formats = ExportedMetadataFormats(
            filenameFormats: ["[@author] @title"], volumeNumberPatterns: [],
            seriesSeparatorPatterns: [], exclusionPatterns: []
        )
        let json = try #require(String(data: try JSONEncoder().encode(formats), encoding: .utf8))
        #expect(!json.lowercased().contains("\"id\""))
    }
}
