import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// レイアウト設定の 3 つの経路(ViewModels/LayoutStore.swift)。
///
/// - `setPageOrderOverride`: ユーザーが決めたページの並びを鍵の配列として焼き付ける。
/// - `checkContentReplacement`: 同じパスのまま中身が差し替わっていないかを見る(指紋の比較)。
/// - `discardLayoutData`: 1 冊ぶんのレイアウトを消す。
///
/// どれも「利用者が手で作ったものを、いつ捨てるか」に関わる。特に `discardLayoutData` の
/// 早期リターン(消すものが無ければ通知も出さない)は、一括削除の重さに直結する。
@MainActor
struct LayoutStoreTests {
    private struct Source {
        let temporary: TemporaryDirectory
        let book: MangaBook

        var keys: [String] { book.pages.map(\.sortKey) }
    }

    private func makeSource(_ label: String, pageCount: Int = 4) async throws -> Source {
        let temporary = try TemporaryDirectory(label)
        let directory = temporary.file("book")
        try FixtureFolder.make(at: directory, pages: (1...pageCount).map {
            FixtureFolder.Page(String(format: "%03d.jpg", $0), number: UInt8($0))
        })
        return Source(temporary: temporary, book: try await FixtureBook.load(directory))
    }

    private func settings(_ library: InMemoryLibrary, _ book: MangaBook) -> BookLayoutSettings? {
        library.layouts.bookLayoutSettings(forBookID: book.id)
    }

    // MARK: - ページ順の固定

    @Test("並びを焼き付けると、その本のレイアウト設定に鍵の配列として残る")
    func thePinnedOrderIsStoredAsKeys() async throws {
        let library = try InMemoryLibrary(label: "layout-order")
        defer { library.close() }
        let source = try await makeSource("layout-order")

        let reversed = Array(source.keys.reversed())
        library.layouts.setPageOrderOverride(for: source.book, reversed)
        #expect(settings(library, source.book)?.pageOrderOverride == reversed)
        #expect(library.layouts.layoutBookIDs.contains(source.book.id))
    }

    @Test("nil を渡すと「ページ順を初期化する」と同じで、行は残ったまま並びだけ消える")
    func passingNilClearsTheOrderButKeepsTheRow() async throws {
        let library = try InMemoryLibrary(label: "layout-order-clear")
        defer { library.close() }
        let source = try await makeSource("layout-order-clear")

        library.layouts.setPageOrderOverride(for: source.book, Array(source.keys.reversed()))
        library.layouts.setPageOrderOverride(for: source.book, nil)
        let row = try #require(settings(library, source.book))
        #expect(row.pageOrderOverride == nil)
    }

    @Test("焼き付けは何度でも上書きできる")
    func thePinnedOrderCanBeReplaced() async throws {
        let library = try InMemoryLibrary(label: "layout-order-replace")
        defer { library.close() }
        let source = try await makeSource("layout-order-replace")

        library.layouts.setPageOrderOverride(for: source.book, source.keys)
        library.layouts.setPageOrderOverride(for: source.book, Array(source.keys.dropLast()))
        #expect(settings(library, source.book)?.pageOrderOverride?.count == source.keys.count - 1)
    }

    // MARK: - 差し替え検知

    @Test("レイアウト設定が無い本は、そもそも守るものが無いので常に unaffected")
    func aBookWithoutLayoutDataIsNeverFlagged() async throws {
        let library = try InMemoryLibrary(label: "layout-replace-none")
        defer { library.close() }
        let source = try await makeSource("layout-replace-none")
        #expect(library.layouts.checkContentReplacement(book: source.book) == .unaffected)
    }

    @Test("開き直しただけなら unaffected(指紋は行を作った時点で記録されている)")
    func reopeningTheSameBookIsUnaffected() async throws {
        let library = try InMemoryLibrary(label: "layout-replace-same")
        defer { library.close() }
        let source = try await makeSource("layout-replace-same")

        library.layouts.setPageLayoutState(for: source.book, pageKey: source.keys[0], state: .single)
        #expect(library.layouts.checkContentReplacement(book: source.book) == .unaffected)
    }

