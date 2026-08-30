import Foundation
import Combine
import Darwin

/// カーネルが数えている、このプロセスの累積リソース量の**ある瞬間の読み値**。
///
/// `proc_pid_rusage(getpid(), RUSAGE_INFO_V4)`の1回の呼び出しで全部そろう(数µs)。
/// サンドボックス内でも自分のpidに対しては許可されている
/// (`/System/Library/Sandbox/Profiles/appsandbox-common.sb`の
/// `(allow process-info-rusage (target self))`で確認済み)。
///
/// - `cpuTime`: ユーザー+カーネルのCPU時間。`ri_user_time`/`ri_system_time`はmach絶対時間の
///   単位(Apple Siliconでは1/24MHz)なので、`mach_timebase_info`でナノ秒へ直してある。
/// - `physicalFootprint`: アクティビティモニタの「メモリ」列とまったく同じ値(phys_footprint
///   台帳。常駐・圧縮・スワップ済みの匿名メモリをすべて含む)。
/// - `lifetimeMaxFootprint`: 起動後のfootprintの最大値。カーネルが常に数えているので、
///   計測のON/OFFに関わらず正確。
/// - `diskBytesRead`/`diskBytesWritten`: **物理I/O**の累積バイト数。ページキャッシュにヒット
///   した読み込みは乗らない(実測: 同じ18MBを2回読むと2回目は0)。アクティビティモニタの
///   「ディスク」タブと同じ意味。ネットワークボリューム上のファイルもここには乗らない。
///
/// nonisolated: 値型で、どのスレッドからでも取れる。
nonisolated struct ProcessResourceReading: Equatable, Sendable {
    var timestamp: Date
    var cpuTime: TimeInterval
    var physicalFootprint: Int
    var lifetimeMaxFootprint: Int
    var diskBytesRead: Int
    var diskBytesWritten: Int

    /// mach絶対時間 → 秒。起動中に変わらないので1度だけ引く。
    private static let secondsPerMachTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// いまの値を読む。失敗(通常は起きない)したらnil。
    static func current() -> ProcessResourceReading? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        guard status == 0 else { return nil }
        return ProcessResourceReading(
            timestamp: Date(),
            cpuTime: Double(info.ri_user_time &+ info.ri_system_time) * secondsPerMachTick,
            physicalFootprint: Int(clamping: info.ri_phys_footprint),
            lifetimeMaxFootprint: Int(clamping: info.ri_lifetime_max_phys_footprint),
            diskBytesRead: Int(clamping: info.ri_diskio_bytesread),
            diskBytesWritten: Int(clamping: info.ri_diskio_byteswritten)
        )
    }
}

/// グラフの1点。2つの読み値の差分から作る「その区間の速度」と、区間末の絶対値。
nonisolated struct ResourceSample: Equatable, Sendable {
    var timestamp: Date
    /// CPU使用率(%)。複数コアを使えば100を超える(アクティビティモニタと同じ数え方)。
    var cpuPercent: Double
    var physicalFootprint: Int
    /// 区間中のディスク読み込み速度(バイト/秒)。
    var diskReadBytesPerSecond: Double
    var diskWriteBytesPerSecond: Double

    init(from previous: ProcessResourceReading, to current: ProcessResourceReading) {
        let elapsed = max(current.timestamp.timeIntervalSince(previous.timestamp), 0.001)
        timestamp = current.timestamp
        cpuPercent = max(current.cpuTime - previous.cpuTime, 0) / elapsed * 100
        physicalFootprint = current.physicalFootprint
        diskReadBytesPerSecond = Double(max(current.diskBytesRead - previous.diskBytesRead, 0)) / elapsed
        diskWriteBytesPerSecond = Double(max(current.diskBytesWritten - previous.diskBytesWritten, 0)) / elapsed
    }

    init(timestamp: Date, cpuPercent: Double, physicalFootprint: Int, diskReadBytesPerSecond: Double, diskWriteBytesPerSecond: Double) {
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.physicalFootprint = physicalFootprint
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
    }
}

/// グラフ用の履歴。1秒刻みの直近2分と、10秒平均の直近1時間の2段で持つ。
///
/// 2段にするのは、サイドパネルの幅(220〜480pt)では1時間ぶんを1秒刻みで描いても1ピクセルに
/// 何十点も重なって意味が無く、かといって10秒平均だけでは「ページを送った瞬間のスパイク」が
/// 均されて見えなくなるため。メモリは (120+360)点 × 5値 × 8バイト ≒ 20KB。
nonisolated struct ResourceHistory: Equatable, Sendable {
    /// 直近2分、1秒刻み。
    private(set) var fine: [ResourceSample] = []
    /// 直近1時間、10秒平均。
    private(set) var coarse: [ResourceSample] = []

    static let fineCapacity = 120
    static let coarseCapacity = 360
    static let coarseBucketSize = 10

    /// `coarse`の次の1点を作るために溜めている、まだ10個に満たないサンプル。
    private var pendingCoarse: [ResourceSample] = []

    mutating func append(_ sample: ResourceSample) {
        fine.append(sample)
        if fine.count > Self.fineCapacity {
            fine.removeFirst(fine.count - Self.fineCapacity)
        }
        pendingCoarse.append(sample)
        if pendingCoarse.count >= Self.coarseBucketSize {
            coarse.append(Self.average(of: pendingCoarse))
            pendingCoarse.removeAll(keepingCapacity: true)
            if coarse.count > Self.coarseCapacity {
                coarse.removeFirst(coarse.count - Self.coarseCapacity)
            }
        }
    }

    /// 速度は平均、footprintは区間末の値(量なので平均する意味が無い)、時刻は区間末。
    private static func average(of samples: [ResourceSample]) -> ResourceSample {
        let n = Double(samples.count)
        return ResourceSample(
            timestamp: samples.last!.timestamp,
            cpuPercent: samples.reduce(0) { $0 + $1.cpuPercent } / n,
            physicalFootprint: samples.last!.physicalFootprint,
            diskReadBytesPerSecond: samples.reduce(0) { $0 + $1.diskReadBytesPerSecond } / n,
            diskWriteBytesPerSecond: samples.reduce(0) { $0 + $1.diskWriteBytesPerSecond } / n
        )
    }
}

