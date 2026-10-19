import Foundation
import Testing

@testable import qooViewer

/// StackNest への通信を XPC サービス(StackNestConnector.xpc)へ回す道。通してよい要求の形(StackNestConnectorPolicy。アプリと
/// サービスが同じ判定をする)と、部品のセッションの要求を運び手へ渡す `StackNestConnectorURLProtocol` を固定する。
/// 実物のサービスとの往復は `TEST_RUNNER_QOO_STACKNEST_CONNECTOR_PROBE_URL` を付けたときだけ走る(docs/10)。
struct StackNestConnectorPolicyTests {
    private static let bearer = ["Authorization": "Bearer test-token-0123456789"]

    private static func request(
        _ url: String, method: String = "GET", headers: [String: String] = bearer, body: Data? = nil
    ) -> StackNestConnectorRequest {
        StackNestConnectorRequest(id: UUID().uuidString, method: method, url: url, headers: headers, body: body)
    }

    private static func refusal(_ request: StackNestConnectorRequest) -> StackNestConnectorPolicy.Refusal? {
        if case .failure(let refusal) = StackNestConnectorPolicy.validate(request) { return refusal }
        return nil
    }

    @Test(
        "StackNest の本の基点の下の 4 つの要求は通す(ローカルの本・中継の本、IPv4・IPv6)",
        arguments: [
            "http://127.0.0.1:51234/api/v1/libraries/0F8D2C1E-1111-2222-3333-444455556666/books/12/manifest",
            "http://127.0.0.1:51234/api/v1/libraries/lib-1/books/12/manifest?pageNames=1",
            "http://127.0.0.1/api/v1/relay/R1/manifest?pageNames=1",
            "http://127.0.0.1:51234/api/v1/libraries/lib-1/books/12/pages/0",
            "http://127.0.0.1:51234/api/v1/libraries/lib-1/books/12/pages/41?maxw=1600",
            "http://127.0.0.1:51234/api/v1/libraries/lib-1/books/12/cover?maxw=300",
            "http://[::1]:51234/api/v1/relay/Abc_-123.x~/manifest",
            "http://127.0.0.1/api/v1/relay/R1/pages/3",
        ]
    )
    func acceptsBookEndpoints(url: String) {
        #expect(Self.refusal(Self.request(url)) == nil)
    }

    @Test("読書位置の POST は JSON の本文を 64 KiB まで通す。GET には本文を付けさせない")
    func progressNeedsAJSONBody() {
        let url = "http://127.0.0.1:51234/api/v1/libraries/lib/books/1/progress"
        var headers = Self.bearer
        headers["Content-Type"] = "application/json"
        #expect(Self.refusal(Self.request(url, method: "POST", headers: headers, body: Data(#"{"page":3}"#.utf8))) == nil)
        #expect(Self.refusal(Self.request(url, method: "POST", headers: headers, body: nil)) == .body)
        let large = Data(repeating: 0x20, count: StackNestConnectorPolicy.maxRequestBodyBytes + 1)
        #expect(Self.refusal(Self.request(url, method: "POST", headers: headers, body: large)) == .body)
        #expect(Self.refusal(Self.request(url, method: "GET")) == .method)
        let manifest = "http://127.0.0.1:51234/api/v1/libraries/lib/books/1/manifest"
        #expect(Self.refusal(Self.request(manifest, method: "POST", headers: headers, body: Data("{}".utf8))) == .method)
        #expect(Self.refusal(Self.request(manifest, body: Data("x".utf8))) == .body)
    }

    @Test(
        "ほかの宛先・形は断る",
        arguments: [
            ("https://127.0.0.1:51234/api/v1/relay/R/manifest", StackNestConnectorPolicy.Refusal.scheme),
            ("http://localhost:51234/api/v1/relay/R/manifest", .host),
            ("http://192.168.0.10:51234/api/v1/relay/R/manifest", .host),
            ("http://127.0.0.2:51234/api/v1/relay/R/manifest", .host),
            ("http://example.com/api/v1/relay/R/manifest", .host),
            ("http://user:pw@127.0.0.1:51234/api/v1/relay/R/manifest", .credentials),
            ("http://127.0.0.1:51234/api/v1/relay/R/manifest#x", .fragment),
            ("http://127.0.0.1:51234/api/v2/relay/R/manifest", .path),
            ("http://127.0.0.1:51234/admin/shutdown", .path),
            ("http://127.0.0.1:51234/api/v1/relay/R/manifest/extra", .path),
            ("http://127.0.0.1:51234/api/v1/relay/R/", .path),
            ("http://127.0.0.1:51234/api/v1/relay//manifest", .path),
            ("http://127.0.0.1:51234/api/v1/relay/../manifest", .path),
            ("http://127.0.0.1:51234/api/v1/relay/R%2F..%2Fx/manifest", .path),
            ("http://127.0.0.1:51234/api/v1/libraries/lib/books/abc/manifest", .path),
            ("http://127.0.0.1:51234/api/v1/libraries/lib/books/1/pages/-1", .path),
            ("http://127.0.0.1:51234/api/v1/libraries/lib/books/1/pages/1?maxw=1&x=2", .query),
            ("http://127.0.0.1:51234/api/v1/libraries/lib/books/1/manifest?maxw=10", .query),
            ("http://127.0.0.1:51234/api/v1/libraries/lib/books/1/manifest?pageNames=0", .query),
            ("http://127.0.0.1:51234/api/v1/libraries/lib/books/1/manifest?pageNames=1&x=2", .query),
            ("http://127.0.0.1:51234/api/v1/libraries/lib/books/1/pages/1?pageNames=1", .query),
            ("http://127.0.0.1:51234/api/v1/libraries/lib/books/1/progress?pageNames=1", .query),
        ]
    )
    func refusesOtherTargets(url: String, expected: StackNestConnectorPolicy.Refusal) {
        #expect(Self.refusal(Self.request(url)) == expected)
    }

