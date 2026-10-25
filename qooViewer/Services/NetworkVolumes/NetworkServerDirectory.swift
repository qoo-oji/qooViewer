import AppKit
import Combine
import Foundation

/// LAN で見つかっている SMB のサーバの一覧と、その共有への接続(ファイルブラウザのツリーの「ネットワーク」。2026-10-25)。
/// アプリで 1 つ(`AppStores.networkServers`)。
///
/// ■ 探すのはツリーが画面に出ている間だけ
/// ツリーが出るたびに `activate(client:)`、消えるたびに `deactivate(client:)` を呼ぶ。1 つでも出ていれば探し、すべて消えたら
/// やめる(画面に出ていない間に何かを写し続けない ―― 2026-09-25 の効率の監査と同じ決まり)。
/// **やめても一覧は空にせず、前回の一覧として残す**(2026-10-25 のレビュー): 本を開いてホームへ戻るたびにツリーは作り直されるので、
/// 空から始めると、ツリーが開き具合と位置を戻した後で「ネットワーク」が差し込まれ、ホーム・よく使う項目が押し下がった。
/// 探し直した結果が来たら(断られた・断られずに少し経った、を含む)入れ替える。
///
/// ■ ローカルネットワークの許可
/// システム設定で断られていると、サービスが `isLocalNetworkDenied` を知らせてくる(一覧は空)。ツリーはそのとき「許可されていない」
/// 行を出し、システム設定への道を案内する。**探している間は、アプリが前面に戻るたびに探し直す**(`refreshOnActivation`):
/// システム設定で許可を戻しても、走っている探索は自分では立ち直らず、使っている途中でオフにされても何も届かない(2026-10-25 実測。
/// 探し直せばすぐに分かる)。以前は断られているときだけ探し直していたので、オフにしても古い一覧のまま変わらなかった(利用者の報告)。
/// 探し直しても一覧は空に戻さない(サービスは結果・断られた・断られずに少し経った、のどれかが来るまで知らせない)ので、変わらなければ
/// 画面も動かない。前面に出入りを繰り返しても `refreshInterval` に 1 回まで。
///
/// ■ 繋ぐ
/// `connect(serverName:)` は NetFS にマウントを頼む(認証と共有の選択のダイアログは macOS が出す)。同じサーバへの要求が
/// 走っている間は重ねない(`isConnecting`)。結果の読み方は呼び出し側(ツリー)。
///
/// 道(`transport`)が nil のとき(テストの中で走る実物のアプリ ―― `AppStores.Dependencies.live()`)は何も探さず、繋ぐ要求は
/// `.unavailable` で返る。
@MainActor
final class NetworkServerDirectory: ObservableObject {
    /// 見つかっているサーバの名前(表示の順)。探していない間は前回の一覧。
    @Published private(set) var servers: [String] = []
    /// ローカルネットワークの許可が無い(システム設定で断られている)。探していない間は前回の値。
    @Published private(set) var isLocalNetworkDenied = false
    /// 繋ぎに行っている最中のサーバ。
    @Published private(set) var connectingServers: Set<String> = []

    private let transport: (any NetworkVolumeConnectorTransport)?
    private var clients: Set<UUID> = []
    /// 探し始めた回の番号(やめた後に届いた前の回の知らせを捨てる)。
    private var browsingGeneration = 0
    private var activationObserver: NSObjectProtocol?

    init(transport: (any NetworkVolumeConnectorTransport)?) {
        self.transport = transport
        guard transport != nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOnActivation() }
        }
    }

    var isBrowsing: Bool { !clients.isEmpty && transport != nil }

    func isConnecting(to server: String) -> Bool { connectingServers.contains(server) }

    func activate(client: UUID) {
        let wasEmpty = clients.isEmpty
        clients.insert(client)
        if wasEmpty { startBrowsing() }
    }

    func deactivate(client: UUID) {
        guard clients.remove(client) != nil, clients.isEmpty else { return }
        browsingGeneration += 1
        transport?.stopBrowsing()
    }

    /// 探していれば探し直す(アプリが前面に戻ったとき。型コメント「ローカルネットワークの許可」)。前の探し始めから
    /// `refreshInterval` 経っていなければ何もしない。
    func refreshOnActivation(now: ContinuousClock.Instant = .now) {
        guard isBrowsing, now - lastStart >= Self.refreshInterval else { return }
        transport?.stopBrowsing()
        startBrowsing(now: now)
    }

    /// 前面に戻ったときの探し直しの間隔の下限。
    static let refreshInterval: Duration = .seconds(3)
    private var lastStart = ContinuousClock.now - .seconds(60)

    private func startBrowsing(now: ContinuousClock.Instant = .now) {
        guard let transport else { return }
        lastStart = now
        browsingGeneration += 1
        let generation = browsingGeneration
        transport.startBrowsing { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.browsingGeneration == generation, !self.clients.isEmpty else { return }
                let shown = NetworkVolumeConnectorPolicy.displayedNames(snapshot.names)
                if shown != self.servers { self.servers = shown }
                if snapshot.isLocalNetworkDenied != self.isLocalNetworkDenied {
                    self.isLocalNetworkDenied = snapshot.isLocalNetworkDenied
                }
            }
        }
    }

    /// サーバ `server` の共有をマウントしてもらう。同じサーバへ繋いでいる最中なら nil(重ねない)。
    func connect(serverName server: String) async -> NetworkMountResult? {
        guard !connectingServers.contains(server) else { return nil }
        guard let transport else { return .unavailable }
        connectingServers.insert(server)
        defer { connectingServers.remove(server) }
        return await withCheckedContinuation { continuation in
            transport.mount(serverName: server) { result in continuation.resume(returning: result) }
        }
    }
}
