import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting

@testable import qooViewer

/// 参照ファイル 1 つと、それに応える StackNestViewerKit の見立て(`StackNestStubServer`。`URLProtocol` で応え、実際には
/// つながない)の一式。作業フォルダの下の参照ファイルから作るセッションには見立ての設定が使われる
/// (`StackNestSessions.useConfigurationForTesting`)。フォルダごとの登録なので、並行して走るほかの試験には効かない。
/// **必ず `close()` すること**(登録が残る)。
///
/// ページの画像は PageImageFactory の色付きの PNG(R = ページ番号 + 1。`PageColorReader` で読み戻せる)にしてある。見立ての
/// 既定のページ(灰色・明るさ = 番号)では 0 番の色が「無い」と紛れるため、範囲内のページの応答を差し替える。
///
/// 見立ての型は `StackNestViewerKitTesting.` を付けて書く(以前の試験の道具に同じ名前の型があり、それが残っている間は
/// 付けないとそちらを指す。付けたままでも害はない)。
///
/// `@unchecked Sendable` の根拠: 持つものは変わらない値(`let`)と、`lock` の中でだけ読み書きする `servedPageCount` だけ。
/// 試験は `fixture.pageRequestIndices` などを待ち合わせの `@Sendable` な閉包の中で読む(2026-10-19: Xcode 26.6 では
/// `#expect` の中でも送信可能でない値の捕捉が警告になり、警告をエラー扱いにした CI のテストのビルドが止まった)。
nonisolated final class StackNestTestBook: @unchecked Sendable {
    static let token = "test-token-0123456789abcdef"

    let temporary: TemporaryDirectory
    let server: StackNestViewerKitTesting.StackNestStubServer
    let referenceURL: URL
    private let lock = NSLock()
    private var servedPageCount: Int

    init(
        pageCount: Int = 6, startPage: Int = 0, expiresAt: Date = Date().addingTimeInterval(86_400),
        title: String = "Reference Title", direction: String = "rtl", label: String = "stacknest",
        fileName: String = "Sample Book.stacknestbook"
    ) throws {
        temporary = try TemporaryDirectory(label)
        server = StackNestViewerKitTesting.StackNestStubServer(pageCount: pageCount, direction: direction)
        servedPageCount = 0
        referenceURL = temporary.file(fileName)
        StackNestSessions.shared.useConfigurationForTesting(server.configuration(), under: temporary.url)
        setPageCount(pageCount)
        try writeReference(pageCount: pageCount, startPage: startPage, expiresAt: expiresAt, title: title)
    }

    /// manifest が答えるページ数を変え、そのページ数ぶんの色付きのページを用意する(範囲の外は見立ての既定の 404)。
    func setPageCount(_ count: Int) {
        server.setPageCount(count)
        let start = lock.withLock { () -> Int in
            defer { servedPageCount = max(servedPageCount, count) }
            return servedPageCount
        }
        for index in start..<max(count, start) {
            server.respond(
                .page(index),
                with: .status(200, headers: ["Content-Type": "image/png"], body: PageImageFactory.png(number: UInt8(index + 1)))
            )
        }
    }

    /// StackNest が開き直したときと同じく、同じパスへ書き直す。見立てが期待する鍵もこの `token` にする。
    func writeReference(
        token: String = StackNestTestBook.token, pageCount: Int, startPage: Int,
        expiresAt: Date = Date().addingTimeInterval(86_400), title: String = "Reference Title",
        bookURL: URL? = nil
    ) throws {
        // 見立ての `reference(token:)` は、期待する鍵を覚える(記録の `carriesExpectedToken` がこの鍵で判定される)。
        _ = try server.reference(token: token)
        try Self.referenceJSON(
            bookURL: bookURL ?? server.bookURL, token: token, pageCount: pageCount, startPage: startPage,
            expiresAt: expiresAt, title: title
        ).write(to: referenceURL)
    }

    /// 以後の `index` 番のページの応答を、返した門が開くまで止める(開け忘れても 60 秒で流れる)。
    func holdPage(_ index: Int) -> StackNestViewerKitTesting.StubGate {
        server.gate(.page(index))
    }

    var requests: [StackNestViewerKitTesting.StackNestStubServer.RecordedRequest] { server.requests }

    /// 届いたページの要求の番号(届いた順)。
    var pageRequestIndices: [Int] {
        requests.compactMap { request in
            if case .page(let index) = request.route { return index }
            return nil
        }
    }

    var manifestRequestCount: Int { server.requestCount(.manifest) }

    /// 書き戻しで届いたページ番号(届いた順)。
    var progressPages: [Int] { requests.compactMap(\.progressPage) }

    func close() {
        StackNestSessions.shared.endUsingConfigurationForTesting(under: temporary.url)
    }

    /// 参照ファイルの中身(StackNest が書くものと同じ形。題名を変えられるよう、部品の `StackNestFixtures` ではなくここで組む)。
    static func referenceJSON(
        bookURL: URL, token: String, pageCount: Int, startPage: Int, expiresAt: Date, title: String = "Reference Title"
    ) -> Data {
        let object: [String: Any] = [
            "format": "stacknest-book-reference", "version": 1, "title": title, "book": bookURL.absoluteString,
            "token": token, "expiresAt": expiresAt.formatted(.iso8601), "pageCount": pageCount, "direction": "rtl",
            "startPage": startPage,
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
