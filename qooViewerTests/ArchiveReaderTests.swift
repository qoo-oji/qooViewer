import Foundation
import Testing

@testable import qooViewer

/// `ArchiveReading` の適合テスト。zip / 7z / rar の 3 実装が、**同じ問いに同じ形で答える**ことを
/// 台帳(manifest.json の `archive`)と突き合わせて確かめる。
///
/// 入力はファイルとメモリ上の `Data` の両方を通す ―― 入れ子の書庫は予算に収まればメモリから開く
/// 経路になる(`ArchiveKind.opensFromMemory` / `NestedArchiveResolver.materialize`)ので、そちらだけ
/// 壊れても気付けるようにしておく。ページ画像には番号が色として埋まっている(`PageImageFactory`)ので、
/// 取り出したバイト列が本当にそのエントリのものかを中身で確かめられる。
struct ArchiveReaderTests {

    // MARK: - 一覧

    @Test(
        "listFilePaths は台帳のエントリと一致する(ディレクトリエントリは含まない)",
        arguments: Fixtures.archivePaths, FixtureArchive.Input.allCases
    )
    func listFilePaths(path: String, input: FixtureArchive.Input) throws {
        let expectation = Fixtures.archiveExpectation(path)
        let reader = try FixtureArchive.reader(path, input: input)
        // listFilePaths は順序を約束しない(zip は辞書の順)ので、名前で並べてから比べる。
        #expect(try reader.listFilePaths().sorted() == expectation.sortedPaths)
    }

    // MARK: - 取り出し

