import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

@testable import qooViewer

/// 参照ファイルの本のセッションの表(StackNestSessions)と、部品の文言を qooViewer の言語で出す口(StackNestText)。
struct StackNestSessionsTests {
    @Test("同じ参照ファイル(同じ中身)からは同じセッション。StackNest が書き直したら(鍵が変わったら)新しいセッション")
    func sharesOneSessionPerReference() throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let first = try StackNestSessions.shared.book(forReferenceAt: fixture.referenceURL)
        let again = try StackNestSessions.shared.book(forReferenceAt: fixture.referenceURL)
        #expect(first === again)
        // StackNest が開き直した: 同じパスへ新しい鍵で書き直す。開いたままの古いセッションを渡してはいけない。
        try fixture.writeReference(token: "renewed-token-0123456789", pageCount: 3, startPage: 0)
        let renewed = try StackNestSessions.shared.book(forReferenceAt: fixture.referenceURL)
        #expect(renewed !== first)
        #expect(renewed.reference.token == "renewed-token-0123456789")
        // 古いセッションは、持っている人がいる間はそのまま(古い鍵のまま)。
        #expect(first.reference.token == StackNestTestBook.token)
        // 新しいセッションは表に残る。
        #expect(try StackNestSessions.shared.book(forReferenceAt: fixture.referenceURL) === renewed)
    }

    @Test("要求の門は接続先ごとに 1 つ: 同じ StackNest の 2 冊は門を共有し、試験は作業フォルダごとに別の門")
    func gateIsSharedPerOrigin() throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let other = fixture.temporary.file("Other Book.stacknestbook")
        try StackNestTestBook.referenceJSON(
            bookURL: fixture.server.bookURL, token: StackNestTestBook.token, pageCount: 3, startPage: 0,
            expiresAt: Date().addingTimeInterval(86_400)
        ).write(to: other)
        let first = try StackNestSessions.shared.book(forReferenceAt: fixture.referenceURL)
        let second = try StackNestSessions.shared.book(forReferenceAt: other)
        #expect(first !== second)
        #expect(first.gate === second.gate)
        // 別の試験(別の作業フォルダ)は、宛先が同じでも門を分ける(並行して走る試験が混ざらない)。
        let elsewhere = try StackNestTestBook(pageCount: 3, label: "stacknest-elsewhere")
        defer { elsewhere.close() }
        let third = try StackNestSessions.shared.book(forReferenceAt: elsewhere.referenceURL)
        #expect(third.gate !== first.gate)
    }

    @Test("表は弱い参照だけを持つ: 持ち主が手放したセッションは残らない")
    func releasedSessionsAreNotKept() throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        weak var released: StackNestSessions.Book?
        do {
            let book = try StackNestSessions.shared.book(forReferenceAt: fixture.referenceURL)
            released = book
            #expect(released != nil)
        }
        #expect(released == nil)
    }

    @Test("127.0.0.1・::1 でない宛先の参照ファイルは、セッションを作らずに hostNotAllowed(要求を出さない)")
    func nonLoopbackBookIsRefused() throws {
        let fixture = try StackNestTestBook(pageCount: 3)
        defer { fixture.close() }
        let lan = try #require(URL(string: "http://192.0.2.10:51234/api/v1/libraries/L/books/1"))
        try fixture.writeReference(pageCount: 3, startPage: 0, bookURL: lan)
        #expect(throws: StackNestViewerError(.hostNotAllowed)) {
            _ = try StackNestSessions.shared.book(forReferenceAt: fixture.referenceURL)
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test("壊れた参照ファイルは部品の invalidReference")
    func brokenReferenceIsInvalid() throws {
        let folder = try TemporaryDirectory("stacknest-broken")
        let url = folder.file("Broken.stacknestbook")
        try Data("{}".utf8).write(to: url)
        #expect(throws: StackNestViewerError(.invalidReference)) {
            _ = try StackNestSessions.shared.book(forReferenceAt: url)
        }
    }

    @Test("文言は qooViewer の表示言語とアプリの名前で出す(Debug の表示名「qooViewer Debug」は使わない)")
    func messagesUseTheAppLanguageAndName() {
        let error = StackNestViewerError(.hostNotAllowed)
        #expect(
            StackNestText.message(for: error, locale: Locale(identifier: "ja"))
                == "この本の接続先がこの Mac ではないため、qooViewer は接続しません。StackNest から開き直してください。"
        )
        #expect(
            StackNestText.message(for: error, locale: Locale(identifier: "en"))
                == "This book's address isn't on this Mac, so qooViewer won't connect to it. Open the book from StackNest again."
        )
        #expect(StackNestText.message(for: StackNestViewerError(.httpStatus, statusCode: 503), locale: Locale(identifier: "en"))
            == "StackNest returned an error (HTTP 503).")
    }

    @Test("開けなかったときのアラートの文言は、表示言語(AppLanguage)の部品の文言")
    func openErrorDescribesInTheAppLanguage() {
        let failure = StackNestOpenError(error: StackNestViewerError(.libraryLocked))
        #expect(failure.errorDescription == StackNestText.message(for: failure.error, locale: AppLanguage.currentLocale))
    }
}
