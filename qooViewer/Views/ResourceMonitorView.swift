import Combine
import SwiftUI
import SwiftData

/// リソースモニタ。このアプリ(プロセス)のCPU・メモリ・ディスクI/Oの推移と、メモリとディスクを**どの機能が**どれだけ
/// 使っているかの内訳、そして検出した異常を1列に並べる(ユーザー要望: v1.29で直した種類のリソースの過剰消費を、
/// ユーザー自身がひと目で把握できるようにする)。
///
/// ■ 置き場所(2026-10-11)
/// 本を開いている画面ではサイドパネルの「リソース」モード、ホームではインスペクタの「リソース」(HomeInspectorPane の
/// モードの切り替え)。以前はサイドパネルにしか無く、ホームではサイドパネルが出ない(ContentView.isSidePanelSuppressedForWelcome)
/// ので、ファイルブラウザ・ライブラリ・スマートライブラリを使っている最中には見られなかった(利用者の要望で、独立した
/// ウインドウではなくインスペクタの中で切り替える形にした)。
///
/// ■ 内訳は機能ごとに折り畳める(2026-10-11、利用者の要望)
/// メモリは MemoryUsageRegistry への届け出を機能(ビューア・補助ウインドウ・ホーム)ごとに、ディスクはコンテナの中のフォルダを
/// 機能(ビューア・ライブラリ・ファイルブラウザとスマートライブラリ・メタデータ・保存データ・一時ファイル)ごとにまとめる。
/// 折り畳んだまとまりはアプリで 1 つの値として覚える(`ResourceMonitorFolding`。サイドパネルとインスペクタで同じ)。
///
/// ■ 3つの更新周期
/// - グラフ: `ProcessResourceSampler`(アプリに1つ)が計測中だけ1秒ごとに伸ばす。ON/OFFは
///   上部のトグル。計測していなくても現在値(`latest`)は出す(サンプラーのコメント参照)。
/// - メモリの内訳・この本のキャッシュ・現在値の更新: この節が表示されている間だけ、1秒ごとに
///   `fetchBookSnapshot`(AppState経由でViewerViewModelへ)・`MemoryUsageRegistry.report()`・`refreshLatest()`を呼ぶ
///   (現在値はアプリで 1 つなので、複数のウインドウの節が同じ 1 秒に呼んでも読み直すのは 1 回。`refreshLatest` のコメント)。
///   このループは長寿命の`.task`で回るため、`fetchBookSnapshot`は**呼ばれた時点のAppStateを
///   引き直す**クロージャでなければならない(ContentView側のコメント参照)。本を切り替えても
///   ループは張り直されないので、渡されたクロージャ自体が古い本を指していると固まる。
/// - ディスクの走査: この節が表示されている間だけ、15秒ごと+「今すぐ更新」。ディレクトリの
///   全走査を伴うため、上の2つより粗い周期にしてある(`StorageUsageScanner`参照)。走査と結果は
///   アプリで 1 つ(`SharedStorageUsageScan`)。サイドパネルのモードはアプリで 1 つなので、「リソース」にすると
///   本を開いている全ウインドウの節が出て、以前はウインドウの数だけ同じ走査(1 回 1 秒前後になりうる)を重ねていた
///   (2026-10-05 の効率の監査 C8)。
///
/// ■ 再描画のコスト(実測に基づく)
/// 最初は1つのbodyに全節を書いていたが、1秒ごとの更新でパネル全体が再描画され、
/// 表示中のCPUが3〜5%に達した(計測そのものは0.0%)。そこで節ごとに**値型の入力だけを
/// 持つEquatableな子ビュー**へ分け、`.equatable()`で「入力が変わっていなければbodyを
/// 評価しない」ようにしてある。ディスクの節は15秒に1回しか変わらず、メモリの内訳は使用量が
/// 動いていなければ変わらないので、毎秒描き直すのはグラフの節と「内訳の無いメモリ」の 1 行だけで済む。
///
/// ■ 文字色
/// 項目名と数値はどちらも通常の文字色(callout)。グレー(secondary)にするのは節の見出しと、
/// 数値に添える補足(`NoteText`: 最大値・設定値・走査時刻・本の名前)だけ(ユーザー指摘:
/// 行ごとに項目名がグレーだったり数値がグレーだったりすると統一感が無い)。
///
/// ■ 「文字の影」
/// 文字・アイコンは`panelOutlinedContent()`、グラフは自前の地を持つ枠(`ResourceGraphView`
/// 参照)、使用率バー・先読みの帯・ON中のトグルの塗りは`panelOutlinedAccent`。サイドパネルとホーム(PanelSurface.welcome)の
/// どちらのすりガラス面に置いても同じ。
struct ResourceMonitorView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var sampler: ProcessResourceSampler

    /// このウインドウで開いている本のキャッシュの状態を取る橋渡し(AppState.fetchResourceSnapshot)。
    /// 本を開いていなければ、呼んだ結果がnilになる。ホームのインスペクタは nil を渡す(この本の節は出ない)。
    var fetchBookSnapshot: (() async -> ResourceMonitorSnapshot?)?

    @ObservedObject private var storageScan = SharedStorageUsageScan.shared

    @State private var bookSnapshot: ResourceMonitorSnapshot?
    /// メモリの内訳の全員(MemoryUsageRegistry.report())。
    @State private var memoryOwners: [MemoryUsageOwner] = []
    @State private var anomalies: [ResourceAnomaly] = []
    @State private var detector = ResourceAnomalyDetector()
    /// グラフの時間幅。falseなら直近2分(1秒刻み)、trueなら直近1時間(10秒平均)。
    @State private var showsLongRange = false
    /// 走査を今すぐやり直す合図(「今すぐ更新」ボタン)。値が変わるたびに`.task(id:)`が走り直す。
    @State private var storageScanRequest = 0
    /// 折り畳んだまとまり(`ResourceMonitorFolding`)。
    @AppStorage(ResourceMonitorFolding.defaultsKey) private var collapsedGroupsRaw = ""

    private static let storageScanInterval: TimeInterval = 15

    var body: some View {
        let collapsed = ResourceMonitorFolding.decode(collapsedGroupsRaw)
        let breakdown = MemoryUsageBreakdown(owners: memoryOwners)
        VStack(spacing: 0) {
            RecordingBar(sampler: sampler)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GraphsSection(
                        samples: showsLongRange ? sampler.history.coarse : sampler.history.fine,
                        capacity: showsLongRange ? ResourceHistory.coarseCapacity : ResourceHistory.fineCapacity,
                        showsLongRange: $showsLongRange,
                        latest: sampler.latest,
                        latestSample: sampler.latestSample,
                        isRecording: sampler.isRecording,
                        locale: preferences.effectiveLocale
                    )
                    .equatable()
                    VStack(alignment: .leading, spacing: 8) {
                        MemorySection(
                            breakdown: breakdown,
                            thisBook: bookSnapshot,
                            collapsed: collapsed,
                            locale: preferences.effectiveLocale,
                            onToggle: toggleGroup
                        )
                        .equatable()
                        UnattributedMemoryRow(
                            footprint: sampler.latest?.physicalFootprint,
                            breakdown: breakdown,
                            locale: preferences.effectiveLocale
                        )
                        .equatable()
                    }
                    StorageSection(
                        storage: storageScan.usage,
                        isScanning: storageScan.isScanning,
                        isDiskCacheEnabled: preferences.thumbnailDiskCacheEnabled,
                        diskCacheLimitBytes: Int(preferences.thumbnailDiskCacheLimitMB) * 1024 * 1024,
                        isFileBrowserThumbnailCacheEnabled: preferences.fileBrowserThumbnailCacheEnabled,
                        fileBrowserThumbnailCacheLimitBytes: Int(preferences.fileBrowserThumbnailCacheLimitMB) * 1024 * 1024,
                        collapsed: collapsed,
                        locale: preferences.effectiveLocale,
                        onRescan: { storageScanRequest &+= 1 },
                        onToggle: toggleGroup
                    )
                    .equatable()
                    AnomaliesSection(anomalies: anomalies)
                        .equatable()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .task(id: fetchBookSnapshot == nil) { await tickLoop() }
        .task(id: storageScanRequest) { await storageScanLoop() }
        // どのウインドウの走査の結果でも、届いたら異常を判定し直す(以前は自分の走査の後だけ。結果がアプリで 1 つになったので)。
        .onChange(of: storageScan.usage) { evaluateAnomalies(advancingStreaks: false) }
    }

    private func toggleGroup(_ key: String) {
        var collapsed = ResourceMonitorFolding.decode(collapsedGroupsRaw)
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        collapsedGroupsRaw = ResourceMonitorFolding.encode(collapsed)
    }

    // MARK: - 更新ループ

    /// この節が表示されている間、1秒ごとに「この本のキャッシュ」・メモリの内訳・現在値を取り直し、異常を
    /// 判定し直す。本の切り替えでは張り直されない(張り直しに頼らず、fetchBookSnapshotの側が
    /// 呼ばれるたびに今の本を引き直す。ContentViewのコメント参照)。
    private func tickLoop() async {
        while !Task.isCancelled {
            await refreshTick()
            try? await Task.sleep(for: .seconds(ProcessResourceSampler.interval))
        }
    }

    private func refreshTick() async {
        sampler.refreshLatest()
        let snapshot = await fetchBookSnapshot?()
        let owners = await MemoryUsageRegistry.forCurrentProcess?.report() ?? []
        guard !Task.isCancelled else { return }
        if snapshot != bookSnapshot { bookSnapshot = snapshot }
        if owners != memoryOwners { memoryOwners = owners }
        evaluateAnomalies()
    }

    private func evaluateAnomalies(advancingStreaks: Bool = true) {
        let found = detector.evaluate(advancingStreaks: advancingStreaks, .init(
            bookSnapshot: bookSnapshot,
            memory: memoryOwners,
            storage: storageScan.usage,
            isDiskCacheEnabled: preferences.thumbnailDiskCacheEnabled,
            diskCacheLimitBytes: Int(preferences.thumbnailDiskCacheLimitMB) * 1024 * 1024,
            isFileBrowserCacheEnabled: preferences.fileBrowserThumbnailCacheEnabled,
            fileBrowserCacheLimitBytes: Int(preferences.fileBrowserThumbnailCacheLimitMB) * 1024 * 1024,
            bookReaderCount: MemoryUsageBreakdown(owners: memoryOwners).bookReaderCount,
            liveNetworkCopyCount: StagedFileRegistry.shared.liveCount
        ))
        if found != anomalies { anomalies = found }
    }

    /// 15秒ごとにコンテナを走査する。「今すぐ更新」で`storageScanRequest`が変わるとループが
    /// 張り直され、即座に1回走る(ほかのウインドウの走査が先に始まっていても、押した後に始めた走査の結果を出す)。
    /// 15 秒より新しい結果があれば走査しない(ほかのウインドウの節が走査した。結果は `storageScan` から全部の節へ届く)。
    private func storageScanLoop() async {
        var forces = storageScanRequest != 0
        while !Task.isCancelled {
            await storageScan.refresh(maxAge: forces ? 0 : Self.storageScanInterval, locations: Self.storageLocations())
            forces = false
            try? await Task.sleep(for: .seconds(Self.storageScanInterval))
        }
    }

    private static func storageLocations() -> StorageUsageScanner.Locations {
        let containerRoot = FileManager.default.homeDirectoryForCurrentUser
        return StorageUsageScanner.Locations(
            containerRoot: containerRoot,
            sessionTemporaryDirectory: TemporaryFileStore.sessionDirectory,
            temporaryRoot: FileManager.default.temporaryDirectory,
            thumbnailCacheDirectory: ThumbnailDiskCache.shared.directory,
            pageListCacheDirectory: BookPageListCache.shared.directoryURL,
            collectionCoverDirectory: CollectionCoverStore.defaultDirectory(),
            collectionCoverSourceDirectory: CollectionCoverSourceStore.defaultDirectory(),
            collectionTileDirectory: CollectionTileImageStore.defaultDirectory(),
            fileBrowserThumbnailCacheDirectory: FileBrowserThumbnailDiskCache.shared.directory,
            smartLibraryCatalogDirectory: SmartLibraryCatalog.defaultCacheURL?.deletingLastPathComponent(),
            metadataRulesDirectory: MetadataRulesStore.defaultURL.deletingLastPathComponent(),
            metadataCorpusDirectory: MetadataCorpusStore.defaultURL?.deletingLastPathComponent(),
            preferencesDirectory: containerRoot.appendingPathComponent("Library/Preferences", isDirectory: true),
            databaseStoreURL: QooViewerApp.modelConfiguration.url
        )
    }
}