    @Test("ページ数が変わったら差し替えの疑い(pageCountMatches: false)")
    func addingAPageRaisesTheSuspicionWithADifferentPageCount() async throws {
        let library = try InMemoryLibrary(label: "layout-replace-count")
        defer { library.close() }
        let source = try await makeSource("layout-replace-count")
        library.layouts.setPageLayoutState(for: source.book, pageKey: source.keys[0], state: .single)

        try FixtureFolder.make(at: source.temporary.file("book"), pages: [.init("099.jpg", number: 99)])
        let reopened = try await FixtureBook.load(source.temporary.file("book"))
        #expect(reopened.pages.count == source.book.pages.count + 1)
        #expect(library.layouts.checkContentReplacement(book: reopened)
                == .possiblyReplaced(pageCountMatches: false))
    }

    @Test("ページ数は同じでも中身が変わったら疑う(pageCountMatches: true)")
    func replacingTheContentWithTheSamePageCountIsStillFlagged() async throws {
        let library = try InMemoryLibrary(label: "layout-replace-same-count")
        defer { library.close() }
        let source = try await makeSource("layout-replace-same-count")
        library.layouts.setPageLayoutState(for: source.book, pageKey: source.keys[0], state: .single)

        // ページ数は変えずにフォルダの更新日時だけ動かす(1 枚差し替えたのと同じ形)。
        let directory = source.temporary.file("book")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: directory.path)
        let reopened = try await FixtureBook.load(directory)
        #expect(reopened.pages.count == source.book.pages.count)
        #expect(library.layouts.checkContentReplacement(book: reopened)
                == .possiblyReplaced(pageCountMatches: true))
    }

    @Test("「そのまま適用する」を選ぶと基準が今の指紋へ更新され、次からは疑われない")
    func acceptingTheCurrentContentUpdatesTheBaseline() async throws {
        let library = try InMemoryLibrary(label: "layout-replace-accept")
        defer { library.close() }
        let source = try await makeSource("layout-replace-accept")
        library.layouts.setPageLayoutState(for: source.book, pageKey: source.keys[0], state: .single)

        let directory = source.temporary.file("book")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: directory.path)
        let reopened = try await FixtureBook.load(directory)
        #expect(library.layouts.checkContentReplacement(book: reopened) != .unaffected)

        library.layouts.acceptCurrentContent(book: reopened)
        #expect(library.layouts.checkContentReplacement(book: reopened) == .unaffected)
        // レイアウトそのものは残っている(「そのまま適用する」なので)。
        #expect(library.pageStates(forBookID: reopened.id) == [source.keys[0]: .single])
    }

    // MARK: - 1 冊ぶんの削除

    @Test("本全体の設定もページ単位の設定もまとめて消える")
    func discardingRemovesBothKindsOfRows() async throws {
        let library = try InMemoryLibrary(label: "layout-discard")
        defer { library.close() }
        let source = try await makeSource("layout-discard")

        library.layouts.setPageOrderOverride(for: source.book, Array(source.keys.reversed()))
        library.layouts.setPageLayoutState(for: source.book, pageKey: source.keys[0], state: .spreadLeft)
        library.layouts.setPageLayoutState(for: source.book, pageKey: source.keys[1], state: .excluded)
        #expect(library.pageStates(forBookID: source.book.id).count == 2)

        library.layouts.discardLayoutData(forBookID: source.book.id)
        #expect(settings(library, source.book) == nil)
        #expect(library.pageStates(forBookID: source.book.id).isEmpty)
        #expect(!library.layouts.layoutBookIDs.contains(source.book.id))
    }

    @Test("他の本のレイアウトは残る")
    func discardingOneBookLeavesTheOthers() async throws {
        let library = try InMemoryLibrary(label: "layout-discard-other")
        defer { library.close() }
        let first = try await makeSource("layout-discard-a")
        let second = try await makeSource("layout-discard-b")

        library.layouts.setPageLayoutState(for: first.book, pageKey: first.keys[0], state: .single)
        library.layouts.setPageLayoutState(for: second.book, pageKey: second.keys[0], state: .single)

        library.layouts.discardLayoutData(forBookID: first.book.id)
        #expect(library.pageStates(forBookID: first.book.id).isEmpty)
        #expect(library.pageStates(forBookID: second.book.id).count == 1)
    }

    @Test("消すものが無ければ変更通知を出さない(一括削除で本の件数ぶん空振りしないため)")
    func discardingNothingDoesNotNotify() async throws {
        let library = try InMemoryLibrary(label: "layout-discard-empty")
        defer { library.close() }

        // 並行して走る他のテストも同じ通知を投げるので、この本の bookID だけを数える。
        let prefix = "/books/no-layout-\(UUID().uuidString)-"
        let counter = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .layoutDataDidChange, object: nil, queue: nil
        ) { notification in
            guard let bookID = notification.userInfo?["bookID"] as? String,
                  bookID.hasPrefix(prefix) else { return }
            counter.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        for index in 0..<20 {
            library.layouts.discardLayoutData(forBookID: "\(prefix)\(index).cbz")
        }
        #expect(counter.count == 0)

        // 対になる確認: 実際に消すものがあるときは 1 冊につき 1 回だけ出る。
        let source = try await makeSource("layout-discard-notify")
        library.layouts.setPageLayoutState(for: source.book, pageKey: source.keys[0], state: .single)
        let notifiedPrefix = source.book.id
        let secondCounter = NotificationCounter()
        let secondToken = NotificationCenter.default.addObserver(
            forName: .layoutDataDidChange, object: nil, queue: nil
        ) { notification in
            guard notification.userInfo?["bookID"] as? String == notifiedPrefix else { return }
            secondCounter.increment()
        }
        defer { NotificationCenter.default.removeObserver(secondToken) }
        library.layouts.discardLayoutData(forBookID: source.book.id)
        library.layouts.discardLayoutData(forBookID: source.book.id)  // 2 回目は消すものが無い
        #expect(secondCounter.count == 1)
    }

    // MARK: - カバーの指定(本を読み込まずに書く版)

    /// コレクションのメタデータ編集シートと「メタデータの編集」ウインドウは、対象の本を
    /// **開かないまま**カバーを指定する。MangaBook を要る版と同じ行・同じ属性へ書けること
    /// (別々の行が2つできると、書き出しと一覧で違うカバーが出る)。
    @Test("本を読み込まない版のカバー指定は、MangaBook 版と同じ行へ書く")
    func theBookIDVariantWritesTheSameRow() async throws {
        let library = try InMemoryLibrary(label: "layout-cover-bookid")
        defer { library.close() }
        let source = try await makeSource("layout-cover-bookid")

        library.layouts.setCoverPageKey(
            forBookID: source.book.id, sourceURL: source.book.sourceURL,
            pageKey: source.keys[2], displayName: "003.jpg"
        )
        #expect(settings(library, source.book)?.coverPageKey == source.keys[2])
        #expect(settings(library, source.book)?.coverPageDisplayName == "003.jpg")

        // MangaBook 版で上書きしても行は増えない。
        library.layouts.setCoverPageKey(for: source.book, pageKey: source.keys[1], displayName: "002.jpg")
        #expect(settings(library, source.book)?.coverPageKey == source.keys[1])
        #expect(library.layouts.coverOverrideBookIDs() == [source.book.id])
    }

    @Test("専用ファイルの指定は、ページの指定を打ち消す(両方が同時に立たない)")
    func anExternalCoverReplacesThePageCover() async throws {
        let library = try InMemoryLibrary(label: "layout-cover-external")
        defer { library.close() }
        let source = try await makeSource("layout-cover-external")
        let coverFile = source.temporary.file("cover.jpg")
        try Data("not really a jpeg".utf8).write(to: coverFile)

        library.layouts.setCoverPageKey(for: source.book, pageKey: source.keys[0], displayName: "001.jpg")
        try library.layouts.setExternalCover(
            forBookID: source.book.id, sourceURL: source.book.sourceURL, fileURL: coverFile
        )
        #expect(settings(library, source.book)?.coverPageKey == nil)
        #expect(settings(library, source.book)?.externalCoverFileName == "cover.jpg")
    }

    /// 横長カバーの見せ方は「どの画像か」ではなく「その画像のどこを見せるか」なので、
    /// カバーを既定へ戻しても残る(LayoutStore.setCoverCropAnchor のコメント)。
    @Test("「カバーを既定に戻す」は、横長カバーの見せ方の指定まで消さない")
    func resettingTheCoverKeepsTheCropAnchor() async throws {
        let library = try InMemoryLibrary(label: "layout-cover-anchor")
        defer { library.close() }
        let source = try await makeSource("layout-cover-anchor")

        library.layouts.setCoverPageKey(for: source.book, pageKey: source.keys[1], displayName: "002.jpg")
        library.layouts.setCoverCropAnchor(
            forBookID: source.book.id, sourceURL: source.book.sourceURL, anchor: .left
        )
        library.layouts.clearCoverOverride(forBookID: source.book.id)

        #expect(settings(library, source.book)?.coverPageKey == nil)
        #expect(settings(library, source.book)?.coverCropAnchor == .left)
    }

    @Test("「自動のまま」の指定は、まだ一行も無い本に空の行を作らない")
    func settingTheAutomaticAnchorDoesNotCreateARow() throws {
        let library = try InMemoryLibrary(label: "layout-cover-anchor-empty")
        defer { library.close() }
        let bookID = "/books/never-touched-\(UUID().uuidString).cbz"

        library.layouts.setCoverCropAnchor(forBookID: bookID, sourceURL: nil, anchor: nil)
        #expect(library.layouts.bookLayoutSettings(forBookID: bookID) == nil)

        library.layouts.setCoverCropAnchor(forBookID: bookID, sourceURL: nil, anchor: .center)
        #expect(library.layouts.bookLayoutSettings(forBookID: bookID)?.coverCropAnchor == .center)
    }

    /// 本を読み込まない版は差し替え検知の指紋を記録しない(ページ数が分からないため)。
    /// 中途半端な指紋を書いてしまうと、その本を次に開いたときに「差し替えられた」と
    /// 誤判定してレイアウトを捨てる提案が出る ―― それを踏まないことの確認。
    @Test("本を読み込まずに作った行は指紋を持たず、差し替え検知は判定しない")
    func theBookIDVariantDoesNotRecordAFingerprint() async throws {
        let library = try InMemoryLibrary(label: "layout-cover-fingerprint")
        defer { library.close() }
        let source = try await makeSource("layout-cover-fingerprint")

        library.layouts.setCoverCropAnchor(
            forBookID: source.book.id, sourceURL: source.book.sourceURL, anchor: .right
        )
        #expect(settings(library, source.book)?.recordedPageCount == nil)
        #expect(library.layouts.checkContentReplacement(book: source.book) == .unaffected)
    }
}

/// 通知の回数を数えるだけの箱。`NotificationCenter` のクロージャは `@Sendable` なので、
/// ローカルの `var` は捕まえられない。
private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}
