import Foundation
import os

/// NetFS へ頼んだマウントの結果(`NetworkVolumeConnecting.mount` の返事を読んだもの)。
nonisolated enum NetworkMountResult: Equatable, Sendable {
    /// マウントされた(マウント先。共有の選択で複数を選べば複数)。
    case mounted([String])
    /// 利用者が認証・共有の選択のダイアログで取り消した。
    case cancelled
    /// 失敗した(NetFS の値: 正 = errno、負 = OSStatus)。
    case failed(Int32)
    /// サービスに届かない(起動できない・落ちた・テストの中)。
    case unavailable

    init(status: Int32, mountPoints: Data?) {
        switch status {
        case 0: self = .mounted(NetworkVolumeConnectorPolicy.decodeNames(mountPoints))
        case NetworkVolumeConnectorPolicy.userCanceledStatus, ECANCELED: self = .cancelled
        default: self = .failed(status)
        }
    }
}

/// サーバ探しとマウントを運ぶ道(本番は XPC サービス NetworkVolumeConnector。試験は見立てを差し込む)。
nonisolated protocol NetworkVolumeConnectorTransport: AnyObject, Sendable {
    /// 探し始める。`onChange` は見つかっているサーバの名前が変わるたびに呼ばれる(どのスレッドからかは決まっていない)。
    func startBrowsing(onChange: @escaping @Sendable ([String]) -> Void)
    func stopBrowsing()
    /// `completion` はどの要求にも 1 度だけ呼ばれる(どのスレッドからかは決まっていない)。
    func mount(serverName: String, completion: @escaping @Sendable (NetworkMountResult) -> Void)
}

/// XPC サービス NetworkVolumeConnector への道(アプリで 1 つ。`AppStores.Dependencies.live()` が作る)。
///
/// ■ 返事は必ず 1 度
/// XPC は、サービスが落ちた・起動できないときに返事の閉包を呼ばない(StackNestConnectorClient の型コメント)。マウントの返事は
/// `Once` で返事・エラーの閉包のどちらか先の方だけを通す。
/// ■ サービスが落ちたら
/// 中断(interruption)のあとは一覧を空にし、探している途中なら新しいサービスで探し直す。
nonisolated final class NetworkVolumeConnectorClient: NSObject, NetworkVolumeConnectorTransport, NetworkVolumeConnectorObserving,
    @unchecked Sendable {
    /// アプリの Info.plist の `QOONetworkVolumeConnectorService`(サービスのバンドル ID。Debug と Release で違う)。
    static let serviceNameInfoKey = "QOONetworkVolumeConnectorService"

    private static let log = Logger(subsystem: "com.qooProject.qooViewer", category: "NetworkVolumeConnector")

    private let serviceName: String
    private let lock = NSLock()
    /// 以下は `lock` の中でだけ読み書きする。
    private var connection: NSXPCConnection?
    private var onChange: (@Sendable ([String]) -> Void)?

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    /// アプリの Info.plist から作る(キーが無ければ nil)。
    static func fromMainBundle() -> NetworkVolumeConnectorClient? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: serviceNameInfoKey) as? String, !name.isEmpty else { return nil }
        return NetworkVolumeConnectorClient(serviceName: name)
    }

    // MARK: - NetworkVolumeConnectorTransport

    func startBrowsing(onChange: @escaping @Sendable ([String]) -> Void) {
        let connection = lock.withLock {
            self.onChange = onChange
            return connectionLocked()
        }
        proxy(of: connection)?.startBrowsing()
    }

    func stopBrowsing() {
        let connection = lock.withLock {
            onChange = nil
            return self.connection
        }
        guard let connection else { return }
        proxy(of: connection)?.stopBrowsing()
    }

    func mount(serverName: String, completion: @escaping @Sendable (NetworkMountResult) -> Void) {
        let once = Once(completion)
        let connection = lock.withLock { connectionLocked() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            Self.log.error("mount request did not reach the service: \(String(describing: error), privacy: .public)")
            once.call(.unavailable)
        }) as? NetworkVolumeConnecting else {
            return once.call(.unavailable)
        }
        proxy.mount(serverName: serverName) { status, mountPoints in
            once.call(NetworkMountResult(status: status, mountPoints: mountPoints))
        }
    }

    // MARK: - NetworkVolumeConnectorObserving(サービスからの知らせ)

    func serversDidChange(_ names: Data) {
        let handler = lock.withLock { onChange }
        handler?(NetworkVolumeConnectorPolicy.decodeNames(names))
    }

    // MARK: - 接続

    /// 呼ぶのは `lock` の中。
    private func connectionLocked() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: NetworkVolumeConnecting.self)
        connection.exportedInterface = NSXPCInterface(with: NetworkVolumeConnectorObserving.self)
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in self?.handleInterruption() }
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self else { return }
            self.lock.withLock { if self.connection === connection { self.connection = nil } }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func proxy(of connection: NSXPCConnection) -> NetworkVolumeConnecting? {
        connection.remoteObjectProxyWithErrorHandler { error in
            Self.log.error("browsing request did not reach the service: \(String(describing: error), privacy: .public)")
        } as? NetworkVolumeConnecting
    }

    /// サービスが落ちた(同じ接続のまま、次の要求で立ち上がり直す)。一覧を空にし、探している途中なら探し直す。
    private func handleInterruption() {
        let (handler, connection) = lock.withLock { (onChange, self.connection) }
        guard let handler else { return }
        handler([])
        if let connection { proxy(of: connection)?.startBrowsing() }
    }

    /// 閉包を 1 度だけ呼ぶ。
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: (@Sendable (NetworkMountResult) -> Void)?

        init(_ completion: @escaping @Sendable (NetworkMountResult) -> Void) {
            self.completion = completion
        }

        func call(_ result: NetworkMountResult) {
            let completion = lock.withLock {
                defer { self.completion = nil }
                return self.completion
            }
            completion?(result)
        }
    }
}