/// 折り畳んだまとまりの覚え方(アプリで 1 つ。UserDefaults の 1 つの文字列に、まとまりの鍵を `,` で並べる)。
/// 環境設定(`qooViewer.pref.*`)ではない画面の状態なので、保存データの書き出しには入らない(ホームのインスペクタの
/// 出し入れ `qooViewer.welcome.showsInspector` と同じ扱い)。
enum ResourceMonitorFolding {
    static let defaultsKey = "qooViewer.resourceMonitor.collapsedGroups"

    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    static func encode(_ keys: Set<String>) -> String {
        keys.sorted().joined(separator: ",")
    }

    static func memoryKey(_ feature: MemoryUsageFeature) -> String { "memory.\(feature.rawValue)" }
    static func diskKey(_ group: StorageGroup) -> String { "disk.\(group.rawValue)" }

    /// ディスクのまとまり。
    enum StorageGroup: String, CaseIterable {
        case viewer, library, fileBrowser, metadata, savedData, temporary
    }
}

/// コンテナのディスク使用量の走査と、その最新の結果(アプリで 1 つ。`ResourceMonitorView` の型コメント)。
///
/// 走査は同時に 1 本だけ。走っている間に頼まれたら、それを待つ(「今すぐ更新」は、頼んだ時点より前に始まった走査なら、
/// 終わるのを待ってからもう 1 本走らせる)。走査はブロッキングする列挙なので FileIO の上で(CLAUDE.md の FileIO の約束。
/// 2026-10-04 の監査 §2-4)。待っていた節が消えても走査は止めない ―― 1 本だけで、ほかのウインドウの節が待っていることがある。
@MainActor
final class SharedStorageUsageScan: ObservableObject {
    static let shared = SharedStorageUsageScan()

    /// 最新の結果(まだ無ければ nil)。
    @Published private(set) var usage: StorageUsage?
    /// 走査中か(「今すぐ更新」を淡色にする)。
    @Published private(set) var isScanning = false

    private var finishedAt: ContinuousClock.Instant?
    private var running: (id: Int, task: Task<StorageUsage?, Never>, startedAt: ContinuousClock.Instant)?
    private var lastRunID = 0