    @Test(
        "data(at:) は台帳どおりのページ画像を返す",
        arguments: Fixtures.archivePaths, FixtureArchive.Input.allCases
    )
    func dataMatchesLedger(path: String, input: FixtureArchive.Input) throws {
        let expectation = Fixtures.archiveExpectation(path)
        let reader = try FixtureArchive.reader(path, input: input)

        for entryPath in expectation.imagePaths {
            guard let number = expectation.entries[entryPath] else { continue }
            if expectation.encrypted == true {
                // 暗号化された書庫は一覧まで。取り出しは失敗するのが正しい(パスワード非対応)。
                #expect(throws: (any Error).self) { _ = try reader.data(at: entryPath) }
                continue
            }
            let data = try reader.data(at: entryPath)
            #expect(!data.isEmpty)
            #expect(
                PageColorReader.matches(data, number: number),
                "\(entryPath) の中身が台帳の番号 \(number) と違う(読めた番号: \(PageColorReader.number(in: data).map(String.init) ?? "nil"))"
            )
            #expect(reader.entryUncompressedSize(at: entryPath) == Int64(data.count))
        }
    }

    @Test("無いエントリは entryNotFound、日付は両方 nil", arguments: Fixtures.archivePaths)
    func missingEntry(path: String) throws {
        let reader = try FixtureArchive.reader(path)
        #expect(throws: ArchiveReaderError.entryNotFound) { _ = try reader.data(at: "no/such/entry.png") }
        #expect(throws: ArchiveReaderError.entryNotFound) {
            _ = try reader.dataPrefix(at: "no/such/entry.png", maxByteCount: 8)
        }
        let dates = reader.entryDates(at: "no/such/entry.png")
        #expect(dates.created == nil)
        #expect(dates.modified == nil)
        #expect(reader.entryUncompressedSize(at: "no/such/entry.png") == nil)
    }

    // MARK: - dataPrefix

    /// 先頭だけを読む経路。**打ち切れるかどうかは形式で違う**(プロトコルの既定実装は全体読み)ので、
    /// 「返ったものは必ず全体の先頭で、必要なぶんは含む」までを共通の約束として押さえ、
    /// 実際に打ち切るのはどれかは下の test で名指しで固定する。
    @Test("dataPrefix は全体の先頭を返す", arguments: Fixtures.archivePaths)
    func dataPrefixIsPrefix(path: String) throws {
        let expectation = Fixtures.archiveExpectation(path)
        guard expectation.encrypted != true, let entryPath = expectation.imagePaths.first else { return }
        let reader = try FixtureArchive.reader(path)
        let whole = try reader.data(at: entryPath)

        for maxByteCount in [1, 8, whole.count, whole.count + 64] {
            let prefix = try reader.dataPrefix(at: entryPath, maxByteCount: maxByteCount)
            #expect(prefix.count >= min(maxByteCount, whole.count))
            #expect(prefix.count <= whole.count)
            #expect(whole.starts(with: prefix))
        }
        // 打ち切った後でも、同じエントリを最後まで読み直せる(7z のソリッドブロックでも)。
        #expect(try reader.data(at: entryPath) == whole)
    }

    /// 打ち切りは**伸長のチャンク単位**なので、「8 バイト頼んだら 8 バイト返る」とは限らない
    /// (zip も 7z も、フィクスチャ程度の大きさなら 1 チャンクで全体が届く)。実際に途中で止まるか
    /// どうかは、この大きさのフィクスチャでは観測できない ―― ここで固定できるのは上の
    /// 「全体の先頭であること」までで、打ち切りの効き目は実物の本での実測の話
    /// (docs/05「ページの寸法を先読みする」)。
    @Test("dataPrefix に 0 を渡したら空(zip の早期リターン)")
    func dataPrefixOfZero() throws {
        let reader = try FixtureArchive.reader("zip/zip-zipcli.cbz")
        #expect(try reader.dataPrefix(at: "cover.png", maxByteCount: 0).isEmpty)
    }

    // MARK: - 更新日時

    /// 形式ごとに持っている情報が違う(`ArchiveReading.entryDates(at:)`)。zip は更新日時だけ、
    /// rar は作成日時も持つ。
    ///
    /// **7z は今のところどちらも取れない(既知の限界、2026-09-05 にこのテストで発見)。**
    /// 書庫自体は更新日時を持っている(`7zz l -slt` で見える)が、SevenZip.swift の
    /// `Archive.init` が `SzBitWithVals_Check(&db.MTime, i) == 0`(=「値が**無い**とき」)を
    /// 「値がある」と取り違えていて、常に nil になる。フォーク側の修正が要るので、直すまでは
    /// 今の振る舞いを固定しておく(→ docs/11「これから直すもの」、docs/13「既知の制限」)。
    @Test("entryDates: 更新日時は zip / rar で取れ、作成日時は rar だけ(7z はどちらも取れない)")
    func entryDates() throws {
        let cases: [(path: String, entry: String, hasModified: Bool, hasCreated: Bool)] = [
            ("zip/zip-zipcli.cbz", "cover.png", true, false),
            ("rar/rar-flat.cbr", "001.jpg", true, true),
            ("7z/7z-flat.cb7", "001.jpg", false, false),
        ]
        for (path, entry, hasModified, hasCreated) in cases {
            let dates = try FixtureArchive.reader(path).entryDates(at: entry)
            #expect((dates.modified != nil) == hasModified, "\(path) の更新日時: \(String(describing: dates.modified))")
            #expect((dates.created != nil) == hasCreated, "\(path) の作成日時: \(String(describing: dates.created))")
        }
    }

    // MARK: - ファイルへの書き出し

    @Test("extract は data(at:) と同じバイト列を書く", arguments: Fixtures.archivePaths)
    func extractWritesSameBytes(path: String) throws {
        let expectation = Fixtures.archiveExpectation(path)
        guard expectation.encrypted != true, let entryPath = expectation.imagePaths.first else { return }
        let reader = try FixtureArchive.reader(path)
        let whole = try reader.data(at: entryPath)

        let temp = try TemporaryDirectory("extract")
        let destination = temp.file("out.bin")
        try reader.extract(at: entryPath, to: destination, maxByteCount: whole.count)
        #expect(try Data(contentsOf: destination) == whole)
    }

    /// 索引の申告より実体が大きい(細工された・壊れた)書庫を、上限で止められること。
    /// **書きかけのファイルを残さない**ところまでが約束(NestedArchiveResolver が一時ファイルの
    /// 所有権を渡す前提にしている)。
    @Test("extract は上限を超えたら entryTooLarge で止まり、書きかけを残さない", arguments: Fixtures.archivePaths)
    func extractStopsAtLimit(path: String) throws {
        let expectation = Fixtures.archiveExpectation(path)
        guard expectation.encrypted != true, let entryPath = expectation.imagePaths.first else { return }
        let reader = try FixtureArchive.reader(path)
        let whole = try reader.data(at: entryPath)

        let temp = try TemporaryDirectory("extract-limit")
        let destination = temp.file("out.bin")
        #expect(throws: ArchiveReaderError.entryTooLarge) {
            try reader.extract(at: entryPath, to: destination, maxByteCount: whole.count - 1)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path), "書きかけのファイルが残っている")
    }

    // MARK: - ソリッド書庫

    /// ソリッドな 7z / rar を、書庫順に最後まで読み切れること。7z のフォーク(streaming-extract)は
    /// 「最後に読んだブロックのデコーダ」を持ち回るので、書庫順なら伸長は 1 回で済む
    /// (SevenZipArchiveReader の型コメント)。ここが壊れると、読めなくなるのではなく**遅くなる**
    /// ため、中身が全ページ正しいことだけは必ず押さえておく。
    @Test(
        "ソリッド書庫を書庫順に読み切れる",
        arguments: ["7z/7z-solid.cb7", "7z/7z-solid-lzma1.7z", "7z/7z-store.7z", "rar/rar-solid.cbr"]
    )
    func solidArchiveInOrder(path: String) throws {
        let expectation = Fixtures.archiveExpectation(path)
        let reader = try FixtureArchive.reader(path)
        for entryPath in expectation.imagePaths {
            let number = try #require(expectation.entries[entryPath])
            #expect(PageColorReader.matches(try reader.data(at: entryPath), number: number), "\(entryPath)")
        }
    }

    /// 逆順(= ソリッドブロックの後方読み)でも結果は正しいこと。7z はブロック先頭からやり直しに
    /// なりうるが、それは速さの話で、返るバイト列は同じでなければならない。
    @Test("ソリッド書庫を逆順に読んでも中身は同じ", arguments: ["7z/7z-solid.cb7", "rar/rar-solid.cbr"])
    func solidArchiveReversed(path: String) throws {
        let expectation = Fixtures.archiveExpectation(path)
        let reader = try FixtureArchive.reader(path)
        for entryPath in expectation.imagePaths.reversed() {
            let number = try #require(expectation.entries[entryPath])
            #expect(PageColorReader.matches(try reader.data(at: entryPath), number: number), "\(entryPath)")
        }
    }

    /// リソースモニタに出す「ライブラリの中に居座っている展開用メモリ」
    /// (`ArchiveReading.residentDecompressionBufferBytes`)。zip / rar はチャンクごとに読み捨てる
    /// ので常に 0。7z は LZMA 辞書を抱えるため 0 にはならない。
    @Test("residentDecompressionBufferBytes は zip / rar が 0、7z は非 0")
    func residentDecompressionBuffer() throws {
        for path in ["zip/zip-zipcli.cbz", "rar/rar-solid.cbr"] {
            let reader = try FixtureArchive.reader(path)
            let entry = try #require(Fixtures.archiveExpectation(path).imagePaths.first)
            _ = try reader.data(at: entry)
            #expect(reader.residentDecompressionBufferBytes == 0, "\(path)")
        }
        let sevenZip = try FixtureArchive.reader("7z/7z-solid.cb7")
        #expect(sevenZip.residentDecompressionBufferBytes == 0, "1 ページも読む前は 0")
        _ = try sevenZip.data(at: "001.png")
        #expect(sevenZip.residentDecompressionBufferBytes > 0, "読んだ後は LZMA 辞書を抱えている")
    }

    // MARK: - 暗号化

    @Test("暗号化された rar: 一覧は読めるが取り出しは失敗する")
    func encryptedArchive() throws {
        let reader = try FixtureArchive.reader("rar/rar-encrypted.cbr")
        #expect(try reader.listFilePaths().sorted() == ["001.jpg", "002.jpg", "003.jpg"])
        #expect(throws: (any Error).self) { _ = try reader.data(at: "001.jpg") }
    }

    // MARK: - 開けないもの

    @Test("書庫として開けないファイルは cannotOpen ではなくライブラリのエラーで落ちる(落ちない)")
    func unreadableArchives() throws {
        for path in ["zip/zip-not-a-zip.cbz", "zip/zip-truncated.cbz"] {
            #expect(throws: (any Error).self, "開けてしまった: \(path)") {
                _ = try FixtureArchive.reader(path)
            }
        }
        // 拡張子が書庫のものでなければ、そもそも Reader を選べない。
        #expect(throws: ArchiveReaderError.cannotOpen) {
            _ = try makeArchiveReader(for: Fixtures.url("pdf/pdf-plain.pdf"))
        }
    }
}