    @Test("ヘッダは鍵・名乗り・本文の型だけ。鍵の無い要求、改行の入った値は断る")
    func headersAreRestricted() {
        let url = "http://127.0.0.1:51234/api/v1/relay/R/manifest"
        #expect(Self.refusal(Self.request(url, headers: [:])) == .header)
        #expect(Self.refusal(Self.request(url, headers: ["Authorization": "Basic abc"])) == .header)
        #expect(Self.refusal(Self.request(url, headers: Self.bearer.merging(["Cookie": "a=b"]) { $1 })) == .header)
        #expect(Self.refusal(Self.request(url, headers: ["Authorization": "Bearer a\r\nX-Evil: 1"])) == .header)
        let named = Self.bearer.merging(["X-StackNest-Viewer": "com.example/1.0; format=1; kit=0.1.0"]) { $1 }
        guard case .success(let request) = StackNestConnectorPolicy.validate(Self.request(url, headers: named)) else {
            Issue.record("名乗り付きの要求が通らない")
            return
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-0123456789")
        #expect(request.value(forHTTPHeaderField: "X-StackNest-Viewer") == "com.example/1.0; format=1; kit=0.1.0")
        #expect(request.httpMethod == "GET")
    }
}

/// `StackNestConnectorURLProtocol` を、見立ての運び手に差し替えて使う(共有の XPC の道は使わない)。試験ごとに別のクラスにして、
/// 並行して走る試験と見立てを共有しない。
private final class RecordingTransport: StackNestConnectorTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [StackNestConnectorRequest] = []
    private var cancelled: [String] = []
    private var pending: [String: @Sendable (Result<(StackNestConnectorResponse, Data), StackNestConnectorFailure>) -> Void] = [:]
    /// nil なら応答を止めておく(取り消しの試験)。
    var answer: Result<(StackNestConnectorResponse, Data), StackNestConnectorFailure>?

    func send(
        _ request: StackNestConnectorRequest,
        completion: @escaping @Sendable (Result<(StackNestConnectorResponse, Data), StackNestConnectorFailure>) -> Void
    ) {
        let answer: Result<(StackNestConnectorResponse, Data), StackNestConnectorFailure>? = lock.withLock {
            sent.append(request)
            if self.answer == nil { pending[request.id] = completion }
            return self.answer
        }
        if let answer { completion(answer) }
    }

    func cancel(_ requestID: String) {
        let completion = lock.withLock { () -> (@Sendable (Result<(StackNestConnectorResponse, Data), StackNestConnectorFailure>) -> Void)? in
            cancelled.append(requestID)
            return pending.removeValue(forKey: requestID)
        }
        completion?(.failure(.cancelled))
    }

    var sentRequests: [StackNestConnectorRequest] { lock.withLock { sent } }
    var cancelledIDs: [String] { lock.withLock { cancelled } }
}

private let answeringTransport = RecordingTransport()
private final class AnsweringProtocol: StackNestConnectorURLProtocol, @unchecked Sendable {
    override class var transport: any StackNestConnectorTransport { answeringTransport }
}

private let refusingTransport = RecordingTransport()
private final class RefusingProtocol: StackNestConnectorURLProtocol, @unchecked Sendable {
    override class var transport: any StackNestConnectorTransport { refusingTransport }
}

private let oversizeTransport = RecordingTransport()
private final class OversizeProtocol: StackNestConnectorURLProtocol, @unchecked Sendable {
    override class var transport: any StackNestConnectorTransport { oversizeTransport }
}

private let stallingTransport = RecordingTransport()
private final class StallingProtocol: StackNestConnectorURLProtocol, @unchecked Sendable {
    override class var transport: any StackNestConnectorTransport { stallingTransport }
}

struct StackNestConnectorURLProtocolTests {
    private static let manifestURL = URL(string: "http://127.0.0.1:51234/api/v1/relay/R1/manifest")!