    /// 最新の結果が `maxAge` 秒より古ければ(無ければ)走査する。0 なら必ず、呼んだ後に始まった走査の結果にする。
    func refresh(maxAge: TimeInterval, locations: StorageUsageScanner.Locations) async {
        let requestedAt = ContinuousClock.now
        if maxAge > 0, let finishedAt, requestedAt - finishedAt < .seconds(maxAge) { return }
        // 走っている走査があれば待つ。古さを問わない頼みならそれで足りる。「今すぐ」は、頼んだ後に始まった走査でなければもう 1 本。
        // 待ち終えた走査がまだ `running` に残っている(始めた側がまだ片付けていない)ときは、もう待たずに始める ―― 同じ走査を
        // 待ち直すと、終わった Task の待ちがその場で戻る場合にメインで回り続ける(2026-10-05 のコードレビュー)。片付けは
        // 自分の番号のときだけ行うので、ここで始めた走査は先の走査の片付けに消されない。
        while let current = running {
            _ = await current.task.value
            if maxAge > 0 || current.startedAt >= requestedAt { return }
            if running?.id == current.id { break }
        }
        lastRunID &+= 1
        let id = lastRunID
        let task = Task { await FileIO.perform(qos: .utility) { StorageUsageScanner.scan(locations) } }
        running = (id, task, ContinuousClock.now)
        isScanning = true
        let result = await task.value
        if running?.id == id {
            running = nil
            isScanning = false
        }
        finishedAt = ContinuousClock.now
        if let result { usage = result }
    }
}


// MARK: - 計測トグル

/// 他のモードの上部ボタン列(戻る/進む、＋/鉛筆、ゴミ箱)と同じ位置・同じ高さ。
private struct RecordingBar: View {
    @ObservedObject var sampler: ProcessResourceSampler

    var body: some View {
        HStack(spacing: 8) {
            Button {
                sampler.setRecording(!sampler.isRecording)
            } label: {
                Image(systemName: sampler.isRecording ? "stop.circle.fill" : "record.circle")
                    .panelIconButtonLabel(isHighlighted: sampler.isRecording)
                    // ON中は地がColor.primary。重ね色がそれと同じ色だと地が溶けて
                    // 「計測中」であることが伝わらないので、縁を付ける。
                    .panelOutlinedAccent(
                        in: RoundedRectangle(cornerRadius: PanelIconButtonLabel.cornerRadius, style: .continuous),
                        isEnabled: sampler.isRecording
                    )
            }
            .buttonStyle(.borderless)
            .help(sampler.isRecording ? "Stop Recording" : "Start Recording")

            Group {
                if sampler.isRecording, let startedAt = sampler.recordingStartedAt {
                    Text("Recording since \(startedAt, format: .dateTime.hour().minute())")
                } else {
                    Text("Not recording")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .panelOutlinedContent()
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

// MARK: - グラフの節

private struct GraphsSection: View, Equatable {
    var samples: [ResourceSample]
    var capacity: Int
    @Binding var showsLongRange: Bool
    var latest: ProcessResourceReading?
    var latestSample: ResourceSample?
    var isRecording: Bool
    var locale: Locale

    private static let graphHeight: CGFloat = 56

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.samples == rhs.samples && lhs.capacity == rhs.capacity
            && lhs.showsLongRange == rhs.showsLongRange && lhs.latest == rhs.latest
            && lhs.latestSample == rhs.latestSample && lhs.isRecording == rhs.isRecording
            && lhs.locale == rhs.locale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SectionTitle("This App")
                Spacer(minLength: 0)
                Button {
                    showsLongRange.toggle()
                } label: {
                    NoteText(Text(showsLongRange ? "1 hour" : "2 min"))
                }
                .buttonStyle(.plain)
                .help("Switch the graphs between the last 2 minutes and the last hour")
            }
            cpuGraph
            memoryGraph
            diskGraph
        }
    }

    private var cpuGraph: some View {
        let values = samples.map(\.cpuPercent)
        let peak = values.max() ?? 0
        return graphBlock(
            title: "CPU",
            systemImage: "cpu",
            current: latestSample.map { Text(verbatim: percentText($0.cpuPercent)) },
            footer: Text("Peak \(percentText(peak))"),
            series: [.init(id: "cpu", color: .blue, values: values)],
            maxValue: max(100, ResourceGraphScale.niceCeiling(peak, fallback: 100))
        )
    }

    private var memoryGraph: some View {
        let values = samples.map { Double($0.physicalFootprint) }
        let footprint = latest?.physicalFootprint ?? 0
        let lifetimeMax = latest?.lifetimeMaxFootprint ?? 0
        let scale = ResourceGraphScale.niceCeiling(
            max(values.max() ?? 0, Double(footprint)) * 1.1,
            fallback: Double(512 * 1024 * 1024)
        )
        return VStack(alignment: .leading, spacing: 4) {
            graphBlock(
                title: "Memory",
                systemImage: "memorychip",
                current: Text(verbatim: memoryText(footprint)),
                footer: Text("Peak since launch \(memoryText(lifetimeMax))"),
                series: [.init(id: "mem", color: .green, values: values)],
                maxValue: scale
            )
        }
    }

    private var diskGraph: some View {
        let reads = samples.map(\.diskReadBytesPerSecond)
        let writes = samples.map(\.diskWriteBytesPerSecond)
        let peak = max(reads.max() ?? 0, writes.max() ?? 0)
        return VStack(alignment: .leading, spacing: 4) {
            graphBlock(
                title: "Disk",
                systemImage: "internaldrive",
                current: latestSample.map {
                    Text("\(rateText($0.diskReadBytesPerSecond)) ↓ \(rateText($0.diskWriteBytesPerSecond)) ↑")
                },
                footer: Text("Peak \(rateText(peak))"),
                series: [
                    .init(id: "read", color: .orange, values: reads),
                    .init(id: "write", color: .purple, values: writes),
                ],
                maxValue: ResourceGraphScale.niceCeiling(peak, fallback: 1024 * 1024)
            )
            .help("Physical disk reads (orange) and writes (purple). Reads served from the system’s file cache are not counted, matching Activity Monitor’s Disk tab.")
            if let latest {
                DetailRow("Read since launch", fileSizeText(latest.diskBytesRead))
                DetailRow("Written since launch", fileSizeText(latest.diskBytesWritten))
            }
        }
    }

    /// 見出し行(アイコン+名前+右寄せの現在値)、グラフ、下の小さな補足、の3段。
    private func graphBlock(
        title: LocalizedStringKey,
        systemImage: String,
        current: Text?,
        footer: Text,
        series: [ResourceGraphView.Series],
        maxValue: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption)
                Text(title)
                    .font(.callout)
                Spacer(minLength: 0)
                if let current {
                    current
                        .font(.callout)
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .panelOutlinedContent()

            ResourceGraphView(series: series, capacity: capacity, maxValue: maxValue)
                .frame(height: Self.graphHeight)
                .overlay(alignment: .center) {
                    if !isRecording {
                        Text("Start recording to see a graph")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .panelOutlinedContent()
                    }
                }

            NoteText(footer)
        }
    }

    /// "%"を文字列側で付ける。`Text("\(value)%")`の形だと、補間の直後の"%"が書式指定と
    /// 衝突してString Catalogのキーが素直に引けない。
    private func percentText(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(0)).locale(locale)) + "%"
    }

    private func memoryText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory).locale(locale))
    }

    private func fileSizeText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(locale))
    }

    private func rateText(_ bytesPerSecond: Double) -> String {
        fileSizeText(Int(bytesPerSecond)) + "/s"
    }
}

// MARK: - メモリの内訳

