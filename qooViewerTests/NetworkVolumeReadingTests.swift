import CoreGraphics
import Foundation
import Testing
import ZIPFoundation

@testable import qooViewer

/// ネットワークボリューム上の書庫の読み方(docs/plans/network-volume-study.md)。
///
/// - `CentralDirectoryZipReader` が `ZipArchiveReader`(ZIPFoundation)と**同じ答え**を返すこと(ページのキーが変わらない)。
///   コミット済みのフィクスチャの zip 全件と、ここで組み立てる境界ケース(ZIP64・暗号化・コメント・先頭のゴミ・データ記述子)。
/// - 読み込み層(`StagedFileSource`)が、どんな読み方でもファイルと同じバイト列を返し、揃ったら後片付けすること。
/// - 「ネットワーク上」とみなした本が、ローカルと同じページ一覧・同じページのバイト列で開けること。
///
/// 実物のネットワークボリュームは使えないので、作業フォルダを `NetworkVolumeReading.treatAsRemoteForTesting` で見立てる。
struct NetworkVolumeReadingTests {

    // MARK: - 中央ディレクトリの reader と ZIPFoundation の一致

    /// フィクスチャのうち zip コンテナのもの(cbz・zip・epub。入れ子の本の外側を含む)。
    nonisolated static let zipFixturePaths: [String] = Fixtures.manifest.fixtures.keys
        .filter { ["zip", "cbz", "epub"].contains(($0 as NSString).pathExtension.lowercased()) }
        .sorted()

    @Test("コミット済みの zip 系フィクスチャで、ZIPFoundation と同じ答えを返す", arguments: zipFixturePaths)
    func matchesZIPFoundationOnFixtures(path: String) throws {
        try expectSameAnswers(Fixtures.url(path))
    }

    @Test("境界ケース: ZIP64・コメント・データ記述子・ディレクトリと記号リンク・同名・deflate/格納の混在")
    func matchesZIPFoundationOnBuiltEdgeCases() throws {
        let folder = try TemporaryDirectory("cdzip-edge")
        let payload = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

        var builder = ZipFixtureBuilder()
        builder.addDirectory("chapter")
        builder.add("chapter/001.jpg", payload, stored: true)
        builder.add("chapter/002.jpg", Data(payload.reversed()), stored: false)
        builder.add("empty.jpg", Data(), stored: true)
        builder.addSymbolicLink("link.jpg", target: "chapter/001.jpg")
        let zipFoundationMade = folder.file("zipfoundation.cbz")
        try builder.write(to: zipFoundationMade)
        try expectSameAnswers(zipFoundationMade)

        // ZIP64 の欄(0xFFFFFFFF + 拡張欄)を持つ小さな書庫。ZIPFoundation は 4GB を超えないと ZIP64 で書かないので手で組む。
        // 先頭のエントリだけは通常の欄にする(先頭の位置 0 は拡張欄では「無い」と読まれる ―― 次のケース)。
        var zip64 = RawZipWriter()
        zip64.add("000.jpg", Data(repeating: 7, count: 5))
        zip64.add("001.jpg", payload, zip64: true)
        zip64.add("002.jpg", Data(repeating: 9, count: 10), zip64: true)
        let zip64URL = folder.file("zip64.cbz")
        try zip64.write(to: zip64URL, zip64EndRecord: true)
        try expectSameAnswers(zip64URL)
        #expect(try CentralDirectoryZipReader(source: LocalFileSource(url: zip64URL)).listFilePaths().sorted()
                == ["000.jpg", "001.jpg", "002.jpg"])
        // 先頭のエントリを ZIP64 の欄で書くと、拡張欄の位置 0 は使われず 0xFFFFFFFF を読みに行って一覧が止まる(ZIPFoundation)。
        // こちらも読まずに同じところで止まる。
        var zip64First = RawZipWriter()
        zip64First.add("001.jpg", payload, zip64: true)
        zip64First.add("002.jpg", Data(repeating: 9, count: 10), zip64: true)
        let zip64FirstURL = folder.file("zip64-first.cbz")
        try zip64First.write(to: zip64FirstURL, zip64EndRecord: true)
        try expectSameAnswers(zip64FirstURL)

        // 書庫のコメント付き、先頭にゴミ付き(自己展開形式の形。オフセットがずれるので両方とも読めない ―― それも一致)。
        var commented = RawZipWriter()
        commented.add("001.jpg", payload)
        let commentedURL = folder.file("commented.cbz")
        try commented.write(to: commentedURL, comment: Data("a comment".utf8))
        try expectSameAnswers(commentedURL)
        let prefixedURL = folder.file("prefixed.cbz")
        try (Data(repeating: 0x41, count: 1000) + (try Data(contentsOf: commentedURL))).write(to: prefixedURL)
        try expectSameAnswers(prefixedURL)

