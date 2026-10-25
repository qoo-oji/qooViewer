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
    private var onChange: (@Sendable (NetworkBrowseSnapshot) -> Void)?
    private var pendingMounts: [(String, @Sendable (NetworkMountResult) -> Void)] = []

    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var mountRequests: [String] { lock.withLock { pendingMounts.map(\.0) } }

    func startBrowsing(onChange: @escaping @Sendable (NetworkBrowseSnapshot) -> Void) {
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

    func send(_ names: [String], denied: Bool = false) {
        let handler = lock.withLock { onChange }
        handler?(NetworkBrowseSnapshot(names: names, isLocalNetworkDenied: denied))
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
        // 待ち: 周回(メインの順番で決まる。時間では決まらない)
        for _ in 0..<5 { await Task.yield() }
    }

    @Test("探すのは 1 つ目のツリーが出たときから最後のツリーが消えるまで。消えても前回の一覧は残し、後から届いた前の回の知らせは捨てる")
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
        // 前回の一覧として残す(ツリーを作り直すたびに「ネットワーク」が出直さないように)。
        #expect(directory.servers == ["NAS-A", "NAS-B"])
        // やめた後に届いた前の回の知らせは捨てる。
        fake.send(["NAS-C"])
        await settle()
        #expect(directory.servers == ["NAS-A", "NAS-B"])
        // 探し直した結果が来たら入れ替える。
        directory.activate(client: first)
        #expect(fake.startCount == 2)
        fake.send(["NAS-C"])
        await settle()
        #expect(directory.servers == ["NAS-C"])
    }

    @Test("断られていれば一覧は空で印が立つ。前面に戻ったら探し直し(間隔の下限あり)、許可されたら一覧が戻る")
    func refreshesOnActivation() async {
        let fake = FakeNetworkVolumeConnector()
        let directory = NetworkServerDirectory(transport: fake)
        let start = ContinuousClock.now
        directory.activate(client: UUID())
        fake.send([], denied: true)
        await settle()
        #expect(directory.isLocalNetworkDenied)
        #expect(directory.servers.isEmpty)
        directory.refreshOnActivation(now: start + .seconds(10))
        #expect(fake.stopCount == 1)
        #expect(fake.startCount == 2)
        fake.send(["NAS-A"])
        await settle()
        #expect(!directory.isLocalNetworkDenied)
        #expect(directory.servers == ["NAS-A"])
        // 間隔の下限より前の前面への出入りでは探し直さない。
        directory.refreshOnActivation(now: start + .seconds(11))
        #expect(fake.startCount == 2)
        // 許可されていても探し直す(使っている途中でオフにされても、走っている探索には届かないため)。
        directory.refreshOnActivation(now: start + .seconds(20))
        #expect(fake.startCount == 3)
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

/// すでにマウントしてある共有の場所(NetworkMountLookup。共有の選択で EEXIST が返ったとき)。
struct NetworkMountLookupTests {
    @Test("マウント元のホストが Bonjour の名前・.local・名前そのもののどれかなら当たる。大文字小文字と百分率符号化は畳む")
    func findsMountedShares() {
        let table = MountTable(entries: [
            .init(mountPoint: "/Volumes/share", mountedFrom: "//user@NAS-01._smb._tcp.local/share", fileSystemType: "smbfs",
                  isLocal: false, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/other", mountedFrom: "//user@other._smb._tcp.local/other", fileSystemType: "smbfs",
                  isLocal: false, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/office", mountedFrom: "//Office%20NAS._smb._tcp.local/docs", fileSystemType: "smbfs",
                  isLocal: false, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/plain", mountedFrom: "//guest@nas-01.local:445/plain", fileSystemType: "smbfs",
                  isLocal: false, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/nfs", mountedFrom: "//NAS-01._smb._tcp.local/nfs", fileSystemType: "nfs",
                  isLocal: false, isHiddenFromBrowsing: false),
        ])
        #expect(NetworkMountLookup.mountPoints(ofServer: "NAS-01", in: table) == ["/Volumes/share", "/Volumes/plain"])
        #expect(NetworkMountLookup.mountPoints(ofServer: "Office NAS", in: table) == ["/Volumes/office"])
        #expect(NetworkMountLookup.mountPoints(ofServer: "nobody", in: table).isEmpty)
        #expect(NetworkMountLookup.host(ofMountedFrom: "/dev/disk4s1") == nil)
    }
}

/// アンマウントの前に、ネットワーク上の書庫の読み込み層が猶予の間だけ持つ記述子を手放す(StagedFileRegistry.releaseHolds)。
struct StagedFileRegistryReleaseTests {
    @Test("そのボリュームの上の、読み手のいない読み込み層だけを手放す")
    func releasesHoldsOnTheVolume() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "staged-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "book.zip")
        try Data(repeating: 7, count: 4096).write(to: file)
        let registry = StagedFileRegistry(gracePeriod: 60, maxHeld: 4)
        _ = try registry.source(for: file)
        #expect(registry.liveCount == 1)
        // 別のボリューム(場所)を手放しても残る。
        registry.releaseHolds(onVolume: "/Volumes/somewhere-else")
        #expect(registry.liveCount == 1)
        registry.releaseHolds(onVolume: folder.path)
        #expect(registry.liveCount == 0)
    }
}