/// メモリの内訳(MemoryUsageRegistry の届け出を機能ごとにまとめたもの)。まとまりは折り畳める。
///
/// ■ 何を合計に足すか
/// 上限付きのキャッシュ・入れ子の書庫・7z のデコーダ・拡大や原寸大の画像は、意図して抱えているものなので足す。一覧のセルが
/// 抱えている絵(`MemoryUsageKind.cellImages`)は**見積もり**で、キャッシュの絵とバッファを共有していることがあるので足さない
/// (「≈」を付けて出す)。
///
/// ■ このウインドウの本
/// サイドパネルでは、このウインドウの本(`thisBook` の `memoryOwnerID`)だけを以前の「この本」の節と同じ詳しさで出す
/// (使用率のバー・先読みの帯・過去のページ)。ほかの持ち主は、使っている項目だけを 1 行ずつ。
private struct MemorySection: View, Equatable {
    var breakdown: MemoryUsageBreakdown
    var thisBook: ResourceMonitorSnapshot?
    var collapsed: Set<String>
    var locale: Locale
    var onToggle: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.breakdown == rhs.breakdown && lhs.thisBook == rhs.thisBook && lhs.collapsed == rhs.collapsed
            && lhs.locale == rhs.locale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Memory Breakdown")
                .help("Memory the app deliberately keeps, grouped by the feature that uses it. Each limit applies to each book or cache separately.")
            ForEach(breakdown.groups) { group in
                let key = ResourceMonitorFolding.memoryKey(group.feature)
                let isExpanded = !collapsed.contains(key)
                FoldableGroupHeader(
                    title: group.feature.titleKey,
                    value: memoryText(group.totalBytes),
                    isExpanded: isExpanded,
                    onToggle: { onToggle(key) }
                )
                .help(group.feature.helpKey)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if group.owners.isEmpty {
                            NoteText(Text("Not in use"))
                        }
                        ForEach(group.owners) { owner in
                            ownerView(owner)
                        }
                    }
                    .padding(.leading, FoldableGroupHeader.contentIndent)
                }
            }
        }
    }

    @ViewBuilder
    private func ownerView(_ owner: MemoryUsageOwner) -> some View {
        if let thisBook, owner.id == thisBook.memoryOwnerID {
            ThisBookBlock(snapshot: thisBook, owner: owner, locale: locale)
        } else if owner.role == .homeCaches {
            // アプリで 1 つのキャッシュは、持ち主の見出しを付けずに項目を並べる(どれも名前だけで何か分かる)。
            VStack(alignment: .leading, spacing: 8) {
                ForEach(owner.items, id: \.kind) { item in
                    MemoryItemRow(item: item, locale: locale)
                }
            }
        } else if owner.items.count == 1, let item = owner.items.first {
            // 項目が 1 つだけの持ち主(一覧のセル・原寸大)は、持ち主の名前の 1 行。
            MemoryItemRow(item: item, title: owner.role.titleText, locale: locale)
                .help(owner.role.helpKey)
        } else {
            OwnerBlock(owner: owner, locale: locale)
        }
    }

    private func memoryText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory).locale(locale))
    }
}

/// 「内訳の無いメモリ」の 1 行。フットプリントが毎秒動くので、内訳の節とは別の Equatable にして、毎秒描き直すのはここだけにする。
private struct UnattributedMemoryRow: View, Equatable {
    var footprint: Int?
    var breakdown: MemoryUsageBreakdown
    var locale: Locale

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.footprint == rhs.footprint && lhs.breakdown.attributedBytes == rhs.breakdown.attributedBytes
            && lhs.locale == rhs.locale
    }

    var body: some View {
        let value = footprint.flatMap { breakdown.unattributedBytes(footprint: $0) }
        DetailRow("Not broken down", value.map(memoryText) ?? "—")
            .help("Memory in use that none of the items above account for: the app itself and the system frameworks, the saved data, the pictures on screen and the copies the system keeps to draw them, and memory not yet returned to the system. Shown as — when the system has compressed the items above below their nominal size.")
    }

    private func memoryText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory).locale(locale))
    }
}

