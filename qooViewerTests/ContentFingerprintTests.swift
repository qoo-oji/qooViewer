import Foundation
import Testing

@testable import qooViewer

/// 「同じパスのまま中身が別物に差し替わった」の検知(Services/ContentFingerprint.swift)。
///
/// `BookReadingState`(読書位置)と `BookLayoutSettings`(ページレイアウト)の両方が、これを見て
/// 保存済みのデータを捨てるかどうかを決める。**捨てる側**の判定なので、誤検知は
/// 「ユーザーが手で並べ替えたレイアウトが消える」に直結する ―― 特に「記録が無い/古い」ときに
/// 差し替え扱いしないことを固定しておく。
@MainActor
struct ContentFingerprintTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func recorded(pageCount: Int? = 10, date: Date? = nil, size: Int64? = 1234)
        -> ContentFingerprint.Recorded
    {
        ContentFingerprint.Recorded(pageCount: pageCount, modificationDate: date ?? now, fileSize: size)
    }

    private func current(pageCount: Int = 10, date: Date? = nil, size: Int64? = 1234)
        -> ContentFingerprint.Snapshot
    {
        ContentFingerprint.Snapshot(pageCount: pageCount, modificationDate: date ?? now, fileSize: size)
    }

    // MARK: - 比較の規則

    @Test("3 点すべて一致していれば差し替えなし")
    func anIdenticalFingerprintIsNotAReplacement() {
        #expect(!ContentFingerprint.looksReplaced(recorded: recorded(), current: current()))
    }

    @Test("ページ数・更新日時・ファイルサイズは、どれか 1 つでも違えば差し替え")
    func anyOfTheThreePointsDetectsAReplacement() {
        #expect(ContentFingerprint.looksReplaced(recorded: recorded(), current: current(pageCount: 11)))
        #expect(ContentFingerprint.looksReplaced(
            recorded: recorded(), current: current(date: now.addingTimeInterval(1))))
        #expect(ContentFingerprint.looksReplaced(recorded: recorded(), current: current(size: 1235)))
    }

    @Test("記録が無ければ差し替えなし(指紋の仕組みを入れる前に保存されたデータを捨てない)")
    func aMissingRecordIsNotAReplacement() {
        #expect(!ContentFingerprint.looksReplaced(recorded: nil, current: current()))
        // 3 属性のうちページ数だけは必須の目印。これが無い行は「比較のしようがない」として素通し。
        #expect(!ContentFingerprint.looksReplaced(
            recorded: recorded(pageCount: nil, date: now.addingTimeInterval(999), size: 99),
            current: current()))
    }

    @Test("ページ数さえ記録されていれば、更新日時とサイズは nil でも比較する")
    func theOtherTwoPointsAreComparedEvenWhenNil() {
        // 記録が nil で現在が値を持つ(= 記録時は測れなかった)場合も食い違いとして扱う。
        let unmeasured = ContentFingerprint.Recorded(pageCount: 10, modificationDate: nil, fileSize: nil)
        #expect(ContentFingerprint.looksReplaced(recorded: unmeasured, current: current()))
        // 両方 nil なら一致。フォルダの本(サイズが取れない)がここに当たる。
        #expect(!ContentFingerprint.looksReplaced(
            recorded: unmeasured,
            current: ContentFingerprint.Snapshot(pageCount: 10, modificationDate: nil, fileSize: nil)))
    }

    // MARK: - 実際の本から測る

    @Test("フォルダの本: ページ数と更新日時は取れ、ファイルサイズは取れない")
    func aFolderBookHasNoFileSize() async throws {
        let temporary = try TemporaryDirectory("fingerprint-folder")
        let directory = temporary.file("book")
        try FixtureFolder.make(at: directory, pages: [
            .init("p1.png", number: 1), .init("p2.png", number: 2), .init("p3.png", number: 3),
        ])
        let book = try await FixtureBook.load(directory)

        let snapshot = ContentFingerprint.current(for: book)
        #expect(snapshot.pageCount == 3)
        #expect(snapshot.modificationDate != nil)
        // `.fileSizeKey` は通常ファイルにしか付かない。フォルダの本はページ数と更新日時の
        // 2 点だけで見ることになる。
        #expect(snapshot.fileSize == nil)
    }

    @Test("フォルダの本: ページを増やすと差し替えとして検知される")
    func addingAPageToAFolderIsDetected() async throws {
        let temporary = try TemporaryDirectory("fingerprint-grow")
        let directory = temporary.file("book")
        try FixtureFolder.make(at: directory, pages: [.init("p1.png", number: 1), .init("p2.png", number: 2)])
        let before = ContentFingerprint.current(for: try await FixtureBook.load(directory))

        try FixtureFolder.make(at: directory, pages: [.init("p3.png", number: 3)])
        let after = ContentFingerprint.current(for: try await FixtureBook.load(directory))

        #expect(before.pageCount == 2 && after.pageCount == 3)
        let recorded = ContentFingerprint.Recorded(
            pageCount: before.pageCount, modificationDate: before.modificationDate, fileSize: before.fileSize
        )
        #expect(ContentFingerprint.looksReplaced(recorded: recorded, current: after))
    }

    @Test("書庫の本: ファイルサイズは実ファイルのバイト数")
    func anArchiveBookRecordsTheFileSize() async throws {
        let url = Fixtures.url("zip/zip-zipcli.cbz")
        let book = try await FixtureBook.load(url)

        let snapshot = ContentFingerprint.current(for: book)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(snapshot.fileSize == (attributes[.size] as? NSNumber)?.int64Value)
        #expect(snapshot.pageCount == book.pages.count)
        #expect(snapshot.modificationDate != nil)
    }

    @Test("同じ本を 2 回測れば同じ指紋になる(開き直しただけで捨てない)")
    func measuringTheSameBookTwiceIsStable() async throws {
        let temporary = try TemporaryDirectory("fingerprint-stable")
        let directory = temporary.file("book")
        try FixtureFolder.make(at: directory, pages: [.init("p1.png", number: 1), .init("p2.png", number: 2)])

        let first = ContentFingerprint.current(for: try await FixtureBook.load(directory))
        let second = ContentFingerprint.current(for: try await FixtureBook.load(directory))
        #expect(first == second)
        let recorded = ContentFingerprint.Recorded(
            pageCount: first.pageCount, modificationDate: first.modificationDate, fileSize: first.fileSize
        )
        #expect(!ContentFingerprint.looksReplaced(recorded: recorded, current: second))
    }
}