/// サイドパネルのリソースモニタの計測役。**アプリ全体で1つ**(QooViewerAppが生成して
/// environmentObjectで配る)。CPU・メモリ・ディスクI/Oはプロセスの値なので、ウインドウごとに
/// 持つ意味が無い。どのウインドウでONにしても全ウインドウの表示が「計測中」になり、
/// どこからでもOFFにできる。
///
/// ■ ON/OFFはユーザーが決める(ユーザー要望)
/// 起動時は常にOFF(永続化しない)。ONの間は、サイドパネルが隠れていようが別のモードだろうが
/// 1秒ごとにサンプリングし続ける。OFFにした時点で履歴は捨てる。
/// 「常時計測」にしなかったのは、測っているつもりの無い状態で裏で動き続けるものを
/// 置かないため。逆に「表示中だけ計測」にしなかったのは、パネルを開いた瞬間にグラフが
/// 空で、直前に何が起きたかが見えないため。
///
/// OFFでも`latest`(現在値)は出せる。カーネルが数えている累積値と起動後のピークは、
/// 計測していなくても正確なので、「いま異常か」はOFFのままでも分かる。
///
/// ■ コスト
/// `proc_pid_rusage`は数µs、タイマーの起床は1回/秒。アクティビティモニタの表示で0.0%に
/// 留まる量で、計測そのものがグラフに現れることはない。
@MainActor
final class ProcessResourceSampler: ObservableObject {
    static let interval: TimeInterval = 1

    /// 計測中か。パネルのトグルの状態そのもの。
    @Published private(set) var isRecording = false
    /// 計測を始めた時刻(「計測中 HH:MM から」の表示用)。
    @Published private(set) var recordingStartedAt: Date?
    /// グラフの履歴。計測中だけ伸びる。
    @Published private(set) var history = ResourceHistory()
    /// 最新の読み値。計測中はタイマーが、OFF中はパネルが`refreshLatest()`で更新する。
    @Published private(set) var latest: ProcessResourceReading?
    /// 最新の区間の速度(計測中だけ。OFF中は前回の読み値が無いので出せない)。
    @Published private(set) var latestSample: ResourceSample?

    private var timer: Timer?
    private var previousReading: ProcessResourceReading?

    init() {
        latest = ProcessResourceReading.current()
    }

    func setRecording(_ enabled: Bool) {
        guard enabled != isRecording else { return }
        if enabled { start() } else { stop() }
    }

    /// OFF中にパネルが現在値だけを更新したいときに呼ぶ。計測中は何もしない(タイマーが担う)。
    func refreshLatest() {
        guard !isRecording else { return }
        latest = ProcessResourceReading.current()
    }

    private func start() {
        isRecording = true
        recordingStartedAt = Date()
        history = ResourceHistory()
        latestSample = nil
        previousReading = ProcessResourceReading.current()
        latest = previousReading
        // RunLoop.commonにするのは、メニューやスライダーのドラッグ中(トラッキングモード)に
        // サンプリングと(ウインドウ内の)グラフの更新が止まらないようにするため。
        //
        // かつてこの毎秒の@Publishedの発火は、QooViewerAppのbody(全Scene+.commands)を
        // 毎回再評価させ、**開いている最中のメニューバーのメニューを毎秒作り直させていた**
        // (表示メニューの描画崩れの一因として実測で確認)。現在はQooViewerAppがストアを
        // 直接観測しない構造(AppStores/MenuBarMenuRefresher参照)になったため、ここは
        // 何も気にせず毎秒発火してよい ―― メニューへの反映はMenuBarMenuRefresherが
        // メニューの閉じたあとへまとめて送り、ウインドウ内のグラフだけがそのまま毎秒動く。
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        isRecording = false
        recordingStartedAt = nil
        previousReading = nil
        latestSample = nil
        history = ResourceHistory()
    }

    private func tick() {
        guard let current = ProcessResourceReading.current() else { return }
        if let previous = previousReading {
            let sample = ResourceSample(from: previous, to: current)
            history.append(sample)
            latestSample = sample
        }
        previousReading = current
        latest = current
    }
}
