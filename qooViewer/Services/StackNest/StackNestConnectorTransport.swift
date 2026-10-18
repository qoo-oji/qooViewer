import Foundation
import os

/// StackNest への要求を運ぶ道(本番は XPC サービス StackNestConnector。試験は見立てを差し込む)。
nonisolated protocol StackNestConnectorTransport: Sendable {
    /// 要求を送る。`completion` はどの要求にも 1 度だけ呼ばれる(取り消した要求も `.cancelled` で)。どのスレッドから
    /// 呼ばれるかは決まっていない。
    func send(
        _ request: StackNestConnectorRequest,
        completion: @escaping @Sendable (Result<(StackNestConnectorResponse, Data), StackNestConnectorFailure>) -> Void
    )
    /// 送った要求を取り消す。`completion` は `.cancelled` で呼ばれる(もう返事が来ていれば何もしない)。
    func cancel(_ requestID: String)
}

/// XPC サービス StackNestConnector への道(アプリで 1 つ)。
///
/// ■ 返事は必ず 1 度
/// XPC は、サービスが落ちた・起動できないときに返事の閉包を呼ばない(エラーの閉包だけが呼ばれる。中断なら何も呼ばれない)。
/// そのため送った要求を `pending` に控え、返事・エラー・中断・無効化・取り消しのどれが先でも、控えから外した側だけが
/// `completion` を呼ぶ。中断(サービスが落ちて立ち直る)のときは、控えている要求をすべて `.unavailable` で終わらせる
/// (部品はつながらない失敗として扱い、次の要求は新しいサービスへ行く)。
nonisolated final class StackNestConnectorClient: StackNestConnectorTransport, @unchecked Sendable {
    typealias Completion = @Sendable (Result<(StackNestConnectorResponse, Data), StackNestConnectorFailure>) -> Void

    /// アプリの Info.plist の `QOOStackNestConnectorService`(サービスのバンドル ID。Debug と Release で違う)。
    static let serviceNameInfoKey = "QOOStackNestConnectorService"

    /// アプリで 1 つの道。接続は最初の要求で作る(StackNest の本を開かなければサービスは起動しない)。
    static let shared = StackNestConnectorClient(
        serviceName: Bundle.main.object(forInfoDictionaryKey: serviceNameInfoKey) as? String)

    private static let log = Logger(subsystem: "com.qooProject.qooViewer", category: "StackNestConnector")

    private let serviceName: String?
    private let lock = NSLock()
    /// `lock` の中でだけ読み書きする。
    private var connection: NSXPCConnection?
    private var pending: [String: Completion] = [:]

    init(serviceName: String?) {
        self.serviceName = serviceName
    }

    func send(_ request: StackNestConnectorRequest, completion: @escaping Completion) {
        guard let encoded = try? JSONEncoder().encode(request) else { return completion(.failure(.refused)) }
        let id = request.id
        let admitted: Result<NSXPCConnection, StackNestConnectorFailure> = lock.withLock {
            guard pending[id] == nil else { return .failure(.refused) }
            guard let connection = connectionLocked() else { return .failure(.unavailable) }
            pending[id] = completion
            return .success(connection)
        }
        let connection: NSXPCConnection
        switch admitted {
        case .success(let admittedConnection): connection = admittedConnection
        case .failure(let failure): return completion(.failure(failure))
        }
        // 代理はロックの外で作る(エラーの閉包がその場で呼ばれても、ロックを取り直して止まらないように)。
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.finish(id, with: .failure(.unavailable))
        }) as? StackNestConnecting else {
            return finish(id, with: .failure(.unavailable))
        }
        proxy.send(encoded) { [weak self] meta, body, failure in
            let result: Result<(StackNestConnectorResponse, Data), StackNestConnectorFailure>
            if let meta, let response = try? JSONDecoder().decode(StackNestConnectorResponse.self, from: meta) {
                result = .success((response, body ?? Data()))
            } else {
                result = .failure(failure.flatMap(StackNestConnectorFailure.init(rawValue:)) ?? .cannotConnect)
            }
            self?.finish(id, with: result)
        }
    }

    func cancel(_ requestID: String) {
        let connection = lock.withLock { self.connection }
        finish(requestID, with: .failure(.cancelled))
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? StackNestConnecting)?.cancel(requestID)
    }

    /// 控えから外せた側だけが `completion` を呼ぶ。
    private func finish(_ id: String, with result: Result<(StackNestConnectorResponse, Data), StackNestConnectorFailure>) {
        guard let completion = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
        completion(result)
    }

    /// 控えている要求をすべて `.unavailable` で終える(中断・無効化)。
    private func failAllPending(invalidated: Bool) {
        let all: [Completion] = lock.withLock {
            let completions = Array(pending.values)
            pending.removeAll()
            if invalidated { connection = nil }
            return completions
        }
        if !all.isEmpty { Self.log.error("connector \(invalidated ? "invalidated" : "interrupted", privacy: .public); failing \(all.count) request(s)") }
        for completion in all { completion(.failure(.unavailable)) }
    }

    private func connectionLocked() -> NSXPCConnection? {
        if let connection { return connection }
        guard let serviceName else { return nil }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: StackNestConnecting.self)
        connection.interruptionHandler = { [weak self] in self?.failAllPending(invalidated: false) }
        connection.invalidationHandler = { [weak self] in self?.failAllPending(invalidated: true) }
        connection.resume()
        self.connection = connection
        return connection
    }
}

