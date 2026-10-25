import Foundation
import NetFS
import Network
import dnssd
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
/// - **ローカルネットワークの許可が無い**ことを一覧と一緒に知らせる(2026-10-25 実測: 断られていると、探し始めた直後に
///   `NWBrowser` が `.waiting(.dns(-65570 PolicyDenied))` になる。返事を待っている間は何も来ない)。許可されたかどうかは
///   「探し始めてから `allowedAfter` 秒、断られなかった」で決める(サーバが 1 台も無いと結果の知らせが来ないため)。
/// - 探し始めた直後には知らせない(以前は空の一覧を送っていた): アプリは前回の一覧を出したまま待つので、ツリーを作り直すたびに
///   「ネットワーク」が消えて出直さない(2026-10-25 のレビュー)。
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
    /// ローカルネットワークの許可が無いと分かっている。
    private var isDenied = false
    /// 探し始めた回の番号(前の回の「許可された」の判定を捨てる)。
    private var browsingGeneration = 0
    /// 探し始めてから断られずにこれだけ経てば、許可されているとみなす(断られているなら数十ミリ秒で来る。実測)。
    private static let allowedAfter: TimeInterval = 2

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
            // 呼ばれるのは `queue` の上(`start(queue:)`)。どのブラウザの知らせかを確かめる(止めて作り直した後に、前のものの
            // 知らせが届いても今のものを止めない ―― 2026-10-25 のレビュー)。
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let self, let browser, browser === self.browser else { return }
                switch state {
                case .failed(let error):
                    Self.log.error("browsing failed: \(String(describing: error), privacy: .public)")
                    self.restartAfterFailure(of: browser)
                case .waiting(let error):
                    // ローカルネットワークの許可が無いとき(断られた)は PolicyDenied。返事を待っている間は何も来ない。
                    Self.log.info("browsing is waiting: \(String(describing: error), privacy: .public)")
                    if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                        self.setDenied(true)
                    }
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                guard let self, let browser, browser === self.browser else { return }
                self.apply(results)
            }
            self.browser = browser
            browsingGeneration += 1
            let generation = browsingGeneration
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.allowedAfter) { [weak self] in
                guard let self, self.browsingGeneration == generation, self.browser != nil,
                      self.browser?.state == .ready
                else { return }
                // 断られずに時間が経った(サーバが 1 台も無ければ結果の知らせも来ないので、ここでいまの一覧を送る)。
                self.isDenied = false
                self.notify()
            }
        }
    }

    func stopBrowsing() {
        queue.async { [self] in
            wantsBrowsing = false
            browsingGeneration += 1
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
        // 結果が来た = 探せている(許可されている)。
        guard shown != names || isDenied else { return }
        names = shown
        isDenied = false
        notify()
    }

    /// 断られた・断られなくなった(`queue` の上)。断られている間は一覧を空にする(結果は来ない)。
    private func setDenied(_ denied: Bool) {
        guard denied != isDenied else { return }
        isDenied = denied
        if denied { names = [] }
        notify()
    }

    /// いまの一覧と許可の有無をアプリへ知らせる(`queue` の上)。
    private func notify() {
        let data = NetworkVolumeConnectorPolicy.encodeNames(names)
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? NetworkVolumeConnectorObserving)?
            .serversDidChange(data, isLocalNetworkDenied: isDenied)
    }

    /// 探すのが失敗で止まった(ネットワークが替わった など)。少し待って探し直す(やめていれば何もしない)。
    /// `failed` が今のブラウザでなければ何もしない(呼ぶのは `queue` の上)。
    private func restartAfterFailure(of failed: NWBrowser) {
        guard failed === browser else { return }
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
