import Foundation
import NetFS
import Network
import os

/// XPC の口を受ける(1 つの接続に 1 つのサービスの物)。
nonisolated final class NetworkVolumeConnectorListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = NetworkVolumeConnectorService(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: NetworkVolumeConnecting.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: NetworkVolumeConnectorObserving.self)
        // 接続が切れたら(アプリが終わった・落ちた)探すのをやめる。頼んだマウントは NetAuthSysAgent が続ける(止める口は無い)。
        connection.invalidationHandler = { service.stopBrowsing() }
        connection.resume()
        return true
    }
}

/// `_smb._tcp` のサーバを探し、頼まれたサーバのマウントを NetFS に頼む(NetworkVolumeConnectorWire.swift の冒頭のコメント)。
///
/// - 探すのは `NWBrowser`(Bonjour)。**この Mac 自身**(ループバックのインターフェースで見えるもの。自分のファイル共有を入れていると
///   出る)は外す ―― Finder のサイドバーにも出ない。
/// - マウントを頼めるのは**いま見つかっている名前だけ**(決まった形の要求しか出さない、の約束。任意の宛先へ繋がせない)。
/// - 返事はどの要求にも 1 度だけ。NetFS は要求を取り消したときだけ完了の閉包を呼ばない(NetFS.h)が、このサービスは取り消さない。
///
/// `@unchecked Sendable`: 変わる状態は `queue` の上でだけ読み書きする。
nonisolated final class NetworkVolumeConnectorService: NSObject, NetworkVolumeConnecting, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.qooProject.qooViewer.NetworkVolumeConnector", category: "connector")

    private let queue = DispatchQueue(label: "com.qooProject.qooViewer.NetworkVolumeConnector")
    /// 接続はサービス(exportedObject)を強く持つので、こちらからは弱く持つ。
    private weak var connection: NSXPCConnection?
    private var browser: NWBrowser?
    /// いま見つかっているサーバの名前(`NetworkVolumeConnectorPolicy.displayedNames` の後)。
    private var names: [String] = []
    /// アプリが探すように頼んでいるか(失敗の後に探し直すかを決める)。
    private var wantsBrowsing = false

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    // MARK: - NetworkVolumeConnecting

    func startBrowsing() {
        queue.async { [self] in
            wantsBrowsing = true
            guard browser == nil else { return notify() }
            let browser = NWBrowser(
                for: .bonjour(type: NetworkVolumeConnectorPolicy.serviceType, domain: NetworkVolumeConnectorPolicy.domain),
                using: NWParameters()
            )
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error):
                    Self.log.error("browsing failed: \(String(describing: error), privacy: .public)")
                    self?.queue.async { self?.restartAfterFailure() }
                case .waiting(let error):
                    // ローカルネットワークの許可が無い(まだ答えていない・断った)ときもここ(PolicyDenied)。結果は来ない。
                    Self.log.info("browsing is waiting: \(String(describing: error), privacy: .public)")
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.apply(results)
            }
            self.browser = browser
            browser.start(queue: queue)
            notify()
        }
    }

    func stopBrowsing() {
        queue.async { [self] in
            wantsBrowsing = false
            browser?.cancel()
            browser = nil
            names = []
        }
    }

    func mount(serverName: String, withReply reply: @escaping @Sendable (Int32, Data?) -> Void) {
        queue.async { [self] in
            guard names.contains(serverName), let url = NetworkVolumeConnectorPolicy.mountURL(forServerName: serverName) else {
                // 名前は出さない(利用者の機器の名前。理由の種類だけ)。
                Self.log.error("refused a mount request for a server that is not being shown")
                return reply(NetworkVolumeConnectorPolicy.refusedStatus, nil)
            }
            // 認証と共有の選択のダイアログを許す(出すのは NetAuthAgent)。マウント先は NetFS に選ばせる(/Volumes の下。
            // App Sandbox の呼び出し元にはそれしか許されない ―― NetAuthSysAgent のログ「no path was supplied; allowing NetFS to
            // mount under /Volumes」)。
            let openOptions = NSMutableDictionary()
            openOptions[kNAUIOptionKey as String] = kNAUIOptionAllowUI as String
            var requestID: AsyncRequestID?
            let started = NetFSMountURLAsync(
                url as CFURL, nil, nil, nil, openOptions as CFMutableDictionary, nil, &requestID, queue
            ) { status, _, mountPoints in
                let paths = (mountPoints as? [String]) ?? []
                reply(status, paths.isEmpty ? nil : NetworkVolumeConnectorPolicy.encodeNames(paths))
            }
            if started != 0 { reply(started, nil) }
        }
    }

    // MARK: - 一覧

    /// 呼ぶのは `queue` の上(`NWBrowser` をこのキューで始めている)。
    private func apply(_ results: Set<NWBrowser.Result>) {
        let found: [String] = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint,
                  !result.interfaces.contains(where: { $0.type == .loopback })
            else { return nil }
            return name
        }
        let shown = NetworkVolumeConnectorPolicy.displayedNames(found)
        guard shown != names else { return }
        names = shown
        notify()
    }

    /// いまの一覧をアプリへ知らせる(`queue` の上)。
    private func notify() {
        let data = NetworkVolumeConnectorPolicy.encodeNames(names)
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? NetworkVolumeConnectorObserving)?.serversDidChange(data)
    }

    /// 探すのが失敗で止まった(ネットワークが替わった など)。少し待って探し直す(やめていれば何もしない)。
    private func restartAfterFailure() {
        guard let failed = browser else { return }
        failed.cancel()
        browser = nil
        names = []
        notify()
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.wantsBrowsing, self.browser == nil, self.connection != nil else { return }
            self.startBrowsing()
        }
    }
}