/// このウインドウの本(以前の「この本」の節。使用率のバー・先読みの帯・過去のページ)。
private struct ThisBookBlock: View {
    var snapshot: ResourceMonitorSnapshot
    var owner: MemoryUsageOwner
    var locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailRow("This Book", memoryText(owner.totalBytes))
                .help("The book shown in this window.")
            VStack(alignment: .leading, spacing: 8) {
                UsageBarRow(
                    title: Text("Page images"),
                    usage: snapshot.pageImages,
                    countsPages: true,
                    locale: locale,
                    help: "Decoded page images kept in memory, against the “Page images kept in memory” setting."
                )
                preloadRow
                alreadyReadRow
                UsageBarRow(
                    title: Text("Thumbnails"),
                    usage: snapshot.thumbnails,
                    locale: locale,
                    help: "Thumbnails for the progress bar and page lists, against their built-in limit."
                )
                UsageBarRow(
                    title: Text("Enlarged thumbnails"),
                    usage: snapshot.gridThumbnails,
                    locale: locale,
                    help: "Larger thumbnails for the page list grid and hover previews, against their built-in limit."
                )
                // 入れ子の書庫が無い本(ほとんどの本)では、常に0の行が並ぶだけなので出さない。
                if snapshot.nestedArchives.count > 0 || snapshot.nestedArchiveTemporaryBytes > 0 {
                    UsageBarRow(
                        title: Text("Nested archives"),
                        usage: snapshot.nestedArchives,
                        locale: locale,
                        help: "Archives found inside this book that are open right now, against the “Nested archives kept in memory” setting. Every format is read directly from memory; an archive larger than the setting is written to a temporary file instead, which appears under On Disk ▸ Temporary files."
                    )
                }
                // 7zのライブラリが次のページを続きから読むために持ち続けているデコーダ(LZMA辞書+
                // バッファ)。ページ画像のキャッシュとは別に居座るメモリ。
                // 以前はソリッドブロック全体が常駐していて上限見積り(「≤」付き)しか出せなかったが、
                // 2026-09にライブラリをフォークして必要なぶんだけ伸長するようになり、実値が取れる
                // (SevenZipArchiveReader参照)。下調べ専用の reader のぶんも入る(PageLoader.cacheStatistics)。7zを含まない本では出さない。
                if snapshot.sevenZipDecoderBytes > 0 {
                    DetailRow("7z decoder memory", memoryText(snapshot.sevenZipDecoderBytes))
                        .help(MemoryUsageKind.sevenZipDecoder.helpKey)
                }
                // 拡大(ピンチ・拡大鏡)の高解像度画像。使っていなければ出さない。
                if let zoom = owner.items.first(where: { $0.kind == .zoomImages }), zoom.usedBytes > 0 {
                    DetailRow("Zoom images", memoryText(zoom.usedBytes))
                        .help(MemoryUsageKind.zoomImages.helpKey)
                }
            }
            .padding(.leading, FoldableGroupHeader.contentIndent)
        }
    }

    /// 先読みの帯(環境設定「前後に先読みするページ数」の範囲を1マス1ページで並べ、メモリに
    /// 残っているマスを塗る)と、その充填数。
    ///
    /// ■ なぜ帯の目盛りが「設定値そのもの」なのか
    /// 以前は前後`radius + 2`マスの帯に「前 N · 後 M」という数字を添えていた。ところが前
    /// (読み終えた側)のページは環境設定「メモリに残しておくページ画像」の上限までLRUで残る
    /// ので、Nは12マスの帯を軽く超えて20にも52にもなる。帯は点灯しきったまま数字だけ伸びる
    /// =帯が情報を持たない状態になり、「設定10なのに52とは異常では」という指摘を受けた。
    /// しかも履歴が押し出されるのはLRUの正常動作なので、前方向の帯は異常検知の材料にもならない。
    /// そこで帯は先読みの範囲ちょうどに詰め、はみ出した履歴は数字だけの別行
    /// (alreadyReadRow =「過去のページ」)に分けてある。こうすると「マスが全部塗られている=先読みは追いついている」が一目で分かり、
    /// 欠けたマスがそのまま異常の手がかりになる。
    ///
    /// ■ 読み方向に合わせて反転する
    /// 帯は画面上の並びなので、右開きの本では後のページが**左**に来なければ実際のページ送りと
    /// 逆に見える(ユーザー指摘)。
    ///
    /// ■ 見開きは2マスが「現在」
    /// 表示中のページ(見開きなら2ページ)をまとめて現在として塗り、先読みの数からも外す。
    /// 以前は先頭ページの1マスだけを現在にしていたため、隣に表示している相方が先読みのマスに
    /// 紛れ、「表示は2ページなのに帯の現在は1マス」に見えていた(ユーザー指摘)。先読み自体も
    /// 表示中の最後のページを基点にするよう直してあるので、見開きでも後ろ側は設定値ちょうど
    /// 埋まる(PageLoader.prefetchのdisplayedPageCount参照)。
    private var preloadRow: some View {
        let neighbours = preloadNeighbourIndices
        let radius = snapshot.prefetchRadius
        let ascending = Array((snapshot.currentIndex - radius)...(lastDisplayedIndex + radius))
        let cells = snapshot.isRightToLeft ? Array(ascending.reversed()) : ascending
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Preloaded pages")
                    .font(.callout)
                Spacer(minLength: 0)
                preloadCountsText
                    .font(.callout)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .panelOutlinedContent()

            // 先読み0(または1ページだけの本)では並べるマスが無いので、帯ごと出さない。
            if !neighbours.isEmpty {
                HStack(spacing: 2) {
                    ForEach(cells, id: \.self) { index in
                        let exists = (0..<snapshot.pageCount).contains(index)
                        let isCurrent = (snapshot.currentIndex...lastDisplayedIndex).contains(index)
                        let isResident = snapshot.residentIndicesAroundCurrent.contains(index)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(cellColor(exists: exists, isCurrent: isCurrent, isResident: isResident))
                            .frame(maxWidth: .infinity)
                            .frame(height: 8)
                            // マスの塗りはアクセント色(現在ページ・残っているページ)か文字色の
                            // 薄い塗り(残っていないページ)。どちらも重ね色と同化しうるので、
                            // 実在するページのマスには縁を付ける。
                            .panelOutlinedAccent(
                                in: RoundedRectangle(cornerRadius: 2, style: .continuous),
                                isEnabled: exists
                            )
                    }
                }
            }
        }
        .help("One cell per page across the “Pages to preload on each side” range, laid out in reading order around the pages on screen (two cells in two-page spreads). Every cell filled means preloading is keeping up; a gap means that page is not in memory yet.")
    }

    /// 先読みの範囲より外側に、まだメモリに残っている既読ページ数(「過去のページ」)。帯は付けない
    /// (目盛りになる上限が枚数ではなくメモリ量なので、マスで表しても読めないため)。
    private var alreadyReadRow: some View {
        HStack(spacing: 6) {
            Text("Earlier pages")
                .font(.callout)
            Spacer(minLength: 0)
            // 単位は付けない。行名(「過去のページ」)で何の数かは分かるうえ、上下の行が
            // 「MB / MB · 枚数」「n/n」と単位の無い数字なので、ここだけ「ページ」が付くと
            // 桁が揃わず読みにくい(ユーザー指摘)。
            Text("\(max(snapshot.residentBefore - snapshot.prefetchRadius, 0))")
                .font(.callout)
                .monospacedDigit()
        }
        .lineLimit(1)
        .panelOutlinedContent()
        .help("Pages you have already read that are still in memory beyond the preload range, counted back from the current page without a gap. They stay until the “Page images kept in memory” limit is reached, so anything from zero to dozens is normal.")
    }

    /// 表示中のページのうち、ファイル順で最後のもの(単ページなら現在ページ自身)。
    private var lastDisplayedIndex: Int {
        snapshot.currentIndex + snapshot.displayedPageCount - 1
    }

    /// 帯が描く範囲のうち、表示中のページを除いて**実在する**ページのインデックス。
    /// 本の先頭・末尾では範囲が本からはみ出すので、分母から外さないと埋まらないままになる。
    private var preloadNeighbourIndices: [Int] {
        let radius = snapshot.prefetchRadius
        guard radius > 0 else { return [] }
        return ((snapshot.currentIndex - radius)...(lastDisplayedIndex + radius))
            .filter { !(snapshot.currentIndex...lastDisplayedIndex).contains($0)
                && (0..<snapshot.pageCount).contains($0) }
    }

    /// 帯の充填数を「前 10/10 · 後 10/10」と**片側ずつ**出す。
    ///
    /// 前後をまとめて「20 / 20」と出していたときは、環境設定が10なのに20と出るのが分かり
    /// にくいという指摘を受けた(ユーザー指摘)。片側ずつにすれば、分母がそのまま設定値になる。
    /// 本の先頭・末尾ではその側に実在するページが無いので、分母0の側(「前 0/0」)は出さない。
    /// 並び順は帯と揃え、右開きでは後(帯の左端)を先に書く。
    private func preloadSideText(offsets: [Int], isForward: Bool) -> Text? {
        let existing = offsets.filter { (0..<snapshot.pageCount).contains($0) }
        guard !existing.isEmpty else { return nil }
        let filled = existing.filter(snapshot.residentIndicesAroundCurrent.contains).count
        return Text(
            isForward
                ? "after \(filled)/\(existing.count)"
                : "before \(filled)/\(existing.count)"
        )
    }

    private var preloadCountsText: Text {
        let radius = snapshot.prefetchRadius
        guard radius > 0 else { return Text("Off") }
        let current = snapshot.currentIndex
        let last = lastDisplayedIndex
        let backward = preloadSideText(offsets: (1...radius).map { current - $0 }, isForward: false)
        let forward = preloadSideText(offsets: (1...radius).map { last + $0 }, isForward: true)
        let ordered = snapshot.isRightToLeft ? [forward, backward] : [backward, forward]
        let parts = ordered.compactMap { $0 }
        guard let first = parts.first else { return Text("Off") }
        // 区切りはローカライズ対象ではないのでverbatim(文字列カタログに拾わせない)。
        return parts.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
    }

    private func cellColor(exists: Bool, isCurrent: Bool, isResident: Bool) -> Color {
        if !exists { return Color.clear }
        if isCurrent { return Color.accentColor }
        // 残っているページも文字色ではなくアクセント色の薄い塗りにする。文字色だと、
        // 重ね色を文字色に寄せたとき(ダーク外観+白など)に「残っている/いない」の差が
        // 縁だけになって読めない。
        return isResident ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.12)
    }

    private func memoryText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory).locale(locale))
    }
}

