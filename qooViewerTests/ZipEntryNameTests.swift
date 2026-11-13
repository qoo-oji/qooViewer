import Foundation
import Testing
import ZIPFoundation

@testable import qooViewer

/// UTF-8 フラグの無い zip のファイル名を、書庫全体で 1 回だけ文字コード判定して戻す経路
/// (`ZipArchiveReader.indexEntries` → `EntryNameDecoder`)を、**reader の外側から**確かめる。
///
/// `EntryNameDecoder` は private のままにしてある ―― 判定そのものは Foundation
/// (`NSString.stringEncoding(for:)`)に委ねていて、OS の更新で結果が変わりうる。テストで固定すべきは
/// 「実際の書庫の名前がどう見えるか」であって、内部の判定手順ではない。
///
/// 既知の限界(EUC-JP / CP949 / 混在)は台帳側で `pageCount` にしてあり、ここでも件数だけを見る。
/// 詳細は docs/04「ファイル名の文字コード」と docs/13「既知の制限」。
struct ZipEntryNameTests {
    /// 台帳の zip/ のうち、開ける本になるもの。`zip-ditto.cbz` だけは `__MACOSX/._*` を含み
    /// listFilePaths と本のページが一致しないので、そちらは ArchiveReaderTests が見る。
    ///
    /// nonisolated: `@Test(arguments:)` の引数は Swift Testing がメインアクター外で評価する
    /// (`Fixtures` を nonisolated にしてあるのと同じ理由)。
    nonisolated static var paths: [String] {
        Fixtures.bookPaths.filter { path in
            guard path.hasPrefix("zip/"), path != "zip/zip-ditto.cbz" else { return false }
            return Fixtures.manifest.fixtures[path]?.book?.error == nil
        }
    }

    @Test("listFilePaths のファイル名が台帳と一致する", arguments: ZipEntryNameTests.paths)
    func entryNamesMatchLedger(path: String) throws {
        let expectation = try #require(Fixtures.manifest.fixtures[path]?.book)
        let reader = try ZipArchiveReader(url: Fixtures.url(path))
        let names = try reader.listFilePaths()
            .sorted { compareCanonicalPageOrder($0, $1) == .orderedAscending }

        if let sortKeys = expectation.sortKeys {
            #expect(names == sortKeys)
        } else if let pageCount = expectation.pageCount {
            // 既知の限界。名前は化けるが、件数と「落ちないこと」は固定する。
            #expect(names.count == pageCount)
        }
    }

    @Test("戻した名前でそのまま取り出せる(補正が一覧と読み出しで食い違わない)", arguments: ZipEntryNameTests.paths)
    func correctedNamesAreReadable(path: String) throws {
        let reader = try ZipArchiveReader(url: Fixtures.url(path))
        for name in try reader.listFilePaths() {
            let data = try reader.data(at: name)
            #expect(PageColorReader.number(in: data) != nil, "\(path) の \(name) が画像として読めない")
        }
    }

    @Test("UTF-8 のエントリは判定を挟まずそのまま(フラグの有無を問わない)")
    func utf8EntriesAreNotGuessed() throws {
        // フラグ無しでも、バイト列として UTF-8 と分かるものはエントリ単位で先に拾う。
        let noFlag = try ZipArchiveReader(url: Fixtures.url("zip/zip-utf8-noflag.zip"))
        #expect(try noFlag.listFilePaths().sorted() == ["日本語/001.png", "日本語/002.png", "日本語/003.png"])

        // UTF-8 のエントリは書庫全体の判定の標本にも混ぜない。混ぜると、CP932 と同居した書庫で
        // 「両方に化ける文字コード」が選ばれてしまう(EntryNameDecoder のコメント)。
        let mixed = try ZipArchiveReader(url: Fixtures.url("zip/zip-mixed-utf8-cp932.zip"))
        #expect(try mixed.listFilePaths().sorted() == [
            "a-日本語/001.png", "b-第1巻/001ページ.png", "b-第1巻/002ページ.png",
        ])
    }

    @Test("短い名前ばかりでも、書庫全体で 1 回判定すれば戻る")
    func shortNamesAreDecodedArchiveWide() throws {
        // 1 件ずつ判定していた頃は windows-1254/1257 などに外れていた(docs/04)。
        let reader = try ZipArchiveReader(url: Fixtures.url("zip/zip-cp932-short-names.zip"))
        #expect(try reader.listFilePaths().sorted() == ["あ.png", "い.png", "う.png"])
    }

    @Test("同じパスのエントリが 2 つあれば先のものを読む(rar / 7z と同じ。展開で 1 つ目の名前に 2 つ目の中身を書かない)")
    func duplicatePathsReadTheFirstEntry() async throws {
        let temporary = try TemporaryDirectory("zip-duplicates")
        var builder = ZipFixtureBuilder()
        builder.add("a.txt", text: "first")
        builder.add("a.txt", text: "second")
        let url = temporary.file("dup.zip")
        try builder.write(to: url)
        let reader = try ZipArchiveReader(url: url)
        #expect(try reader.listFilePaths() == ["a.txt"])
        #expect(String(decoding: try reader.data(at: "a.txt"), as: UTF8.self) == "first")
        #expect(try reader.entriesInArchiveOrder().map(\.path) == ["a.txt", "a.txt"])

        let service = FileOperationService(environment: .pseudoTrash(at: try temporary.directory("PseudoTrash")))
        let destination = try temporary.directory("out")
        _ = try await service.extract([url], into: destination, placement: .contents, limits: .standard, progress: nil, cancellation: Cancellation())
        #expect(String(decoding: try Data(contentsOf: destination.appendingPathComponent("a.txt")), as: UTF8.self) == "first")
    }
}

