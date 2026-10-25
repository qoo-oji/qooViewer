import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザのツリーの「ネットワーク」(2026-10-25)。XPC サービス NetworkVolumeConnector とアプリが同じ判定をする決まり
/// (NetworkVolumeConnectorPolicy)、NetFS の返事の読み方、探すのはツリーが出ている間だけという `NetworkServerDirectory` の約束を固定する。
/// 実物のサーバ探しとマウントは実機で確かめる(docs/10「ネットワークのサーバとボリュームの接続」)。
struct NetworkVolumeConnectorPolicyTests {
    @Test("マウントの URL は Finder のサイドバーと同じ Bonjour の名前の形。英数字と - _ 以外は百分率符号化する")
    func mountURLUsesTheBonjourName() {
        #expect(NetworkVolumeConnectorPolicy.mountURL(forServerName: "NAS-01")?.absoluteString == "smb://NAS-01._smb._tcp.local")
        #expect(
            NetworkVolumeConnectorPolicy.mountURL(forServerName: "Office NAS")?.absoluteString
                == "smb://Office%20NAS._smb._tcp.local"
        )
        // URL の区切りとして読ませない(利用者・ポート・パスにならない)。
        let tricky = NetworkVolumeConnectorPolicy.mountURL(forServerName: "a@b:1/c")
        #expect(tricky?.absoluteString == "smb://a%40b%3A1%2Fc._smb._tcp.local")
        #expect(tricky?.user == nil)
        #expect(tricky?.port == nil)
        #expect(tricky?.path == "")
    }

    @Test("空・長すぎる(63 バイト超)・制御文字を含む名前は断る")
    func refusesUnacceptableNames() {
        #expect(NetworkVolumeConnectorPolicy.mountURL(forServerName: "") == nil)
        #expect(NetworkVolumeConnectorPolicy.mountURL(forServerName: String(repeating: "a", count: 64)) == nil)
        #expect(NetworkVolumeConnectorPolicy.mountURL(forServerName: String(repeating: "a", count: 63)) != nil)
        // 日本語は 1 文字 3 バイト: 21 文字 = 63 バイトは通り、22 文字は断る。
        #expect(NetworkVolumeConnectorPolicy.isAcceptableServerName(String(repeating: "共", count: 21)))
        #expect(!NetworkVolumeConnectorPolicy.isAcceptableServerName(String(repeating: "共", count: 22)))
        #expect(!NetworkVolumeConnectorPolicy.isAcceptableServerName("NAS\n"))
    }

    @Test("出す一覧は重なりを除き、決まりに合わない名前を外し、名前順(数字は数として)")
    func displayedNames() {
        let names = ["nas10", "Nas2", "", "nas10", "Alpha", "nas9"]
        #expect(NetworkVolumeConnectorPolicy.displayedNames(names) == ["Alpha", "Nas2", "nas9", "nas10"])
    }

    @Test("名前の一覧は JSON で往復する。壊れた値は空")
    func namesRoundTrip() {
        let names = ["Office NAS", "共有"]
        #expect(NetworkVolumeConnectorPolicy.decodeNames(NetworkVolumeConnectorPolicy.encodeNames(names)) == names)
        #expect(NetworkVolumeConnectorPolicy.decodeNames(Data("{".utf8)).isEmpty)
        #expect(NetworkVolumeConnectorPolicy.decodeNames(nil).isEmpty)
    }

    @Test("NetFS の返事: 0 はマウント先、-128 と ECANCELED は取り消し、ほかは失敗")
    func readsNetFSStatus() {
        let points = NetworkVolumeConnectorPolicy.encodeNames(["/Volumes/share"])
        #expect(NetworkMountResult(status: 0, mountPoints: points) == .mounted(["/Volumes/share"]))
        #expect(NetworkMountResult(status: -128, mountPoints: nil) == .cancelled)
        #expect(NetworkMountResult(status: ECANCELED, mountPoints: nil) == .cancelled)
        #expect(NetworkMountResult(status: EPERM, mountPoints: nil) == .failed(EPERM))
        #expect(NetworkMountResult(status: -6602, mountPoints: nil) == .failed(-6602))
    }
}