/// このウインドウの本以外の、項目が複数ある持ち主(ほかのウインドウの本・編集ウインドウの本・書き出し中の本など)。
/// 見出し(持ち主の名前と合計、本の名前)と項目。**項目の並び・形は「この本」(ThisBookBlock)と同じ**(2026-10-11、利用者の指示:
/// サイドパネルとインスペクタで同じ構成・並びに)―― 3 つのキャッシュは 0 でも使用率のバー付きで出し、入れ子の書庫・7z のデコーダ・
/// 拡大の画像は使っているときだけ。「この本」と違うのは、このウインドウでしか意味の無い先読みの帯と過去のページが無いことだけ。
private struct OwnerBlock: View {
    var owner: MemoryUsageOwner
    var locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                DetailRow(owner.role.titleText, memoryText(owner.totalBytes))
                if let subtitle = owner.role.bookTitle {
                    NoteText(Text(verbatim: subtitle))
                        .truncationMode(.middle)
                }
            }
            .help(owner.role.helpKey)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(owner.items.filter { Self.alwaysShownKinds.contains($0.kind) || $0.usedBytes > 0 }, id: \.kind) { item in
                    MemoryItemRow(item: item, locale: locale)
                }
            }
            .padding(.leading, FoldableGroupHeader.contentIndent)
        }
    }

    /// 0 でも出す項目(「この本」と同じ)。
    private static let alwaysShownKinds: Set<MemoryUsageKind> = [.pageImages, .thumbnails, .gridThumbnails]

    private func memoryText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory).locale(locale))
    }
}

/// 内訳の項目 1 つ。上限のあるものは「使用量 / 上限 · 件数」と使用率のバー、無いものは使用量だけ。見積もりには「≈」を付ける。
private struct MemoryItemRow: View {
    var item: MemoryUsageItem
    var title: Text?
    var locale: Locale

    var body: some View {
        let label = title ?? Text(item.kind.titleKey)
        if let limit = item.limitBytes {
            UsageBarRow(
                title: label,
                usage: .init(usedBytes: item.usedBytes, limitBytes: limit, count: item.count ?? 0),
                countsPages: item.kind == .pageImages,
                locale: locale,
                help: item.kind.helpKey
            )
        } else {
            HStack(spacing: 6) {
                label
                    .font(.callout)
                Spacer(minLength: 0)
                Text(verbatim: valueText)
                    .font(.callout)
                    .monospacedDigit()
                    .fixedSize()
            }
            .lineLimit(1)
            .panelOutlinedContent()
            .help(item.kind.helpKey)
        }
    }

    private var valueText: String {
        let used = memoryText(item.usedBytes)
        if !item.kind.countsTowardTotal { return "≈ " + used }
        if let limit = item.limitBytes { return used + " / " + memoryText(limit) }
        return used
    }

    private func memoryText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory).locale(locale))
    }
}

/// 使用率のバー付きの 1 行(「使用量 / 上限 · 件数」)。
private struct UsageBarRow: View {
    var title: Text
    var usage: ResourceMonitorSnapshot.CacheUsage
    /// 末尾の件数に「ページ」を付けるか。ページ画像だけtrueにする
    /// (ユーザー要望)。この行の件数は先読み・過去のページの2行が数えている対象そのもので、
    /// 単位があったほうが手前のMBの数字と区別しやすい。サムネイルの行は枚数のまま。
    var countsPages = false
    var locale: Locale
    var help: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 1 行に収まらなければ、数値を名前の下の行へ回す(数値は切らない。インスペクタの幅 220〜300pt では
            // 「使用量 / 上限 · 件数」が長く、名前が「ペー…」まで削れた ―― 2026-10-11 の実機検証)。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    title
                        .font(.callout)
                        .fixedSize()
                    Spacer(minLength: 0)
                    valueText
                }
                VStack(alignment: .leading, spacing: 1) {
                    title
                        .font(.callout)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        valueText
                    }
                }
            }
            .lineLimit(1)
            .panelOutlinedContent()

            GeometryReader { geometry in
                let fraction = min(max(usage.fraction, 0), 1)
                let isOver = usage.usedBytes > usage.limitBytes
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                        // 溝は文字色の薄い塗りなので、重ね色が文字色と同じだと消える。
                        // 縁を付けて「ここまでが100%」が読めるようにする。
                        .panelOutlinedAccent(in: Capsule())
                    Capsule()
                        .fill(isOver ? Color.red : Color.accentColor)
                        .frame(width: max(geometry.size.width * fraction, fraction > 0 ? 4 : 0))
                        // アクセント色の塗りは、重ね色が近い色だと長さが読めなくなる。
                        .panelOutlinedAccent(in: Capsule(), isEnabled: fraction > 0)
                }
            }
            .frame(height: 6)
        }
        .help(help)
    }

    private var valueText: some View {
        Text(usageCountText)
            .font(.callout)
            .monospacedDigit()
            .fixedSize()
    }

    private var usageCountText: LocalizedStringKey {
        let used = memoryText(usage.usedBytes)
        let limit = memoryText(usage.limitBytes)
        if countsPages {
            return "\(used) / \(limit) · \(usage.count) pages"
        }
        return "\(used) / \(limit) · \(usage.count)"
    }

    private func memoryText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory).locale(locale))
    }
}

/// 折り畳めるまとまりの見出し(三角・名前・右寄せの合計)。行全体が押せる。
private struct FoldableGroupHeader: View {
    var title: LocalizedStringKey
    var value: String
    var isExpanded: Bool
    var onToggle: () -> Void

    /// 中身を見出しの名前の位置まで下げる幅(三角の幅 + 間隔)。
    static let contentIndent: CGFloat = 14

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Self.contentIndent - 4)
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                Text(verbatim: value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            .lineLimit(1)
            .contentShape(Rectangle())
            .panelOutlinedContent()
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
    }
}

// MARK: - 名前と説明

extension MemoryUsageFeature {
    var titleKey: LocalizedStringKey {
        switch self {
        case .viewer: return "Viewer"
        case .toolWindows: return "Tool Windows"
        case .home: return "Home"
        }
    }

    var helpKey: LocalizedStringKey {
        switch self {
        case .viewer:
            return "Books open in viewer windows and tabs, the side panel, and Actual Size windows."
        case .toolWindows:
            return "Books read by Edit Bookmarks & Layout and by book export, including choosing a cover page."
        case .home:
            return "The file browser, libraries, smart library and inspector: their thumbnails and covers, and the books read to make collection covers."
        }
    }
}

extension MemoryUsageRole {
    /// 行の名前。ビューアの本は本の名前そのもの(名前を出さない本は「シークレットの本」)。
    var titleText: Text {
        switch self {
        case .viewerBook(let title):
            if let title { return Text(verbatim: title) }
            return Text("Book in a Private Window")
        default:
            return Text(titleKey)
        }
    }

    private var titleKey: LocalizedStringKey {
        switch self {
        case .viewerBook: return "Book in a Private Window"
        case .bookContents: return "Book contents pane"
        case .actualSize: return "Actual Size"
        case .pageListCells: return "Page list"
        case .sidePanelPageCells: return "Side panel pages"
        case .bookmarkEditor: return "Edit Bookmarks & Layout"
        case .bookmarkEditorCells: return "Edit Bookmarks & Layout list"
        case .exportCoverPicker: return "Choosing a cover page to export"
        case .exporting: return "Book being exported"
        case .otherBookReading: return "Other book reading"
        case .homeCaches: return "Shared caches"
        case .coverExtraction: return "Making collection covers"
        case .collectionGridCells: return "Collection list"
        case .collectionItemCells: return "Books in the collection"
        case .smartLibraryCells: return "Smart library covers"
        }
    }

    /// 見出しの下に添える本の名前(見出しそのものが本の名前のとき・名前を出さない本では nil)。
    var bookTitle: String? {
        switch self {
        case .bookmarkEditor(let title), .exportCoverPicker(let title): return title
        default: return nil
        }
    }