/// Info-ZIP Unicode Path 拡張欄(0x7075、APPNOTE 4.6.9)を、本で使う reader(`makeArchiveReader` → `CentralDirectoryZipReader`)で
/// 確かめる(2026-11-13)。ZIPFoundation はこの欄を読まないので、ここだけは基準の `ZipArchiveReader` と答えが違う(型コメントの
/// 「違い」の 3 つ目)。
///
/// きっかけの書庫は、CP932 の名前で日本語が全エントリ共通のフォルダ名(カタカナ 7 文字)だけ、残りが英数字だった。Foundation の
/// 判定は Windows-1254(トルコ語)を返し、1 バイトの文字コードはどのバイト列も読めてしまうので検証も通り、全ページの名前が化けた。
/// 下の `katakanaFolder` は同じ形の合成名(macOS 27 で同じく Windows-1254 に外れることを確かめてある。判定は OS で変わりうるので、
/// 欄の無いときの化け方そのものは固定しない)。
struct ZipUnicodePathFieldTests {
    private static let katakanaFolder = "テストフォルダ"

    private func reader(_ builder: LegacyZipBuilder) throws -> ArchiveReading {
        try makeArchiveReader(kind: .zip, data: builder.build())
    }

    /// CP932 の名前に、正しい Unicode Path 拡張欄を添えたエントリ。
    private func addCP932WithField(_ builder: inout LegacyZipBuilder, _ name: String, _ text: String) {
        let raw = name.data(using: .shiftJIS)!
        builder.add(rawName: raw, data: Data(text.utf8), extra: LegacyZipBuilder.unicodePathField(name, crcOf: raw))
    }

    @Test("CP932 の名前に Unicode Path 拡張欄があれば、推定せずに欄の名前を使う")
    func theFieldWinsOverTheGuess() throws {
        var builder = LegacyZipBuilder()
        let names = (1...5).map { String(format: "\(Self.katakanaFolder)/%03d.jpg", $0) }
        for (i, name) in names.enumerated() { addCP932WithField(&builder, name, "page\(i)") }
        let reader = try reader(builder)
        #expect(try reader.listFilePaths().sorted() == names)
        #expect(try reader.entriesInArchiveOrder().map(\.path) == names)
        // 一覧の名前でそのまま読める(一覧と読み出しの食い違いが無い)。
        #expect(String(decoding: try reader.data(at: names[2]), as: UTF8.self) == "page2")
    }

    @Test("ディレクトリのエントリも欄の名前になる(末尾の / はそのまま)")
    func directoryEntriesUseTheField() throws {
        var builder = LegacyZipBuilder()
        let folder = Self.katakanaFolder + "/"
        let rawFolder = folder.data(using: .shiftJIS)!
        builder.add(rawName: rawFolder, data: Data(), extra: LegacyZipBuilder.unicodePathField(folder, crcOf: rawFolder))
        addCP932WithField(&builder, Self.katakanaFolder + "/001.jpg", "a")
        let entries = try reader(builder).entriesInArchiveOrder()
        #expect(entries.map(\.path) == [folder, Self.katakanaFolder + "/001.jpg"])
        #expect(entries.map(\.kind) == [.directory, .file])
    }

    @Test("CRC が元の名前と合わない欄は使わない(名前を書き換えた道具が古い欄を残した書庫)")
    func aStaleFieldIsIgnored() throws {
        // 推定で確実に戻る名前(zip-cp932-noflag.zip と同じ)にして、欄を使わなかったことを推定の答えで確かめる。
        let name = "第1巻/001ページ.png"
        let raw = name.data(using: .shiftJIS)!
        var builder = LegacyZipBuilder()
        builder.add(rawName: raw, data: Data("a".utf8),
                    extra: LegacyZipBuilder.unicodePathField("stale/001.png", crcOf: Data("old name".utf8)))
        #expect(try reader(builder).listFilePaths() == [name])
    }