    private static func session(_ type: StackNestConnectorURLProtocol.Type) -> URLSession {
        URLSession(configuration: type.makeSessionConfiguration())
    }

    @Test("部品のセッションの要求を、許したヘッダだけ付けて運び手へ渡し、応答をそのまま返す")
    func forwardsRequestsAndResponses() async throws {
        answeringTransport.answer = .success((
            StackNestConnectorResponse(statusCode: 403, headers: ["Content-Type": "application/json", "X-Library-Locked": "1"]),
            Data("{}".utf8)
        ))
        let session = Self.session(AnsweringProtocol.self)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.manifestURL)
        request.setValue("Bearer test-token-0123456789", forHTTPHeaderField: "Authorization")
        request.setValue("com.example/1.0; format=1", forHTTPHeaderField: "X-StackNest-Viewer")
        request.setValue("private", forHTTPHeaderField: "X-Other")
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 403)
        #expect(http.value(forHTTPHeaderField: "X-Library-Locked") == "1")
        #expect(data == Data("{}".utf8))
        let sent = try #require(answeringTransport.sentRequests.last)
        #expect(sent.url == Self.manifestURL.absoluteString)
        #expect(sent.method == "GET")
        #expect(Set(sent.headers.keys.map { $0.lowercased() }) == ["authorization", "x-stacknest-viewer"])
    }

    @Test("決まった形でない要求は運び手へ渡さずに失敗させる")
    func refusesWithoutSending() async {
        refusingTransport.answer = .success((StackNestConnectorResponse(statusCode: 200, headers: [:]), Data()))
        let session = Self.session(RefusingProtocol.self)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:51234/admin/shutdown")!)
        request.setValue("Bearer test-token-0123456789", forHTTPHeaderField: "Authorization")
        await #expect(throws: URLError.self) { _ = try await session.data(for: request) }
        #expect(refusingTransport.sentRequests.isEmpty)
    }

    @Test("上限を超えた本文は、上限を超える長さを申告する応答として部品へ渡す")
    func oversizeBodyIsAnnouncedAsTooLong() async throws {
        oversizeTransport.answer = .success((
            StackNestConnectorResponse(statusCode: 200, headers: ["Content-Type": "image/png"], exceededLimit: true), Data()
        ))
        let session = Self.session(OversizeProtocol.self)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.manifestURL)
        request.setValue("Bearer test-token-0123456789", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        #expect(response.expectedContentLength == Int64(StackNestConnectorPolicy.maxResponseBytes + 1))
    }

    @Test("取り消した要求は運び手にも取り消しを伝える")
    func cancellationReachesTheTransport() async throws {
        stallingTransport.answer = nil
        let session = Self.session(StallingProtocol.self)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.manifestURL)
        request.setValue("Bearer test-token-0123456789", forHTTPHeaderField: "Authorization")
        let task = Task { try await session.data(for: request) }
        let limit = Date().addingTimeInterval(5)
        while stallingTransport.sentRequests.isEmpty, Date() < limit { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        _ = try? await task.value
        let sentID = try #require(stallingTransport.sentRequests.first?.id)
        let cancelLimit = Date().addingTimeInterval(5)
        while !stallingTransport.cancelledIDs.contains(sentID), Date() < cancelLimit { try await Task.sleep(for: .milliseconds(10)) }
        #expect(stallingTransport.cancelledIDs.contains(sentID))
    }

    /// 手で走らせる確かめ: 実物の XPC サービスを通して、この Mac の見立てのサーバ(`QOO_STACKNEST_CONNECTOR_PROBE_URL` の基点。
    /// 例 `http://127.0.0.1:51234`)へ manifest の GET を送り、応答が返る(状態は問わない)ことを見る。
    nonisolated static let probeBase = ProcessInfo.processInfo.environment["QOO_STACKNEST_CONNECTOR_PROBE_URL"]
        .flatMap(URL.init(string:))

    @Test("実物の StackNestConnector.xpc を通して、この Mac の見立てのサーバから応答が返る(手動)",
          .enabled(if: StackNestConnectorURLProtocolTests.probeBase != nil))
    func realServiceRoundTrip() async throws {
        let base = try #require(Self.probeBase)
        let client = StackNestConnectorClient(
            serviceName: Bundle.main.object(forInfoDictionaryKey: StackNestConnectorClient.serviceNameInfoKey) as? String)
        let request = StackNestConnectorRequest(
            id: UUID().uuidString, method: "GET", url: base.appending(path: "api/v1/relay/probe/manifest").absoluteString,
            headers: ["Authorization": "Bearer probe-token"], body: nil)
        let result = await withCheckedContinuation { continuation in
            client.send(request) { continuation.resume(returning: $0) }
        }
        switch result {
        case .success(let (response, _)):
            #expect(response.statusCode > 0)
        case .failure(let failure):
            Issue.record("サービスから応答が返らない: \(failure)")
        }
    }
}