/// StackNestViewerKit のセッションの要求を、`StackNestConnectorTransport` へ回す `URLProtocol`。
///
/// 部品の `StackNestBookSession.Configuration.makeURLSessionConfiguration` で、このクラスだけを `protocolClasses` に入れた
/// 設定を渡す(`makeSessionConfiguration()`)。アプリ本体のプロセスはソケットを開かない(本体にネットワークの entitlement は無い)。
/// 部品の側の決まり(宛先の制限・リダイレクトの拒否・本文の上限・時間切れ)はそのまま効き、サービスの側でも同じ形を確かめる
/// (StackNestConnectorPolicy)。
///
/// 試験は、このクラスを継承して `transport` を自分の見立てへ差し替えたクラスを使う(共有の状態を触らない)。
nonisolated class StackNestConnectorURLProtocol: URLProtocol, @unchecked Sendable {
    /// 要求を運ぶ道。
    class var transport: any StackNestConnectorTransport { StackNestConnectorClient.shared }

    /// このクラスだけを通す URLSession の設定。
    class func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stateLock = NSLock()
    /// `stateLock` の中でだけ読み書きする。
    private var sentID: String?
    private var isStopped = false
    /// `startLoading` を呼んだスレッドの run loop とその時のモード。`client` へはここからだけ知らせる(URLProtocol の約束:
    /// client はこの読み込みを始めたスレッドから呼ぶ。2026-10-18 のレビュー ―― 以前は XPC の返事のキューから直に呼んでいて、
    /// 取り消し(stopLoading)と食い違う・完了が落ちるおそれがあった)。`startLoading` の中で書き、以後は読むだけ。
    private var clientRunLoop: CFRunLoop?
    private var clientModes: [CFString] = []

    /// `body` を、この読み込みを始めたスレッドの run loop で走らせる。
    private func performOnClientThread(_ body: @escaping () -> Void) {
        guard let runLoop = clientRunLoop else { return body() }
        CFRunLoopPerformBlock(runLoop, clientModes as CFArray, body)
        CFRunLoopWakeUp(runLoop)
    }

    override func startLoading() {
        clientRunLoop = CFRunLoopGetCurrent()
        let mode = RunLoop.current.currentMode ?? .default
        clientModes = mode == .default ? [CFRunLoopMode.defaultMode.rawValue] : [mode.rawValue as CFString, CFRunLoopMode.defaultMode.rawValue]
        let request = self.request
        guard let url = request.url else { return fail(.refused) }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:]
        where StackNestConnectorPolicy.forwardedRequestHeaders.contains(name.lowercased()) {
            headers[name] = value
        }
        let body = Self.body(of: request)
        guard body.map({ $0.count <= StackNestConnectorPolicy.maxRequestBodyBytes }) ?? true else { return fail(.refused) }
        let outgoing = StackNestConnectorRequest(
            id: UUID().uuidString, method: request.httpMethod ?? "GET", url: url.absoluteString, headers: headers,
            body: body)
        // 送る前にここでも形を確かめる(サービスの判定と同じ。通らないものは XPC に載せない)。
        if case .failure = StackNestConnectorPolicy.validate(outgoing) { return fail(.refused) }
        let proceeds: Bool = stateLock.withLock {
            guard !isStopped else { return false }
            sentID = outgoing.id
            return true
        }
        guard proceeds else { return }
        type(of: self).transport.send(outgoing) { [self] result in
            performOnClientThread { [self] in
                // 止めた後は client に触れない(stopLoading も同じスレッドで呼ばれるので、ここで見れば食い違わない)。
                let delivers = stateLock.withLock { () -> Bool in
                    guard !isStopped else { return false }
                    sentID = nil
                    return true
                }
                guard delivers else { return }
                switch result {
                case .success(let (meta, body)):
                    deliver(meta, body: body, for: url)
                case .failure(let failure):
                    fail(failure)
                }
            }
        }
    }

    override func stopLoading() {
        let id: String? = stateLock.withLock {
            isStopped = true
            defer { sentID = nil }
            return sentID
        }
        if let id { type(of: self).transport.cancel(id) }
    }

    private func deliver(_ meta: StackNestConnectorResponse, body: Data, for url: URL) {
        var headers = meta.headers
        // 上限を超えた本文は届かない。上限を超える長さを申告する応答として渡すと、部品は自分の上限で `.responseTooLarge` にする。
        headers["Content-Length"] = String(meta.exceededLimit ? StackNestConnectorPolicy.maxResponseBytes + 1 : body.count)
        guard let response = HTTPURLResponse(url: url, statusCode: meta.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return fail(.cannotConnect) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ failure: StackNestConnectorFailure) {
        let code: URLError.Code
        switch failure {
        case .refused: code = .unsupportedURL
        case .timedOut: code = .timedOut
        case .cancelled: code = .cancelled
        case .cannotConnect, .unavailable: code = .cannotConnectToHost
        }
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }

    /// POST の本文(URLSession は `httpBody` をストリームに移して渡してくる)。上限+1 バイトまでしか読まない。
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable, data.count <= StackNestConnectorPolicy.maxRequestBodyBytes {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