        // 同じパスのエントリが 2 つ(先のものを採る)。
        var duplicated = RawZipWriter()
        duplicated.add("same.jpg", Data("first".utf8))
        duplicated.add("same.jpg", Data("second-content".utf8))
        let duplicatedURL = folder.file("duplicated.cbz")
        try duplicated.write(to: duplicatedURL)
        try expectSameAnswers(duplicatedURL)
        #expect(try CentralDirectoryZipReader(source: LocalFileSource(url: duplicatedURL)).data(at: "same.jpg") == Data("first".utf8))

        // 暗号化フラグの立ったエントリがあると、そこで一覧が止まる(ZIPFoundation と同じ)。
        var encrypted = RawZipWriter()
        encrypted.add("001.jpg", payload)
        encrypted.add("002.jpg", payload, encrypted: true)
        encrypted.add("003.jpg", payload)
        let encryptedURL = folder.file("encrypted.cbz")
        try encrypted.write(to: encryptedURL)
        try expectSameAnswers(encryptedURL)
        #expect(try CentralDirectoryZipReader(source: LocalFileSource(url: encryptedURL)).listFilePaths() == ["001.jpg"])
    }

    @Test("意図した違い: 途中のローカルヘッダーだけが壊れた書庫は、一覧に含めて取り出しで失敗する")
    func corruptLocalHeaderIsListedButFailsToRead() throws {
        let folder = try TemporaryDirectory("cdzip-corrupt")
        var writer = RawZipWriter()
        writer.add("001.jpg", Data(repeating: 1, count: 100))
        writer.add("002.jpg", Data(repeating: 2, count: 100))
        writer.add("003.jpg", Data(repeating: 3, count: 100))
        let url = folder.file("corrupt.cbz")
        try writer.write(to: url)
        var bytes = try Data(contentsOf: url)
        // 2 つ目のローカルヘッダーの署名を壊す(中央ディレクトリはそのまま)。
        let second = try #require(bytes.range(of: Data([0x50, 0x4B, 0x03, 0x04]), in: 1..<bytes.count))
        bytes[second.lowerBound] = 0
        try bytes.write(to: url)

        // ZIPFoundation はそこで一覧を打ち切る。
        #expect(try ZipArchiveReader(url: url).listFilePaths().sorted() == ["001.jpg"])
        // こちらは中央ディレクトリどおりに並べ、壊れたエントリだけ読めない。
        let reader = try CentralDirectoryZipReader(source: LocalFileSource(url: url))
        #expect(try reader.listFilePaths().sorted() == ["001.jpg", "002.jpg", "003.jpg"])
        #expect(try reader.data(at: "001.jpg") == Data(repeating: 1, count: 100))
        #expect(throws: (any Error).self) { try reader.data(at: "002.jpg") }
        #expect(try reader.data(at: "003.jpg") == Data(repeating: 3, count: 100))
    }

    @Test("zip ではないファイルは末尾の窓だけ読んで諦める(ファイル全体を読まない・メモリに載せない)")
    func nonZipFileReadsOnlyTheTail() throws {
        // 2026-09-27 の監査: 以前は EOCD を先頭まで探し、窓の外を 1MB ずつ読んで前へ連結していた(中身が RAR の .cbz・途中までの
        // zip で、ファイル全体の取り寄せと、大きさの 2 乗の写し)。
        let folder = try TemporaryDirectory("cdzip-notzip")
        let url = folder.file("not-a-zip.cbz")
        try Data(repeating: 0x41, count: 4 << 20).write(to: url)
        let source = CountingSource(try LocalFileSource(url: url))
        #expect(throws: (any Error).self) { _ = try CentralDirectoryZipReader(source: source) }
        #expect(source.bytesRequested <= 128 * 1024, "\(source.bytesRequested) バイト読んだ")
    }

    @Test("意図した違い: 末尾に 64KB を超えるゴミが付いた zip は開かない(ZIPFoundation は先頭まで探して開く)")
    func trailingGarbageBeyondCommentLimitIsNotAZip() throws {
        let folder = try TemporaryDirectory("cdzip-trailing")
        var writer = RawZipWriter()
        writer.add("001.jpg", Data(repeating: 1, count: 100))
        let zipURL = folder.file("plain.cbz")
        try writer.write(to: zipURL)
        let url = folder.file("trailing.cbz")
        try (try Data(contentsOf: zipURL) + Data(repeating: 0x41, count: 70_000)).write(to: url)
        #expect(try ZipArchiveReader(url: url).listFilePaths() == ["001.jpg"])
        #expect(throws: (any Error).self) { _ = try CentralDirectoryZipReader(source: LocalFileSource(url: url)) }
    }

    @Test("細工された ZIP64 の値(上限近くの位置・大きさ)で落ちない")
    func craftedZIP64ValuesDoNotTrap() throws {
        // 2026-09-27 の監査: 位置 + 長さ・`Int64(大きさ)` が UInt64 / Int64 であふれて trap していた。
        let folder = try TemporaryDirectory("cdzip-crafted")
        // 0x07 は deflate として読むと「予約されたブロック型」(BTYPE=11)で、伸長は必ず失敗する(偶然伸長できて通らないように)。
        let payload = Data(repeating: 7, count: 64)

        // ローカルヘッダーの位置が上限近く → 一覧はそこで止まる。
        var offsetWriter = RawZipWriter()
        offsetWriter.add("000.jpg", payload)
        offsetWriter.add("001.jpg", payload, zip64: true, centralZIP64: (64, 64, UInt64.max - 10))
        let offsetURL = folder.file("offset.cbz")
        try offsetWriter.write(to: offsetURL)
        #expect(try CentralDirectoryZipReader(source: LocalFileSource(url: offsetURL)).listFilePaths() == ["000.jpg"])

        // 圧縮サイズが Int64 の上限を超え、ローカルヘッダーは deflate → 取り出しは失敗するだけ。
        var sizeWriter = RawZipWriter()
        sizeWriter.add("000.jpg", payload)
        sizeWriter.add("001.jpg", payload, zip64: true, centralZIP64: (64, UInt64.max, nil), localMethod: 8)
        let sizeURL = folder.file("size.cbz")
        try sizeWriter.write(to: sizeURL)
        let sizeReader = try CentralDirectoryZipReader(source: LocalFileSource(url: sizeURL))
        #expect(throws: (any Error).self) { try sizeReader.data(at: "001.jpg") }
        #expect(try sizeReader.data(at: "000.jpg") == payload)

        // ZIP64 の終わりのレコードが指す中央ディレクトリの位置が上限近く → 本は空(落ちない)。
        var cdWriter = RawZipWriter()
        cdWriter.add("000.jpg", payload)
        let cdURL = folder.file("cd.cbz")
        try cdWriter.write(to: cdURL, zip64EndRecord: true, zip64CentralOffset: UInt64.max - 5)
        #expect(try CentralDirectoryZipReader(source: LocalFileSource(url: cdURL)).listFilePaths().isEmpty)
    }

    @Test("rar: 読み込み層の読みが途中で失敗したら、短い一覧ではなくエラーになる", arguments: ["rar/rar-flat.cbr", "rar/rar-solid.cbr"])
    func rarReadFailureIsAnErrorNotAShorterList(path: String) throws {
        // 2026-09-27 の監査: unrar は読み取りの失敗を「書庫がそこで終わった」として扱い、ページの少ない本として開いていた
        // (「中身が差し替わった本」と判断されて読書位置・ブックマークが消え、短い一覧が構造キャッシュに残った)。
        let url = Fixtures.url(path)
        let full = try RarArchiveReader(source: LocalFileSource(url: url)).listFilePaths()
        #expect(full.count > 1)
        let failing = FailingSource(try LocalFileSource(url: url), failsFrom: try LocalFileSource(url: url).size / 2)
        #expect(throws: ArchiveReaderError.readFailed) { _ = try RarArchiveReader(source: failing) }

        // 一覧を取った後に失敗し始めた場合も、ページの読みは(途中までのデータではなく)エラーになる。
        let later = FailingSource(try LocalFileSource(url: url), failsFrom: .max)
        let reader = try RarArchiveReader(source: later)
        #expect(try reader.listFilePaths().sorted() == full.sorted())
        later.failsFrom = 0
        #expect(throws: ArchiveReaderError.readFailed) { _ = try reader.data(at: full.sorted().last!) }
    }

    /// 2 つの reader の答えをすべて突き合わせる。開けるかどうかも一致させる。
    private func expectSameAnswers(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let expected: ZipArchiveReader
        do {
            expected = try ZipArchiveReader(url: url)
        } catch {
            #expect(throws: (any Error).self, "ZIPFoundation は開けないのに開けた: \(url.lastPathComponent)", sourceLocation: sourceLocation) {
                _ = try CentralDirectoryZipReader(source: LocalFileSource(url: url))
            }
            return
        }
        let actual = try CentralDirectoryZipReader(source: StagedFileSource(url: url))
        let paths = try expected.listFilePaths().sorted()
        #expect(try actual.listFilePaths().sorted() == paths, sourceLocation: sourceLocation)
        let actualEntries = try actual.entriesInArchiveOrder(), expectedEntries = try expected.entriesInArchiveOrder()
        #expect(actualEntries == expectedEntries, "\(actualEntries) vs \(expectedEntries)", sourceLocation: sourceLocation)
        for path in paths {
            #expect(actual.entryUncompressedSize(at: path) == expected.entryUncompressedSize(at: path), sourceLocation: sourceLocation)
            let expectedDates = expected.entryDates(at: path), actualDates = actual.entryDates(at: path)
            #expect(actualDates.created == expectedDates.created && actualDates.modified == expectedDates.modified,
                    sourceLocation: sourceLocation)
            let full = try? expected.data(at: path)
            #expect((try? actual.data(at: path)) == full, "\(path)", sourceLocation: sourceLocation)
            var streamed = Data()
            let streamedOK = (try? actual.readEntry(at: path) { streamed.append($0) }) != nil
            #expect(streamedOK == (full != nil), sourceLocation: sourceLocation)
            if let full {
                if streamedOK { #expect(streamed == full, "readEntry \(path)", sourceLocation: sourceLocation) }
                // 先頭読みの約束: 少なくとも min(要求, 全体) バイトで、全体の先頭と一致する(ZIPFoundation 版はチャンク単位で多めに返す)。
                for count in [1, 4096, 128 * 1024] {
                    let prefix = try actual.dataPrefix(at: path, maxByteCount: count)
                    #expect(prefix.count >= min(count, full.count) && full.prefix(prefix.count) == prefix,
                            "dataPrefix(\(count)) \(path)", sourceLocation: sourceLocation)
                }
            }
        }
    }

    // MARK: - 読み込み層

    @Test("読み込み層: どんな位置・大きさの読みもファイルと同じバイト列(前景と裏の取り寄せが混ざっても)")
    func stagedSourceReturnsTheFileBytes() throws {
        let folder = try TemporaryDirectory("staged-bytes")
        let url = folder.file("book.bin")
        let bytes = Data((0..<(3 * 1024 * 1024 + 777)).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ ($0 >> 9)) })
        try bytes.write(to: url)

        // ブロックを小さくして、ブロックの境界をまたぐ読みを多く通す。
        let source = try StagedFileSource(url: url, blockSize: 4096, readAhead: 64 * 1024, backgroundChunk: 32 * 1024)
        source.startBackgroundFill()
        var generator = SplitMix64(seed: 42)
        for _ in 0..<400 {
            let offset = UInt64(generator.next() % UInt64(bytes.count + 100))
            let count = Int(generator.next() % 200_000)
            let got = try source.read(at: offset, count: count)
            let start = Int(min(offset, UInt64(bytes.count)))
            let end = min(bytes.count, start + count)
            #expect(got == bytes.subdata(in: start..<end))
        }
        // 順読み(伸長器の読み方)。
        var position: UInt64 = 0
        var joined = Data()
        while position < UInt64(bytes.count) {
            let chunk = try source.read(at: position, count: 16 * 1024 + 3)
            joined.append(chunk)
            position += UInt64(chunk.count)
        }
        #expect(joined == bytes)
    }

    @Test("読み込み層: 複数のスレッドから同時に読んでも同じバイト列")
    func stagedSourceIsSafeAcrossThreads() async throws {
        let folder = try TemporaryDirectory("staged-threads")
        let url = folder.file("book.bin")
        let bytes = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 11)) })
        try bytes.write(to: url)
        let source = try StagedFileSource(url: url, blockSize: 8192, readAhead: 128 * 1024, backgroundChunk: 64 * 1024)
        source.startBackgroundFill()
        let box = UncheckedSendableBox(source)
        let mismatches = await withTaskGroup(of: Int.self) { group in
            for seed in 0..<8 {
                group.addTask {
                    var generator = SplitMix64(seed: UInt64(seed))
                    var bad = 0
                    for _ in 0..<150 {
                        let offset = Int(generator.next() % UInt64(bytes.count))
                        let count = Int(generator.next() % 100_000)
                        let end = min(bytes.count, offset + count)
                        if (try? box.value.read(at: UInt64(offset), count: count)) != bytes.subdata(in: offset..<end) { bad += 1 }
                    }
                    return bad
                }
            }
            return await group.reduce(0, +)
        }
        #expect(mismatches == 0)
    }

    @Test("読み込み層: 裏の取り寄せで全部揃い、揃った後は元のファイルが消えても読める。解放で一時ファイルが消える")
    func stagedSourceCompletesAndCleansUp() async throws {
        let folder = try TemporaryDirectory("staged-complete")
        let url = folder.file("book.bin")
        let bytes = Data((0..<(1024 * 1024 + 5)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try bytes.write(to: url)
        var source: StagedFileSource? = try StagedFileSource(url: url, blockSize: 4096, backgroundChunk: 16 * 1024)
        source?.startBackgroundFill()
        // 裏の取り寄せは最初の前景の読みの後に始まる。
        _ = try source?.read(at: 0, count: 10)
        let deadline = Date().addingTimeInterval(20)
        while source?.isComplete == false, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(source?.isComplete == true)
        #expect((source?.backgroundFetchCount ?? 0) > 0)

        // 揃ったら元のファイルには触らない(ネットワーク上のファイルの記述子も閉じている)。
        try FileManager.default.removeItem(at: url)
        #expect(try source?.read(at: 0, count: bytes.count) == bytes)

        let cacheURL = try #require(source?.cacheURL)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        source = nil
        // 裏のスレッドは 1 回の取り寄せの間しか強参照しないので、手放せばすぐ解放される。
        let gone = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: cacheURL.path), Date() < gone {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path), "一時ファイルが残った")
    }

    @Test("読み込み層: 裏の取り寄せの頼み(StagedFillLease)を手放すと、裏は取り寄せない")
    func releasedFillLeaseStopsTheBackgroundFill() async throws {
        // 2026-09-27 の監査: 以前は一度始めた裏の取り寄せを止める人がおらず、表紙を 1 枚作るために開いた本も丸ごと取り寄せた。
        let folder = try TemporaryDirectory("staged-lease")
        let url = folder.file("book.bin")
        try Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 3) }).write(to: url)
        let source = try StagedFileSource(url: url, blockSize: 4096, backgroundChunk: 16 * 1024)
        // 裏は最初の前景の読みを待っている。その間に頼みを取り下げる。
        var lease: StagedFillLease? = StagedFillLease(source)
        _ = lease
        lease = nil
        _ = try source.read(at: 0, count: 100)
        try await Task.sleep(for: .milliseconds(300))
        #expect(source.backgroundFetchCount == 0)
        #expect(!source.isComplete)

        // 頼み直せば、また取り寄せる(スレッドを作り直す)。
        let again = StagedFillLease(source)
        for _ in 0..<300 where !source.isComplete { try await Task.sleep(for: .milliseconds(10)) }
        #expect(source.isComplete)
        _ = again
    }

    @Test("読み込み層: 0 バイトのファイルで裏の取り寄せを頼んでも、読み込み層は残らない")
    func emptyFileDoesNotPinTheSource() async throws {
        // 2026-09-27 の監査: 以前は裏のスレッドが「最初の前景の読み」を永久に待ち、読み込み層(記述子)を握り続けた。
        let folder = try TemporaryDirectory("staged-empty")
        let url = folder.file("empty.cbz")
        try Data().write(to: url)
        weak var weakSource: StagedFileSource?
        do {
            let source = try StagedFileSource(url: url)
            weakSource = source
            let lease = StagedFillLease(source)
            #expect(try lease.read(at: 0, count: 10).isEmpty)
        }
        for _ in 0..<100 where weakSource != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(weakSource == nil)
    }

    @Test("読み込み層: 手元へ書けない(空きが無いなど)ときも、ネットワークから読んだバイト列を返す")
    func cacheWriteFailureFallsBackToTheRemoteFile() throws {
        let folder = try TemporaryDirectory("staged-nowrite")
        let url = folder.file("book.bin")
        let bytes = Data((0..<(300 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        try bytes.write(to: url)
        // 書き込めない置き場所(一時ファイルを作れない)。
        let readOnly = folder.url.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        let source = try StagedFileSource(url: url, blockSize: 4096, cacheDirectory: readOnly)
        #expect(try source.read(at: 1000, count: 50_000) == bytes.subdata(in: 1000..<51_000))
        #expect(try source.read(at: 0, count: bytes.count) == bytes)
    }

    @Test("読み込み層: 止めた後は、手元に無い部分の読みが失敗する(手元にある部分は読める)")
    func stoppedSourceFailsOnlyForMissingBlocks() throws {
        let folder = try TemporaryDirectory("staged-stop")
        let url = folder.file("book.bin")
        try Data(repeating: 5, count: 200_000).write(to: url)
        let source = try StagedFileSource(url: url, blockSize: 4096)
        #expect(try source.read(at: 0, count: 100) == Data(repeating: 5, count: 100))
        source.stop()
        #expect(try source.read(at: 0, count: 100) == Data(repeating: 5, count: 100))
        #expect(throws: RandomAccessSourceError.self) { try source.read(at: 150_000, count: 100) }
    }

    @Test("登録簿: 同じファイルは同じ読み込み層を共有し、中身が変わったファイルは別になる")
    func registrySharesPerFileIdentity() throws {
        let folder = try TemporaryDirectory("staged-registry")
        let url = folder.file("book.bin")
        try Data(repeating: 1, count: 10_000).write(to: url)
        let registry = StagedFileRegistry(gracePeriod: 60)
        let first = try registry.source(for: url)
        let second = try registry.source(for: url)
        #expect(first === second)
        // 大きさが変われば別の鍵(古い写しは使わない)。
        try Data(repeating: 2, count: 20_000).write(to: url)
        let third = try registry.source(for: url)
        #expect(third !== first)
        #expect(try third.read(at: 0, count: 3) == Data([2, 2, 2]))
    }

    @Test("登録簿: 猶予で残すのは直近の数本だけ(記述子を溜めない)。使われているものは上限に関わらず残る")
    func registryCapsHeldSources() throws {
        let folder = try TemporaryDirectory("staged-cap")
        let registry = StagedFileRegistry(gracePeriod: 60, maxHeld: 2)
        var urls: [URL] = []
        for i in 0..<5 {
            let url = folder.file("book\(i).bin")
            try Data(repeating: UInt8(i), count: 1000).write(to: url)
            urls.append(url)
        }
        let inUse = try registry.source(for: urls[0])
        for url in urls.dropFirst() { _ = try registry.source(for: url) }
        // 使っている 1 本 + 猶予の 2 本だけが生きている(ほかは手放された)。
        #expect(registry.liveCount == 3)
        #expect(try inUse.read(at: 0, count: 1) == Data([0]))
    }

    // MARK: - ネットワーク上とみなした本

    /// 書庫のフィクスチャ全部(zip・rar・7z・epub)。
    nonisolated static let archiveFixturePaths: [String] = Fixtures.manifest.fixtures.keys
        .filter { archiveKind(forFileName: $0) != nil }
        .sorted()

    @Test("ネットワーク上の書庫の本(zip・rar・7z)は、ローカルと同じページ一覧・同じページのバイト列で開ける",
          arguments: archiveFixturePaths)
    func remoteBookMatchesLocal(path: String) async throws {
        let folder = try TemporaryDirectory("remote-book")
        let url = folder.file((path as NSString).lastPathComponent)
        try FileManager.default.copyItem(at: Fixtures.url(path), to: url)

        let local = try? await FixtureBook.load(url)
        let isZip = archiveKind(forFileName: url.lastPathComponent) == .zip
        let opens = (try? makeArchiveReader(for: url)) != nil
        if opens, isZip { #expect(!((try? makeArchiveReader(for: url)) is CentralDirectoryZipReader)) }

        NetworkVolumeReading.treatAsRemoteForTesting(folder.url)
        defer { NetworkVolumeReading.endTreatingAsRemoteForTesting(folder.url) }
        if opens, isZip { #expect((try? makeArchiveReader(for: url)) is CentralDirectoryZipReader) }
        let remote = try? await FixtureBook.load(url)

        // 同じ sortKey のページが 2 つある本(nested-same-name-file-and-folder: 入れ子の a.zip の中と、a.zip という名前の
        // フォルダの中)では、その 2 つの並びが書庫の一覧の順(辞書の順。プロセスごとに変わる)で決まり、ローカル同士でも
        // 入れ替わる。並びは sortKey の列で、中身はページの id ごとに比べる。
        #expect(remote?.pages.map(\.sortKey) == local?.pages.map(\.sortKey))
        #expect(remote.map { Set($0.pages.map(\.id)) } == local.map { Set($0.pages.map(\.id)) })
        guard let local, let remote else { return }

        // ページのバイト列(PageLoader は本を開いたら残りを裏で取り寄せる経路)。
        NetworkVolumeReading.endTreatingAsRemoteForTesting(folder.url)
        let localLoader = PageLoader(book: local, usesThumbnailDiskCache: false)
        var expected: [String: Data?] = [:]
        for (index, page) in local.pages.enumerated() { expected[page.id] = await localLoader.rawImageData(at: index) }
        await localLoader.releaseAllResources()

        NetworkVolumeReading.treatAsRemoteForTesting(folder.url)
        let remoteLoader = PageLoader(book: remote, usesThumbnailDiskCache: false)
        for (index, page) in remote.pages.enumerated() {
            let got = await remoteLoader.rawImageData(at: index)
            #expect(got == expected[page.id] ?? nil, "\(page.id)")
        }
        await remoteLoader.releaseAllResources()
    }

    nonisolated static let pdfFixturePaths: [String] = Fixtures.manifest.fixtures.keys.filter { $0.hasSuffix(".pdf") }.sorted()

    @Test("ネットワーク上の PDF の本は、読み込み層を通してローカルと同じページ数・読み方向・描画結果で開ける",
          arguments: pdfFixturePaths)
    func remotePDFMatchesLocal(path: String) async throws {
        let folder = try TemporaryDirectory("remote-pdf")
        let url = folder.file((path as NSString).lastPathComponent)
        try FileManager.default.copyItem(at: Fixtures.url(path), to: url)

        let local = try await FixtureBook.load(url)
        let localLoader = PageLoader(book: local, usesThumbnailDiskCache: false)
        var expected: [Data?] = []
        for index in local.pages.indices { expected.append(await localLoader.pageImage(at: index)?.dataProvider?.data as Data?) }
        await localLoader.releaseAllResources()

        NetworkVolumeReading.treatAsRemoteForTesting(folder.url)
        defer { NetworkVolumeReading.endTreatingAsRemoteForTesting(folder.url) }
        let remote = try await FixtureBook.load(url)
        #expect(remote.pages.map(\.sortKey) == local.pages.map(\.sortKey))
        #expect(remote.sourceLayoutHint == local.sourceLayoutHint)
        let remoteLoader = PageLoader(book: remote, usesThumbnailDiskCache: false)
        for index in remote.pages.indices {
            let got = await remoteLoader.pageImage(at: index)?.dataProvider?.data as Data?
            #expect(got != nil && got == expected[index], "\(index + 1) ページ目")
        }
        await remoteLoader.releaseAllResources()
    }

    @Test("隠し設定の既定は「使う」(値が無い・true)。判定はローカルのフィクスチャでは使わない")
    func localFixturesAreNotStaged() {
        #expect(!NetworkVolumeReading.usesStagedReading(for: Fixtures.url("zip/zip-zipcli.cbz")))
    }
}

// MARK: - テスト用の道具

/// 決まった列を返す乱数(再現できるように)。
private nonisolated struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 頼まれた読みの量を数える出所(zip ではないファイルで、末尾の窓より多く読まないことを確かめる)。
private nonisolated final class CountingSource: RandomAccessSource {
    private let base: RandomAccessSource
    private(set) var bytesRequested = 0
    var size: UInt64 { base.size }
    init(_ base: RandomAccessSource) { self.base = base }
    func read(at offset: UInt64, count: Int) throws -> Data {
        bytesRequested += count
        return try base.read(at: offset, count: count)
    }
}

/// `failsFrom` 以降を含む読みが失敗する出所(ネットワークの瞬断の見立て)。
private nonisolated final class FailingSource: RandomAccessSource {
    private let base: RandomAccessSource
    var failsFrom: UInt64
    var size: UInt64 { base.size }
    init(_ base: RandomAccessSource, failsFrom: UInt64) {
        self.base = base
        self.failsFrom = failsFrom
    }
    func read(at offset: UInt64, count: Int) throws -> Data {
        if count > 0, offset &+ UInt64(count) > failsFrom { throw RandomAccessSourceError.readFailed(EIO) }
        return try base.read(at: offset, count: count)
    }
}

/// スレッド安全なもの(読み込み層)を並行テストへ渡す箱。
private nonisolated struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// zip を 1 バイトずつ組み立てる(ZIPFoundation では書けない形 ―― 小さな ZIP64・暗号化フラグ・同名 ―― のため)。
/// エントリはすべて格納(無圧縮)、作成 OS は unix(通常のファイル)。
private nonisolated struct RawZipWriter {
    private struct Entry {
        let name: Data
        let data: Data
        let zip64: Bool
        let encrypted: Bool
        /// 中央ディレクトリの ZIP64 拡張欄に書く値(細工した書庫のため。nil の欄は実際の値)。
        let centralZIP64: (uncompressed: UInt64?, compressed: UInt64?, offset: UInt64?)?
        /// ローカルヘッダーの圧縮方式(中身は常に格納のまま)。
        let localMethod: UInt16
    }
    private var entries: [Entry] = []

    mutating func add(
        _ name: String, _ data: Data, zip64: Bool = false, encrypted: Bool = false,
        centralZIP64: (uncompressed: UInt64?, compressed: UInt64?, offset: UInt64?)? = nil, localMethod: UInt16 = 0
    ) {
        entries.append(Entry(name: Data(name.utf8), data: data, zip64: zip64, encrypted: encrypted,
                             centralZIP64: centralZIP64, localMethod: localMethod))
    }

    /// - Parameter zip64CentralOffset: ZIP64 の終わりのレコードに書く中央ディレクトリの位置(細工した書庫のため)。
    func write(to url: URL, comment: Data = Data(), zip64EndRecord: Bool = false, zip64CentralOffset: UInt64? = nil) throws {
        var out = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt64(out.count)
            let crc = entry.data.crc32(checksum: 0)
            let flags: UInt16 = (1 << 11) | (entry.encrypted ? 1 : 0)
            let version: UInt16 = entry.zip64 ? 45 : 20
            let size32: UInt32 = entry.zip64 ? 0xFFFF_FFFF : UInt32(entry.data.count)
            var localExtra = Data()
            if entry.zip64 {
                localExtra.le(UInt16(1)); localExtra.le(UInt16(16))
                localExtra.le(UInt64(entry.data.count)); localExtra.le(UInt64(entry.data.count))
            }
            out.le(UInt32(0x0403_4b50)); out.le(version); out.le(flags); out.le(entry.localMethod)
            out.le(UInt16(0x6000)); out.le(UInt16(0x5A21)); out.le(crc); out.le(size32); out.le(size32)
            out.le(UInt16(entry.name.count)); out.le(UInt16(localExtra.count))
            out.append(entry.name); out.append(localExtra); out.append(entry.data)

            var centralExtra = Data()
            if entry.zip64 {
                centralExtra.le(UInt16(1)); centralExtra.le(UInt16(24))
                let crafted = entry.centralZIP64
                centralExtra.le(crafted?.uncompressed ?? UInt64(entry.data.count))
                centralExtra.le(crafted?.compressed ?? UInt64(entry.data.count))
                centralExtra.le(crafted?.offset ?? offset)
            }
            central.le(UInt32(0x0201_4b50)); central.le(UInt16(3 << 8 | 45)); central.le(version); central.le(flags)
            central.le(UInt16(0)); central.le(UInt16(0x6000)); central.le(UInt16(0x5A21)); central.le(crc)
            central.le(size32); central.le(size32)
            central.le(UInt16(entry.name.count)); central.le(UInt16(centralExtra.count)); central.le(UInt16(0))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt32(0o100644) << 16)
            central.le(entry.zip64 ? 0xFFFF_FFFF : UInt32(offset))
            central.append(entry.name); central.append(centralExtra)
        }
        let centralOffset = UInt64(out.count)
        out.append(central)
        if zip64EndRecord {
            let recordOffset = UInt64(out.count)
            out.le(UInt32(0x0606_4b50)); out.le(UInt64(44)); out.le(UInt16(45)); out.le(UInt16(45))
            out.le(UInt32(0)); out.le(UInt32(0)); out.le(UInt64(entries.count)); out.le(UInt64(entries.count))
            out.le(UInt64(central.count)); out.le(zip64CentralOffset ?? centralOffset)
            out.le(UInt32(0x0706_4b50)); out.le(UInt32(0)); out.le(recordOffset); out.le(UInt32(1))
        }
        out.le(UInt32(0x0605_4b50)); out.le(UInt16(0)); out.le(UInt16(0))
        out.le(zip64EndRecord ? UInt16(0xFFFF) : UInt16(entries.count)); out.le(zip64EndRecord ? UInt16(0xFFFF) : UInt16(entries.count))
        out.le(zip64EndRecord ? UInt32(0xFFFF_FFFF) : UInt32(central.count))
        out.le(zip64EndRecord ? UInt32(0xFFFF_FFFF) : UInt32(centralOffset))
        out.le(UInt16(comment.count)); out.append(comment)
        try out.write(to: url)
    }
}

private extension Data {
    nonisolated mutating func le<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
