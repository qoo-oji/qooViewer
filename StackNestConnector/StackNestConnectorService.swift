import Foundation
import os

/// XPC の口を受ける(1 つの接続に 1 つのサービスの物)。
nonisolated final class StackNestConnectorListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = StackNestConnectorService()
        connection.exportedInterface = NSXPCInterface(with: StackNestConnecting.self)
        connection.exportedObject = service
        // 接続が切れたら(アプリが終わった・落ちた)、走っている要求を止めてセッションを畳む。
        connection.invalidationHandler = { service.cancelAll() }
        connection.resume()
        return true
    }
}

/// 要求を StackNest の本の API へ出し、応答を返す。通すのは `StackNestConnectorPolicy` の形だけ。
///
/// - リダイレクトには付いて行かない(3xx はそのまま応答として返す。鍵を別の宛先へ渡さない)。
/// - ephemeral のセッション: ディスクのキャッシュ・クッキー・資格情報の保管・プロキシを使わない。
/// - 本文は `StackNestConnectorPolicy.maxResponseBytes` まで。超えたら受け取りをやめて、その印だけを返す。
/// - どの要求にも返事は 1 度だけ(`Pending.claim`)。
///
/// `@unchecked Sendable`: 変わる状態(`tasks`)は `lock` の中でだけ読み書きし、ロックを持ったまま返事を呼ばない。
nonisolated final class StackNestConnectorService: NSObject, StackNestConnecting, URLSessionDataDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.qooProject.qooViewer.StackNestConnector", category: "connector")
    /// 1 回の要求の無通信の時間切れ。StackNestViewerKit の既定(`requestTimeout`)と同じ。
    private static let requestTimeout: TimeInterval = 20
    /// 1 回の要求の全体の上限。部品は 25 秒で待つのをやめて取り消すので、これはその取り消しが届かなかったときの歯止め。
    private static let resourceTimeout: TimeInterval = 60

    /// 走っている要求 1 件。
    private final class Pending: @unchecked Sendable {
        let id: String
        let reply: @Sendable (Data?, Data?, String?) -> Void
        var response: HTTPURLResponse?
        var body = Data()
        var exceededLimit = false
        private var replied = false

        init(id: String, reply: @escaping @Sendable (Data?, Data?, String?) -> Void) {
            self.id = id
            self.reply = reply
        }

        /// 返事をする権利を 1 度だけ取る(呼ぶのは `lock` の中)。
        func claim() -> Bool {
            guard !replied else { return false }
            replied = true
            return true
        }
    }

    private let lock = NSLock()
    /// URLSession のタスクの番号 → 要求。
    private var pendingByTask: [Int: Pending] = [:]
    /// 要求の ID → タスク。
    private var tasksByID: [String: URLSessionDataTask] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.httpMaximumConnectionsPerHost = 6
        // delegate は強く持たれる(URLSession を無効にするまで)。サービスの物は接続と同じだけ生き、cancelAll で無効にする。
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: - StackNestConnecting

    func send(_ request: Data, withReply reply: @escaping @Sendable (Data?, Data?, String?) -> Void) {
        guard let decoded = try? JSONDecoder().decode(StackNestConnectorRequest.self, from: request) else {
            return reply(nil, nil, StackNestConnectorFailure.refused.rawValue)
        }
        let urlRequest: URLRequest
        switch StackNestConnectorPolicy.validate(decoded) {
        case .success(var validated):
            validated.timeoutInterval = Self.requestTimeout
            urlRequest = validated
        case .failure(let refusal):
            // 鍵も URL も出さない(理由の種類だけ)。
            Self.log.error("refused a request: \(refusal.rawValue, privacy: .public)")
            return reply(nil, nil, StackNestConnectorFailure.refused.rawValue)
        }
        let pending = Pending(id: decoded.id, reply: reply)
        let task = session.dataTask(with: urlRequest)
        let duplicate: Bool = lock.withLock {
            guard tasksByID[decoded.id] == nil else { return true }
            pendingByTask[task.taskIdentifier] = pending
            tasksByID[decoded.id] = task
            return false
        }
        guard !duplicate else { return reply(nil, nil, StackNestConnectorFailure.refused.rawValue) }
        task.resume()
    }

    func cancel(_ requestID: String) {
        let found: (URLSessionDataTask, Pending)? = lock.withLock {
            guard let task = tasksByID.removeValue(forKey: requestID),
                  let pending = pendingByTask.removeValue(forKey: task.taskIdentifier),
                  pending.claim()
            else { return nil }
            return (task, pending)
        }
        guard let (task, pending) = found else { return }
        task.cancel()
        pending.reply(nil, nil, StackNestConnectorFailure.cancelled.rawValue)
    }

    /// 接続が切れたときに、走っている要求をすべて止めてセッションを畳む。
    func cancelAll() {
        let all: [(URLSessionDataTask?, Pending)] = lock.withLock {
            let entries = pendingByTask.map { (key, pending) in
                (tasksByID[pending.id], pending, key)
            }
            pendingByTask.removeAll()
            tasksByID.removeAll()
            return entries.compactMap { task, pending, _ in pending.claim() ? (task, pending) : nil }
        }
        for (task, pending) in all {
            task?.cancel()
            pending.reply(nil, nil, StackNestConnectorFailure.cancelled.rawValue)
        }
        session.invalidateAndCancel()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // 付いて行かない。3xx がそのまま応答になる。
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let allow: Bool = lock.withLock {
            guard let pending = pendingByTask[dataTask.taskIdentifier] else { return false }
            pending.response = response as? HTTPURLResponse
            if response.expectedContentLength > Int64(StackNestConnectorPolicy.maxResponseBytes) {
                pending.exceededLimit = true
                return false
            }
            if response.expectedContentLength > 0 {
                pending.body.reserveCapacity(Int(response.expectedContentLength))
            }
            return true
        }
        // 断った(上限超え)ときは、取り消しの完了で印を返す(didCompleteWithError)。
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow: Bool = lock.withLock {
            guard let pending = pendingByTask[dataTask.taskIdentifier], !pending.exceededLimit else { return false }
            if pending.body.count + data.count > StackNestConnectorPolicy.maxResponseBytes {
                pending.exceededLimit = true
                pending.body = Data()
                return true
            }
            pending.body.append(data)
            return false
        }
        if overflow { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let finished: Pending? = lock.withLock {
            guard let pending = pendingByTask.removeValue(forKey: task.taskIdentifier) else { return nil }
            tasksByID[pending.id] = nil
            return pending.claim() ? pending : nil
        }
        guard let pending = finished else { return }
        if let response = pending.response, error == nil || pending.exceededLimit {
            var headers: [String: String] = [:]
            for name in StackNestConnectorPolicy.returnedResponseHeaders {
                if let value = response.value(forHTTPHeaderField: name) { headers[name] = value }
            }
            let meta = StackNestConnectorResponse(
                statusCode: response.statusCode, headers: headers, exceededLimit: pending.exceededLimit)
            guard let encoded = try? JSONEncoder().encode(meta) else {
                return pending.reply(nil, nil, StackNestConnectorFailure.cannotConnect.rawValue)
            }
            return pending.reply(encoded, pending.exceededLimit ? Data() : pending.body, nil)
        }
        let failure: StackNestConnectorFailure
        switch (error as? URLError)?.code {
        case .timedOut?: failure = .timedOut
        case .cancelled?: failure = .cancelled
        default: failure = .cannotConnect
        }
        pending.reply(nil, nil, failure.rawValue)
    }
}
