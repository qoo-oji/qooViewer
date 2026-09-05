import Foundation
import Testing

@testable import qooViewer

/// ディスク側のキャッシュ・一時ファイルの「純粋な計算」の部分。
///
/// 実体(`BookPageListCache.shared` / `ThumbnailDiskCache.shared` / 自分のセッションの `tmp/`)は
/// **共有の保存先**なのでテストからは触らない。ここで見るのは、保存する JSON の形、刈り込みの
/// 境目の式、残骸の判定 ―― どれも入力から結果が決まるものだけ。
struct BookPageListCacheEntryTests {
    private func decode(_ json: String) throws -> BookPageListCache.Entry {
        try JSONDecoder().decode(BookPageListCache.Entry.self, from: Data(json.utf8))
    }

    @Test("構造キャッシュの版は 3(版 2 以前は捨てて読み直す)")
    func theCurrentSchemaVersionIsThree() {
        // 2: 並びを正準順にした(版 1 の `.numeric` 順をそのまま使うと並びが狂う)。
        // 3: 書庫の中の `__MACOSX/._*.jpg` をページとして数えるのをやめた。
        //    版 2 の JSON にはそのページが残っているため、組み立て直すと復活する。
        #expect(BookPageListCache.Entry.currentSchemaVersion == 3)
    }

    @Test("版 2 の JSON も復号できる(欠けている項目は nil になるだけ)")
    func aVersionTwoDocumentStillDecodes() throws {
        // 構造キャッシュを入れる前・`folderPath` を入れる前に保存された形。移行処理は持たない。
        let entry = try decode("""
        {"pages":[{"sortKey":"001.jpg","displayName":"001.jpg"},
                  {"sortKey":"002.jpg","displayName":"002.jpg"}],
         "schemaVersion":2,
         "rootPath":"/books/a.cbz",
         "fingerprint":{"fileSize":1234}}
        """)
        #expect(entry.pages.map(\.sortKey) == ["001.jpg", "002.jpg"])
        #expect(entry.schemaVersion == 2)
        #expect(entry.schemaVersion != BookPageListCache.Entry.currentSchemaVersion)
        #expect(entry.pages.allSatisfy { $0.folderPath == nil && $0.idSuffix == nil })
        #expect(entry.hasNestedArchives == nil)
        #expect(entry.pageSizes == nil)
        #expect(entry.fingerprint == BookPageListCache.Entry.Fingerprint(modificationDate: nil, fileSize: 1234))
    }

    @Test("この仕組みより前の JSON(ページ一覧だけ)も復号できる")
    func theOldestDocumentStillDecodes() throws {
        let entry = try decode(#"{"pages":[{"sortKey":"001.jpg","displayName":"001.jpg"}]}"#)
        #expect(entry.pages.count == 1)
        #expect(entry.schemaVersion == nil)
        #expect(entry.rootPath == nil)
        #expect(entry.fingerprint == nil)
    }

    @Test("いま書く形は、そのまま往復する")
    func theCurrentShapeRoundTrips() throws {
        var entry = BookPageListCache.Entry(pages: [
            BookPageListCache.Entry.Page(
                sortKey: "vol1.cbz/ch03/001.jpg", displayName: "001.jpg", folderPath: "vol1.cbz/ch03",
                idSuffix: "#vol1.cbz/ch03/001.jpg", nestedPath: ["vol1.cbz"], entryPath: "ch03/001.jpg",
                spreadPosition: nil
            ),
        ])
        entry.schemaVersion = BookPageListCache.Entry.currentSchemaVersion
        entry.rootPath = "/books/a.cbz"
        entry.fingerprint = BookPageListCache.Entry.Fingerprint(modificationDate: Date(timeIntervalSince1970: 1), fileSize: 42)
        entry.hasNestedArchives = true
        entry.pageSizes = ["vol1.cbz/ch03/001.jpg": [800, 1200]]

        let decoded = try JSONDecoder().decode(
            BookPageListCache.Entry.self, from: try JSONEncoder().encode(entry)
        )
        #expect(decoded.pages == entry.pages)
        #expect(decoded.schemaVersion == entry.schemaVersion)
        #expect(decoded.rootPath == entry.rootPath)
        #expect(decoded.fingerprint == entry.fingerprint)
        #expect(decoded.hasNestedArchives == true)
        #expect(decoded.pageSizes == entry.pageSizes)
    }

    @Test("指紋は実ファイルから読める(属性が1つも無ければ nil)")
    func theFingerprintComesFromTheFile() throws {
        let workspace = try TemporaryDirectory("fingerprint")
        let url = workspace.file("a.cbz")
        try Data("abc".utf8).write(to: url)

        let fingerprint = try #require(BookPageListCache.Entry.Fingerprint.current(for: url))
        #expect(fingerprint.fileSize == 3)
        #expect(fingerprint.modificationDate != nil)
        // 中身が変われば指紋も変わる。
        try Data("abcd".utf8).write(to: url)
        #expect(BookPageListCache.Entry.Fingerprint.current(for: url) != fingerprint)
        #expect(BookPageListCache.Entry.Fingerprint.current(for: workspace.file("ghost.cbz")) == nil)
    }
}

/// サムネイルのディスクキャッシュのうち、刈り込みの境目を決める式だけ。
struct ThumbnailDiskCacheTrimThresholdTests {
    @Test("上限の 5% を目安に、1MB〜16MB で頭打ちにする")
    func theThresholdIsFivePercentClamped() {
        let mb = 1024 * 1024
        // 上限が小さいときに全走査が頻発しないよう、下は 1MB。
        #expect(ThumbnailDiskCache.trimThreshold(for: 0) == 1 * mb)
        #expect(ThumbnailDiskCache.trimThreshold(for: 10 * mb) == 1 * mb)
        #expect(ThumbnailDiskCache.trimThreshold(for: 20 * mb) == 1 * mb)
        // 5% が 1MB を超えたら、そちらを使う。
        #expect(ThumbnailDiskCache.trimThreshold(for: 200 * mb) == 10 * mb)
        // 上限が大きいときに超過が広がりすぎないよう、上は 16MB。
        #expect(ThumbnailDiskCache.trimThreshold(for: 320 * mb) == 16 * mb)
        #expect(ThumbnailDiskCache.trimThreshold(for: 4096 * mb) == 16 * mb)
    }