    var helpKey: LocalizedStringKey {
        switch self {
        case .viewerBook:
            return "A book open in another window or tab."
        case .bookContents:
            return "Nested archives that the lower half of the side panel opened itself to list the book’s contents, against the “Nested archives kept in memory” setting."
        case .actualSize:
            return "The full-size image shown in an Actual Size window. It is released when the window is closed."
        case .pageListCells, .sidePanelPageCells, .bookmarkEditorCells, .collectionGridCells, .collectionItemCells,
             .smartLibraryCells:
            return MemoryUsageKind.cellImages.helpKey
        case .coverExtraction:
            return "Books being read for a moment to make the covers of books added to a collection."
        case .bookmarkEditor:
            return "The book open in the Edit Bookmarks & Layout window."
        case .exportCoverPicker:
            return "The book read to choose its cover page in an export window."
        case .exporting:
            return "A book being read page by page to export it."
        case .otherBookReading:
            return "A book being read by something not listed above."
        case .homeCaches:
            return "Caches shared by every window’s Home."
        }
    }
}

extension MemoryUsageKind {
    var titleKey: LocalizedStringKey {
        switch self {
        case .pageImages: return "Page images"
        case .thumbnails: return "Thumbnails"
        case .gridThumbnails: return "Enlarged thumbnails"
        case .nestedArchives: return "Nested archives"
        case .sevenZipDecoder: return "7z decoder memory"
        case .zoomImages: return "Zoom images"
        case .actualSizeImage: return "Actual Size"
        // まとまり(「ホーム」)の中なので短い名前。何のサムネイルかは説明に書く。
        case .fileBrowserThumbnails: return "Thumbnails"
        case .collectionCovers: return "Collection covers"
        case .collectionTiles: return "Collection tiles"
        case .cellImages: return "Pictures held by the list"
        }
    }

    var helpKey: LocalizedStringKey {
        switch self {
        case .pageImages:
            return "Decoded page images kept in memory, against the “Page images kept in memory” setting."
        case .thumbnails:
            return "Thumbnails for the progress bar and page lists, against their built-in limit."
        case .gridThumbnails:
            return "Larger thumbnails for the page list grid and hover previews, against their built-in limit."
        case .nestedArchives:
            return "Archives found inside the book that are open right now, against the “Nested archives kept in memory” setting."
        case .sevenZipDecoder:
            return "Memory the 7z library keeps between page reads so that the next page of a solid block can continue from where the last one ended (and a few pages back can be re-read without starting the block over): the LZMA dictionary of that block, whose size is chosen when the archive is made (usually 16–64 MB), plus small buffers. It is released when the book is closed."
        case .zoomImages:
            return "Higher-resolution copies of the pages on screen, decoded for pinch zoom and the loupe. They are released when you turn the page or close the book."
        case .actualSizeImage:
            return "The full-size image shown in an Actual Size window. It is released when the window is closed."
        case .fileBrowserThumbnails:
            return "Pictures of books, images, videos and folders shown in the file browser’s icon view, the smart library and the inspector, against their built-in limit. They are also kept on disk (On Disk ▸ File Browser & Smart Library)."
        case .collectionCovers:
            return "Decoded collection covers for the books inside a collection, against their built-in limit."
        case .collectionTiles:
            return "Decoded collection tiles for the library’s collection list, against their built-in limit."
        case .cellImages:
            return "An estimate of the pictures held by the cells of this list since it was last rebuilt. The list is rebuilt to let them go once they pass its budget. Some of them are the same pictures as in the caches, so this is not added to the totals."
        }
    }
}

// MARK: - ディスク

