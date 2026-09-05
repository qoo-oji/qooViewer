import Foundation
import Testing

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
}