    @Test("版が 1 でない欄は使わない")
    func anUnknownVersionIsIgnored() throws {
        let name = "第1巻/001ページ.png"
        let raw = name.data(using: .shiftJIS)!
        var builder = LegacyZipBuilder()
        builder.add(rawName: raw, data: Data("a".utf8),
                    extra: LegacyZipBuilder.unicodePathField("other/001.png", crcOf: raw, version: 2))
        #expect(try reader(builder).listFilePaths() == [name])
    }

    @Test("UTF-8 フラグのあるエントリは欄を見ない(名前そのものが UTF-8)")
    func theFlagWinsOverTheField() throws {
        let name = "日本語/001.png"
        let raw = Data(name.utf8)
        var builder = LegacyZipBuilder()
        builder.add(rawName: raw, data: Data("a".utf8), utf8Flag: true,
                    extra: LegacyZipBuilder.unicodePathField("other/001.png", crcOf: raw))
        #expect(try reader(builder).listFilePaths() == [name])
    }

    @Test("末尾の / が名前と食い違う欄は使わない(ファイルとディレクトリの判定は元の名前で決まる)")
    func aFieldThatChangesTheKindIsIgnored() throws {
        let name = "第1巻/001ページ.png"
        let raw = name.data(using: .shiftJIS)!
        var builder = LegacyZipBuilder()
        builder.add(rawName: raw, data: Data("a".utf8), extra: LegacyZipBuilder.unicodePathField("dir/", crcOf: raw))
        #expect(try reader(builder).listFilePaths() == [name])
    }

    @Test("欄のあるエントリは推定の標本に入れない(欄の無いエントリの判定は欄の無いものだけで決まる)")
    func entriesWithTheFieldAreLeftOutOfTheGuess() throws {
        // 欄のある CP932 のエントリと、欄の無い CP932 のエントリ。欄の無い方は zip-cp932-noflag.zip と同じ名前で、
        // 単独で推定すれば戻る。
        var builder = LegacyZipBuilder()
        addCP932WithField(&builder, Self.katakanaFolder + "/001.jpg", "a")
        let plain = ["第1巻/001ページ.png", "第1巻/002ページ.png", "第1巻/表紙.png"]
        for name in plain { builder.add(name, encoding: .shiftJIS, data: Data("b".utf8)) }
        #expect(try reader(builder).listFilePaths().sorted() == ([Self.katakanaFolder + "/001.jpg"] + plain).sorted())
    }

    @Test("名前が ASCII に置き換えられていても、欄があれば欄の名前を使う")
    func anASCIIPlaceholderNameUsesTheField() throws {
        // 名前を表せない文字コードで書いた道具は「?」や「_」に置き換え、本当の名前を欄に入れる。
        let raw = Data("_______/001.jpg".utf8)
        var builder = LegacyZipBuilder()
        builder.add(rawName: raw, data: Data("a".utf8),
                    extra: LegacyZipBuilder.unicodePathField(Self.katakanaFolder + "/001.jpg", crcOf: raw))
        #expect(try reader(builder).listFilePaths() == [Self.katakanaFolder + "/001.jpg"])
    }

    @Test("壊れた欄(大きさが拡張欄の外まで続く・中身が短い・UTF-8 でない)で落ちず、推定へ落ちる")
    func malformedFieldsFallBackToTheGuess() throws {
        let name = "第1巻/001ページ.png"
        let raw = name.data(using: .shiftJIS)!
        let crc = raw.crc32(checksum: 0)
        let crcBytes = Data([UInt8(crc & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 24)])
        let malformed: [Data] = [
            Data([0x75, 0x70, 0xFF, 0x00, 0x01]),                       // 大きさ 255 だが中身は 1 バイト
            Data([0x75, 0x70, 0x05, 0x00, 0x01]) + crcBytes,            // 名前が空
            Data([0x75, 0x70, 0x07, 0x00, 0x01]) + crcBytes + Data([0xFF, 0xFE]), // UTF-8 でない
            Data([0x75, 0x70, 0x02, 0x00, 0x01, 0x00]),                 // CRC の途中で終わる
        ]
        for extra in malformed {
            var builder = LegacyZipBuilder()
            builder.add(rawName: raw, data: Data("a".utf8), extra: extra)
            #expect(try reader(builder).listFilePaths() == [name])
        }
    }
}