/// サービスの代わり(呼ばれた回数を数え、知らせとマウントの返事を試験から出す)。
private final class FakeNetworkVolumeConnector: NetworkVolumeConnectorTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private var onChange: (@Sendable ([String]) -> Void)?
    private var pendingMounts: [(String, @Sendable (NetworkMountResult) -> Void)] = []

    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var mountRequests: [String] { lock.withLock { pendingMounts.map(\.0) } }

    func startBrowsing(onChange: @escaping @Sendable ([String]) -> Void) {
        lock.withLock {
            _startCount += 1
            self.onChange = onChange
        }
    }

    func stopBrowsing() {
        lock.withLock { _stopCount += 1 }
    }

    func mount(serverName: String, completion: @escaping @Sendable (NetworkMountResult) -> Void) {
        lock.withLock { pendingMounts.append((serverName, completion)) }
    }

    func send(_ names: [String]) {
        let handler = lock.withLock { onChange }
        handler?(names)
    }

    func finishMount(with result: NetworkMountResult) {
        let completion = lock.withLock { pendingMounts.isEmpty ? nil : pendingMounts.removeFirst().1 }
        completion?(result)
    }
}

@MainActor
struct NetworkServerDirectoryTests {
    /// メインの次の周回まで待つ(知らせは `Task { @MainActor }` で一覧に入る)。
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test("探すのは 1 つ目のツリーが出たときから最後のツリーが消えるまで。消えたら一覧は空")
    func browsesOnlyWhileATreeIsShown() async {
        let fake = FakeNetworkVolumeConnector()
        let directory = NetworkServerDirectory(transport: fake)
        let first = UUID(), second = UUID()
        directory.activate(client: first)
        directory.activate(client: second)
        #expect(fake.startCount == 1)
        fake.send(["NAS-B", "NAS-A"])
        await settle()
        #expect(directory.servers == ["NAS-A", "NAS-B"])
        directory.deactivate(client: first)
        #expect(fake.stopCount == 0)
        #expect(directory.servers == ["NAS-A", "NAS-B"])
        directory.deactivate(client: second)
        #expect(fake.stopCount == 1)
        #expect(directory.servers.isEmpty)
        // やめた後に届いた前の回の知らせは捨てる。
        fake.send(["NAS-C"])
        await settle()
        #expect(directory.servers.isEmpty)
    }

    @Test("同じサーバへ繋いでいる最中の 2 回目は重ねない(nil)。返事が来たら繋ぎ直せる")
    func doesNotOverlapConnects() async {
        let fake = FakeNetworkVolumeConnector()
        let directory = NetworkServerDirectory(transport: fake)
        let firstTask = Task { await directory.connect(serverName: "NAS-A") }
        await settle()
        #expect(directory.isConnecting(to: "NAS-A"))
        #expect(await directory.connect(serverName: "NAS-A") == nil)
        #expect(fake.mountRequests == ["NAS-A"])
        fake.finishMount(with: .mounted(["/Volumes/share"]))
        #expect(await firstTask.value == .mounted(["/Volumes/share"]))
        #expect(!directory.isConnecting(to: "NAS-A"))
    }

    @Test("道が無ければ(テストの中で走る実物のアプリ)探さず、繋ぐ要求は unavailable")
    func withoutTransport() async {
        let directory = NetworkServerDirectory(transport: nil)
        directory.activate(client: UUID())
        #expect(!directory.isBrowsing)
        #expect(await directory.connect(serverName: "NAS-A") == .unavailable)
    }
}

/// アンマウントのボタンを付けるボリューム(VolumeUnmounting)。マウント表は作り物なので、ネットワーク越しの行と、付けない行だけを確かめる
/// (ローカルの外付けかどうかはボリュームへの問い合わせで決まる ―― 実機で確かめる)。
struct VolumeUnmountingTests {
    @Test("起動ボリュームと /Volumes の外には付けず、ネットワーク越しのボリュームには問い合わせずに付ける")
    func unmountableMountPoints() {
        let table = MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "/dev/disk3s1s1", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/share", mountedFrom: "//user@nas._smb._tcp.local/share", fileSystemType: "smbfs",
                  isLocal: false, isHiddenFromBrowsing: false),
            .init(mountPoint: "/System/Volumes/Data", mountedFrom: "/dev/disk3s5", fileSystemType: "apfs", isLocal: true,
                  isHiddenFromBrowsing: true),
        ])
        let volumes = ["/", "/Volumes/share", "/System/Volumes/Data", "/Volumes/not-mounted"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
        #expect(VolumeUnmounting.unmountableMountPoints(of: volumes, mountTable: table) == ["/Volumes/share"])
    }
}