    @Test("実際の使用量が収まる範囲(上限の8割〜上限+threshold)は、上限に対して単調")
    func theThresholdNeverShrinksAsTheLimitGrows() {
        // リソースモニタの異常判定(ResourceAnomalyDetector)もこの式で境目を引く。
        let limits = [0, 1, 8, 20, 50, 200, 320, 1024].map { $0 * 1024 * 1024 }
        let thresholds = limits.map(ThumbnailDiskCache.trimThreshold(for:))
        #expect(thresholds == thresholds.sorted())
    }
}

/// 一時ファイルの残骸の判定(Services/TemporaryFileStore.swift)。
struct TemporaryFileStoreStaleEntryTests {
    private func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    @Test("自分のセッションのディレクトリは残骸ではない")
    func theOwnSessionDirectoryIsNeverStale() {
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(!TemporaryFileStore.isStaleEntry(url("qooViewer-\(pid)"), isDirectory: true))
    }

    @Test("生きていない pid のセッションディレクトリは残骸")
    func aDeadSessionDirectoryIsStale() {
        // pid 0 / 負数は `kill(pid, 0)` に渡してはいけない値なので、生きていない扱いにしている。
        #expect(TemporaryFileStore.isStaleEntry(url("qooViewer-0"), isDirectory: true))
        // 使われていないであろう大きな pid。取り違えても安全側(消さない)に倒れるだけ。
        let unlikely = 99_999_999
        if kill(pid_t(unlikely), 0) != 0, errno != EPERM {
            #expect(TemporaryFileStore.isStaleEntry(url("qooViewer-\(unlikely)"), isDirectory: true))
        }
    }

    @Test("pid として読めない名前は触らない")
    func aNonNumericSuffixIsLeftAlone() {
        #expect(!TemporaryFileStore.isStaleEntry(url("qooViewer-abc"), isDirectory: true))
        #expect(!TemporaryFileStore.isStaleEntry(url("qooViewer-"), isDirectory: true))
    }

    @Test("旧形式の <UUID>.<書庫拡張子> は残骸")
    func aLegacyTemporaryArchiveIsStale() {
        let uuid = UUID().uuidString
        #expect(TemporaryFileStore.isStaleEntry(url("\(uuid).cbz"), isDirectory: false))
        #expect(TemporaryFileStore.isStaleEntry(url("\(uuid).rar"), isDirectory: false))
        #expect(TemporaryFileStore.isStaleEntry(url("\(uuid).7z"), isDirectory: false))
    }

    @Test("tmp/ にある他のもの(OS・状態復元・診断ログ)は巻き込まない")
    func unrelatedEntriesAreNeverStale() {
        let uuid = UUID().uuidString
        #expect(!TemporaryFileStore.isStaleEntry(url("TemporaryItems"), isDirectory: true))
        #expect(!TemporaryFileStore.isStaleEntry(url("com.apple.savedState"), isDirectory: true))
        // UUID の形をしていないファイル、書庫でない拡張子はどちらも対象外。
        #expect(!TemporaryFileStore.isStaleEntry(url("scratch.cbz"), isDirectory: false))
        #expect(!TemporaryFileStore.isStaleEntry(url("\(uuid).log"), isDirectory: false))
        #expect(!TemporaryFileStore.isStaleEntry(url("\(uuid).cbz"), isDirectory: true))
    }
}
