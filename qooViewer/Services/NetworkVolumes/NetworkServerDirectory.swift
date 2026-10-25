import Combine
import Foundation

/// LAN で見つかっている SMB のサーバの一覧と、その共有への接続(ファイルブラウザのツリーの「ネットワーク」。2026-10-25)。
/// アプリで 1 つ(`AppStores.networkServers`)。
///
/// ■ 探すのはツリーが画面に出ている間だけ
/// ツリーが出るたびに `activate(client:)`、消えるたびに `deactivate(client:)` を呼ぶ。1 つでも出ていれば探し、すべて消えたら
/// やめて一覧を空にする(画面に出ていない間に何かを写し続けない ―― 2026-09-25 の効率の監査と同じ決まり)。
///
/// ■ 繋ぐ
/// `connect(serverName:)` は NetFS にマウントを頼む(認証と共有の選択のダイアログは macOS が出す)。同じサーバへの要求が
/// 走っている間は重ねない(`isConnecting`)。結果の読み方は呼び出し側(ツリー)。
///
/// 道(`transport`)が nil のとき(テストの中で走る実物のアプリ ―― `AppStores.Dependencies.live()`)は何も探さず、繋ぐ要求は
/// `.unavailable` で返る。
@MainActor
final class NetworkServerDirectory: ObservableObject {
    /// 見つかっているサーバの名前(表示の順)。探していない間は空。
    @Published private(set) var servers: [String] = []
    /// 繋ぎに行っている最中のサーバ。
    @Published private(set) var connectingServers: Set<String> = []

    private let transport: (any NetworkVolumeConnectorTransport)?
    private var clients: Set<UUID> = []
    /// 探し始めた回の番号(やめた後に届いた前の回の知らせを捨てる)。
    private var browsingGeneration = 0

    init(transport: (any NetworkVolumeConnectorTransport)?) {
        self.transport = transport
    }

    var isBrowsing: Bool { !clients.isEmpty && transport != nil }

    func isConnecting(to server: String) -> Bool { connectingServers.contains(server) }

    func activate(client: UUID) {
        let wasEmpty = clients.isEmpty
        clients.insert(client)
        guard wasEmpty, let transport else { return }
        browsingGeneration += 1
        let generation = browsingGeneration
        transport.startBrowsing { [weak self] names in
            Task { @MainActor [weak self] in
                guard let self, self.browsingGeneration == generation, !self.clients.isEmpty else { return }
                let shown = NetworkVolumeConnectorPolicy.displayedNames(names)
                if shown != self.servers { self.servers = shown }
            }
        }
    }

    func deactivate(client: UUID) {
        guard clients.remove(client) != nil, clients.isEmpty else { return }
        browsingGeneration += 1
        transport?.stopBrowsing()
        if !servers.isEmpty { servers = [] }
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