/// コンテナのディスク使用量を、機能ごとのまとまりで出す(2026-10-11)。まとまりは折り畳める。
///
/// 容量はすべてディスクの上で確保されている量(DiskFootprint)。上限のあるキャッシュは上限を並べる(刈り込みも同じ数え方)。
/// 「その他」は名前の付いた内訳を引いた残り、「コンテナ全体」は全部の合計。
private struct StorageSection: View, Equatable {
    var storage: StorageUsage?
    var isScanning: Bool
    var isDiskCacheEnabled: Bool
    var diskCacheLimitBytes: Int
    var isFileBrowserThumbnailCacheEnabled: Bool
    var fileBrowserThumbnailCacheLimitBytes: Int
    var collapsed: Set<String>
    var locale: Locale
    var onRescan: () -> Void
    var onToggle: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage == rhs.storage && lhs.isScanning == rhs.isScanning
            && lhs.isDiskCacheEnabled == rhs.isDiskCacheEnabled
            && lhs.diskCacheLimitBytes == rhs.diskCacheLimitBytes
            && lhs.isFileBrowserThumbnailCacheEnabled == rhs.isFileBrowserThumbnailCacheEnabled
            && lhs.fileBrowserThumbnailCacheLimitBytes == rhs.fileBrowserThumbnailCacheLimitBytes
            && lhs.collapsed == rhs.collapsed
            && lhs.locale == rhs.locale
    }

    /// 内訳の 1 行。
    fileprivate struct Row: Identifiable {
        enum Limit {
            case none
            case limit(Int)
            /// 環境設定で OFF にしてあるキャッシュ。
            case off
        }

        var title: LocalizedStringKey
        var bytes: Int?
        var limit: Limit = .none
        var help: LocalizedStringKey
        var id: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SectionTitle("On Disk")
                Spacer(minLength: 0)
                if let storage {
                    NoteText(Text("\(storage.scannedAt, format: .dateTime.hour().minute().second())"))
                }
                SidePanelNavButton(systemName: "arrow.clockwise", isDisabled: isScanning, help: "Rescan Now") {
                    onRescan()
                }
            }
            if let storage {
                ForEach(ResourceMonitorFolding.StorageGroup.allCases, id: \.self) { group in
                    let key = ResourceMonitorFolding.diskKey(group)
                    let isExpanded = !collapsed.contains(key)
                    let rows = rows(for: group, storage: storage)
                    FoldableGroupHeader(
                        title: group.titleKey,
                        value: optionalSizeText(Self.sum(rows)),
                        isExpanded: isExpanded,
                        onToggle: { onToggle(key) }
                    )
                    if isExpanded {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(rows) { row in
                                rowView(row)
                            }
                        }
                        .padding(.leading, FoldableGroupHeader.contentIndent)
                    }
                }
                DetailRow("Other", optionalSizeText(storage.otherBytes))
                    .help("Everything else in the app’s container, such as saved window state, logs and downloaded updates.")
                Divider()
                DetailRow("Container total", optionalSizeText(storage.containerBytes))
                    .help("Everything the app stores on disk, in ~/Library/Containers.")
            } else {
                NoteText(Text(isScanning ? "Scanning…" : "—"))
            }
        }
    }

    private func rows(for group: ResourceMonitorFolding.StorageGroup, storage: StorageUsage) -> [Row] {
        switch group {
        case .viewer:
            return [
                Row(title: "Thumbnail cache", bytes: storage.thumbnailCacheBytes,
                    limit: isDiskCacheEnabled ? .limit(diskCacheLimitBytes) : .off,
                    help: "Thumbnails of book pages for the progress bar and page lists, so a book you have viewed before shows them without decoding its pages again. Kept under the limit shown, oldest first; you can turn it off or delete it in Settings ▸ Cache.",
                    id: "thumbnails"),
                // ページ一覧・構造・ページ寸法のキャッシュ(BookPageListCache)。サムネイルと同じく
                // 「知らないうちに増える」性格のものなので、上限と並べて見せる(ユーザー要望)。
                Row(title: "Page list cache", bytes: storage.pageListCacheBytes,
                    limit: .limit(BookPageListCache.maxTotalBytes),
                    help: "The order, names and image sizes of the pages of books you have opened, so that a book opens without scanning its archive again. Trimmed to the limit shown once per launch, oldest first; you can delete it in Settings ▸ Cache. Nothing is written for books opened in a private window or kept in a secret folder.",
                    id: "pageLists"),
            ]
        case .library:
            return [
                // コレクションのカバー画像。上の2つと違って**キャッシュではない**(消えると
                // 登録してある本を全冊読み直すことになる)ので、上限は並べずに容量だけ出す。
                Row(title: "Collection covers", bytes: storage.collectionCoverBytes,
                    help: "One small JPEG per book registered in a collection, extracted once when the book is added. Not a cache: deleting it means re-reading every registered book, so there is no size limit and nothing is evicted. It goes away with the collection, the book’s entry, or “Delete All Data”.",
                    id: "covers"),
                // 利用者が指定した表紙の画像の複製。作り直せない(以前は上と 1 つの数だった)。
                Row(title: "Chosen cover images", bytes: storage.collectionCoverSourceBytes,
                    help: "Copies of the images you chose as books’ covers (for collections and export), reduced in size when saved. The original file may already be gone, so they cannot be made again; each is kept until that book’s cover is set back or its saved data is deleted.",
                    id: "coverSources"),
                // 焼いたコレクションのタイル。カバーから作り直せるキャッシュなので、上限と並べて見せる。
                Row(title: "Collection tiles", bytes: storage.collectionTileBytes,
                    limit: .limit(CollectionTileImageStore.maxTotalBytes),
                    help: "One JPEG per collection holding the covers shown on its tile, so Home draws each tile from a single image instead of reading every cover separately. Rebuilt from the collection covers whenever it is missing, and kept under the limit shown, oldest first.",
                    id: "tiles"),
            ]
        case .fileBrowser:
            return [
                // ファイルブラウザ・スマートライブラリ・インスペクタの絵(改善要望7 段階 7a)。ページサムネイルと同じくON/OFFと上限を持つ。
                // まとまり(「ファイルブラウザとスマートライブラリ」)の中なので、ビューアの行と同じ短い名前。
                Row(title: "Thumbnail cache", bytes: storage.fileBrowserThumbnailCacheBytes,
                    limit: isFileBrowserThumbnailCacheEnabled ? .limit(fileBrowserThumbnailCacheLimitBytes) : .off,
                    help: "Pictures of books, images, videos and folders shown in the file browser’s icon view, the smart library and the inspector, so they appear without reading the books again. Videos under Favorite Locations are prepared in advance. Kept under the limit shown, oldest first; you can turn it off or delete it in Settings ▸ Cache.",
                    id: "fileBrowserThumbnails"),
                Row(title: "Smart library list", bytes: storage.smartLibraryCatalogBytes,
                    help: "The last list of books the smart library found in its target folders, so that it can show them at once next time. It is made again whenever the folders are scanned.",
                    id: "smartLibrary"),
            ]
        case .metadata:
            return [
                Row(title: "Metadata rules", bytes: storage.metadataRulesBytes,
                    help: "Your changes to the rules that derive metadata from file names, and copies of a rules file that could not be read.",
                    id: "metadataRules"),
                Row(title: "Metadata book list", bytes: storage.metadataCorpusBytes,
                    help: "The books that collections and the smart library have seen, recorded so that metadata can be derived from their file names even while those features are turned off.",
                    id: "metadataCorpus"),
            ]
        case .savedData:
            return [
                Row(title: "Database", bytes: storage.databaseBytes,
                    help: "Bookmarks, reading positions, page layouts, metadata, libraries and collections (the SwiftData store and its write-ahead log).",
                    id: "database"),
                Row(title: "Settings and History", bytes: storage.preferencesBytes,
                    help: "Settings, history, folder permissions, secret folders and the state of windows (the app’s preferences files).",
                    id: "preferences"),
            ]
        case .temporary:
            var rows = [
                Row(title: "Nested archives", bytes: storage.nestedTemporaryBytes,
                    help: "Archives found inside the books open in this launch that were too large for the “Nested archives kept in memory” setting and had to be written out to be read. Only the ones in use are kept; they are removed as you move on, when the book is closed, and when the app quits.",
                    id: "nested"),
                Row(title: "Network volume copies", bytes: storage.stagedTemporaryBytes,
                    help: "The parts of books on a network volume that have been read, kept locally so they are not fetched again. Only the parts actually read take up space; while a book is open in a viewer, the rest is fetched in the background. They are removed shortly after the book is closed, and when the app quits.",
                    id: "staged"),
            ]
            // 他の起動が残した一時ファイル。起動時に掃除されるので普段は0で、0のときは行を出さない。
            // 0でないときは「異常」にも出るが、内訳の合計が「コンテナ全体」と合うように、
            // 容量そのものもここに載せる(ユーザー要望: このアプリが使っているディスクを正確に
            // 把握できること)。
            if storage.staleTemporaryBytes > 0 {
                rows.append(Row(title: "Leftover temporary files", bytes: storage.staleTemporaryBytes,
                                help: "Temporary files left behind by a previous launch that did not get to clean up (a crash or a forced quit). They are deleted the next time the app starts.",
                                id: "stale"))
            }
            return rows
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 0) {
            DetailRow(row.title, optionalSizeText(row.bytes))
            switch row.limit {
            case .none:
                EmptyView()
            case .limit(let bytes):
                Text(verbatim: " / \(fileSizeText(bytes))")
                    .font(.callout)
                    .monospacedDigit()
                    .fixedSize()
                    .panelOutlinedContent()
            case .off:
                Text(" (off)")
                    .font(.callout)
                    .panelOutlinedContent()
            }
        }
        .lineLimit(1)
        .help(row.help)
    }

    /// まとまりの合計。どの行も測れなかったら nil(「—」)。
    private static func sum(_ rows: [Row]) -> Int? {
        let values = rows.compactMap(\.bytes)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private func fileSizeText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(locale))
    }

    private func optionalSizeText(_ bytes: Int?) -> String {
        bytes.map(fileSizeText) ?? "—"
    }
}

extension ResourceMonitorFolding.StorageGroup {
    var titleKey: LocalizedStringKey {
        switch self {
        case .viewer: return "Viewer"
        case .library: return "Library"
        case .fileBrowser: return "File Browser & Smart Library"
        case .metadata: return "Metadata"
        case .savedData: return "Saved Data"
        case .temporary: return "Temporary files"
        }
    }
}

// MARK: - 異常

private struct AnomaliesSection: View, Equatable {
    var anomalies: [ResourceAnomaly]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Problems")
            if anomalies.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("None detected")
                        .font(.callout)
                }
                .panelOutlinedContent()
            } else {
                ForEach(anomalies) { anomaly in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(anomaly.title)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .panelOutlinedContent()
                    .help(anomaly.detail)
                }
            }
        }
    }
}

// MARK: - 共通の小部品

/// 節の見出し。他のモードの見出し(「履歴」など)と同じ書式。
private struct SectionTitle: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }

    var body: some View {
        Text(key)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .panelOutlinedContent()
    }
}

/// 項目名と数値の1行。どちらも通常の文字色。
private struct DetailRow: View {
    let title: Text
    let value: String
    init(_ key: LocalizedStringKey, _ value: String) {
        self.title = Text(key)
        self.value = value
    }

    /// 名前が組み立てた `Text`(本の名前など)のとき。
    init(_ title: Text, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(spacing: 6) {
            title
                .font(.callout)
            Spacer(minLength: 0)
            Text(value)
                .font(.callout)
                .monospacedDigit()
                // 数値は切らない(狭いパネルでは名前のほうを省略する)。
                .fixedSize()
        }
        .lineLimit(1)
        .panelOutlinedContent()
    }
}

/// 補足の文字(最大値・設定値・走査時刻など)。節の見出しと同じグレー。
private struct NoteText: View {
    let text: Text
    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .panelOutlinedContent()
    }
}
