import SwiftUI
import SwiftData

/// サイドパネルの「リソース」モード。このアプリ(プロセス)のCPU・メモリ・ディスクI/Oの推移と、
/// 開いている本のメモリキャッシュ、コンテナのディスク使用量、そして検出した異常を1列に
/// 並べる(ユーザー要望: v1.29で直した種類のリソースの過剰消費を、ユーザー自身がひと目で
/// 把握できるようにする)。
///
/// ■ 3つの更新周期
/// - グラフ: `ProcessResourceSampler`(アプリに1つ)が計測中だけ1秒ごとに伸ばす。ON/OFFは
///   上部のトグル。計測していなくても現在値(`latest`)は出す(サンプラーのコメント参照)。
/// - この本のキャッシュ・現在値の更新: この節が表示されている間だけ、1秒ごとに
///   `fetchBookSnapshot`(AppState経由でViewerViewModelへ)と`refreshLatest()`を呼ぶ。
///   このループは長寿命の`.task`で回るため、`fetchBookSnapshot`は**呼ばれた時点のAppStateを
///   引き直す**クロージャでなければならない(ContentView側のコメント参照)。本を切り替えても
///   ループは張り直されないので、渡されたクロージャ自体が古い本を指していると固まる。
/// - ディスクの走査: この節が表示されている間だけ、15秒ごと+「今すぐ更新」。ディレクトリの
///   全走査を伴うため、上の2つより粗い周期にしてある(`StorageUsageScanner`参照)。
///
/// ■ 再描画のコスト(実測に基づく)
/// 最初は1つのbodyに全節を書いていたが、1秒ごとの更新でパネル全体が再描画され、
/// 表示中のCPUが3〜5%に達した(計測そのものは0.0%)。そこで節ごとに**値型の入力だけを
/// 持つEquatableな子ビュー**へ分け、`.equatable()`で「入力が変わっていなければbodyを
/// 評価しない」ようにしてある。ディスクの節は15秒に1回しか変わらず、本の節は本が
/// 動いていなければ変わらないので、毎秒描き直すのはグラフの節だけで済む。
///
/// ■ 文字色
/// 項目名と数値はどちらも通常の文字色(callout)。グレー(secondary)にするのは節の見出しと、
/// 数値に添える補足(`NoteText`: 最大値・設定値・走査時刻・冊数)だけ(ユーザー指摘:
/// 行ごとに項目名がグレーだったり数値がグレーだったりすると統一感が無い)。
///
/// ■ 「文字の影」
/// 文字・アイコンは`panelOutlinedContent()`、グラフは自前の地を持つ枠(`ResourceGraphView`
/// 参照)、使用率バー・先読みの帯・ON中のトグルの塗りは`panelOutlinedAccent`。
struct SidePanelResourcesSectionView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var sampler: ProcessResourceSampler

    /// このウインドウで開いている本のキャッシュの状態を取る橋渡し(AppState.fetchResourceSnapshot)。
    /// 本を開いていなければ、呼んだ結果がnilになる(クロージャ自体はContentViewが常に渡す)。
    var fetchBookSnapshot: (() async -> ResourceMonitorSnapshot?)?

    @State private var bookSnapshot: ResourceMonitorSnapshot?
    @State private var openBookCount = 0
    @State private var storage: StorageUsage?
    @State private var isScanningStorage = false
    @State private var anomalies: [ResourceAnomaly] = []
    @State private var detector = ResourceAnomalyDetector()
    /// グラフの時間幅。falseなら直近2分(1秒刻み)、trueなら直近1時間(10秒平均)。
    @State private var showsLongRange = false
    /// 走査を今すぐやり直す合図(「今すぐ更新」ボタン)。値が変わるたびに`.task(id:)`が走り直す。
    @State private var storageScanRequest = 0

    private static let storageScanInterval: TimeInterval = 15

    var body: some View {
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
                        bookCacheBytes: bookSnapshot?.totalCacheBytes,
                        locale: preferences.effectiveLocale
                    )
                    .equatable()
                    if let bookSnapshot {
                        BookMemorySection(
                            snapshot: bookSnapshot,
                            openBookCount: openBookCount,
                            locale: preferences.effectiveLocale
                        )
                        .equatable()
                    }
                    StorageSection(
                        storage: storage,
                        isScanning: isScanningStorage,
                        isDiskCacheEnabled: preferences.thumbnailDiskCacheEnabled,
                        diskCacheLimitBytes: Int(preferences.thumbnailDiskCacheLimitMB) * 1024 * 1024,
                        locale: preferences.effectiveLocale,
                        onRescan: { storageScanRequest &+= 1 }
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
    }

    // MARK: - 更新ループ

    /// この節が表示されている間、1秒ごとに「この本のキャッシュ」と現在値を取り直し、異常を
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
        guard !Task.isCancelled else { return }
        if snapshot != bookSnapshot { bookSnapshot = snapshot }
        let count = ViewerViewModel.openBookCount
        if count != openBookCount { openBookCount = count }
        evaluateAnomalies()
    }

    private func evaluateAnomalies() {
        let found = detector.evaluate(.init(
            bookSnapshot: bookSnapshot,
            storage: storage,
            isDiskCacheEnabled: preferences.thumbnailDiskCacheEnabled,
            diskCacheLimitBytes: Int(preferences.thumbnailDiskCacheLimitMB) * 1024 * 1024,
            openBookCount: ViewerViewModel.openBookCount
        ))
        if found != anomalies { anomalies = found }
    }

    /// 15秒ごとにコンテナを走査する。「今すぐ更新」で`storageScanRequest`が変わるとループが
    /// 張り直され、即座に1回走る。
    private func storageScanLoop() async {
        while !Task.isCancelled {
            await scanStorage()
            try? await Task.sleep(for: .seconds(Self.storageScanInterval))
        }
    }

    /// 走査の世代。「今すぐ更新」で`.task(id:)`が張り直されると古い走査は取り消されるが、
    /// その`defer`が新しい走査の最中に`isScanningStorage = false`を書いてボタンを早く
    /// 有効にしてしまわないよう、自分が最新の世代であるときだけ状態を戻す(監査で指摘)。
    @State private var storageScanGeneration = 0

    private func scanStorage() async {
        storageScanGeneration &+= 1
        let generation = storageScanGeneration
        isScanningStorage = true
        defer { if generation == storageScanGeneration { isScanningStorage = false } }
        let locations = StorageUsageScanner.Locations(
            containerRoot: FileManager.default.homeDirectoryForCurrentUser,
            sessionTemporaryDirectory: TemporaryFileStore.sessionDirectory,
            temporaryRoot: FileManager.default.temporaryDirectory,
            thumbnailCacheDirectory: ThumbnailDiskCache.shared.directory,
            databaseStoreURL: QooViewerApp.modelConfiguration.url
        )
        // Task.detachedはキャンセルを継承しないので、この`.task`が取り消されたら走査側の
        // タスクも明示的に取り消す。走査はディレクトリの列挙中にTask.isCancelledを見て
        // 途中で打ち切る(StorageUsageScanner参照)ため、古い走査と新しい走査が丸ごと
        // 並走することはない。
        let scanTask = Task.detached(priority: .utility) {
            StorageUsageScanner.scan(locations)
        }
        let result = await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
        guard !Task.isCancelled, let result else { return }
        storage = result
        evaluateAnomalies()
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
    /// この本のキャッシュの実使用量の合計(「説明のつかないメモリ」の計算用)。本が無ければnil。
    var bookCacheBytes: Int?
    var locale: Locale

    private static let graphHeight: CGFloat = 56

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.samples == rhs.samples && lhs.capacity == rhs.capacity
            && lhs.showsLongRange == rhs.showsLongRange && lhs.latest == rhs.latest
            && lhs.latestSample == rhs.latestSample && lhs.isRecording == rhs.isRecording
            && lhs.bookCacheBytes == rhs.bookCacheBytes && lhs.locale == rhs.locale
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
            if let bookCacheBytes {
                // 「説明のつかないメモリ」(ユーザー要望: 警告にはせず数値だけ出す)。
                // footprintから、この本のキャッシュの実使用量を引いた残り。本が複数開いて
                // いればそのぶんは含まれる(この節が見ているのはこのウインドウの本だけ)。
                //
                // footprintは圧縮済みのメモリを圧縮後の大きさで数えるため、中身が単調な
                // 画像(ベタ塗りのテストページなど)ではキャッシュの帳簿より小さくなりうる。
                // その場合は引き算に意味が無いので「—」にする。
                let other = footprint - bookCacheBytes
                DetailRow("Outside this book’s caches", other >= 0 ? memoryText(other) : "—")
                    .help("Memory not accounted for by the page-image and thumbnail caches of the book in this window. Includes the app itself, other open books, and anything waiting to be returned to the system. Shown as — when the system has compressed the caches below their nominal size.")
            }
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

    private func usageCountText(
        _ usage: ResourceMonitorSnapshot.CacheUsage, countsPages: Bool
    ) -> LocalizedStringKey {
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

    private func fileSizeText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(locale))
    }

    private func rateText(_ bytesPerSecond: Double) -> String {
        fileSizeText(Int(bytesPerSecond)) + "/s"
    }
}

// MARK: - この本のメモリ

private struct BookMemorySection: View, Equatable {
    var snapshot: ResourceMonitorSnapshot
    var openBookCount: Int
    var locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionTitle("This Book")
                Spacer(minLength: 0)
                NoteText(Text("\(openBookCount) open"))
                    .help("Books open across all windows and tabs. The limits below apply to each book separately.")
            }

            usageBar(
                title: "Page images",
                usage: snapshot.pageImages,
                countsPages: true,
                help: "Decoded page images kept in memory, against the “Page images kept in memory” setting."
            )
            preloadRow
            alreadyReadRow
            usageBar(
                title: "Thumbnails",
                usage: snapshot.thumbnails,
                help: "Thumbnails for the progress bar and page lists, against their built-in limit."
            )
            usageBar(
                title: "Enlarged thumbnails",
                usage: snapshot.gridThumbnails,
                help: "Larger thumbnails for the page list grid and hover previews, against their built-in limit."
            )
            // 入れ子の書庫が無い本(ほとんどの本)では、常に0の行が並ぶだけなので出さない。
            if snapshot.nestedArchives.count > 0 || snapshot.nestedArchiveTemporaryBytes > 0 {
                usageBar(
                    title: "Nested archives",
                    usage: snapshot.nestedArchives,
                    help: "Archives found inside this book that are open right now, against the “Nested archives kept in memory” setting. The count includes every format, but the size covers only ZIP archives — RAR and 7z have to be held as temporary files instead, which appear under On Disk ▸ Temporary files."
                )
            }
        }
    }

    /// - Parameter countsPages: 末尾の件数に「ページ」を付けるか。ページ画像だけtrueにする
    ///   (ユーザー要望)。この行の件数は先読み・過去のページの2行が数えている対象そのもので、
    ///   単位があったほうが手前のMBの数字と区別しやすい。サムネイルの2行は枚数のまま。
    private func usageBar(
        title: LocalizedStringKey,
        usage: ResourceMonitorSnapshot.CacheUsage,
        countsPages: Bool = false,
        help: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.callout)
                Spacer(minLength: 0)
                Text(usageCountText(usage, countsPages: countsPages))
                    .font(.callout)
                    .monospacedDigit()
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

    private func usageCountText(
        _ usage: ResourceMonitorSnapshot.CacheUsage, countsPages: Bool
    ) -> LocalizedStringKey {
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

// MARK: - ディスク

private struct StorageSection: View, Equatable {
    var storage: StorageUsage?
    var isScanning: Bool
    var isDiskCacheEnabled: Bool
    var diskCacheLimitBytes: Int
    var locale: Locale
    var onRescan: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage == rhs.storage && lhs.isScanning == rhs.isScanning
            && lhs.isDiskCacheEnabled == rhs.isDiskCacheEnabled
            && lhs.diskCacheLimitBytes == rhs.diskCacheLimitBytes && lhs.locale == rhs.locale
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
                DetailRow("Temporary files", fileSizeText(storage.sessionTemporaryBytes))
                    .help("Archives found inside the books open in this launch that had to be written out to be read — RAR and 7z only, since ZIP is read directly from memory. Only the ones in use are kept; they are removed as you move on, when the book is closed, and when the app quits.")
                HStack(spacing: 0) {
                    DetailRow("Thumbnail cache", optionalSizeText(storage.thumbnailCacheBytes))
                    Group {
                        if isDiskCacheEnabled {
                            Text(" / \(fileSizeText(diskCacheLimitBytes))")
                        } else {
                            Text(" (off)")
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                    .panelOutlinedContent()
                }
                .lineLimit(1)
                DetailRow("Database", optionalSizeText(storage.databaseBytes))
                    .help("Favorites, bookmarks, reading positions, page layouts, and metadata (the SwiftData store and its write-ahead log).")
                DetailRow("Other", optionalSizeText(storage.otherBytes))
                    .help("Everything else in the app’s container: preferences, saved window state, logs.")
                Divider()
                DetailRow("Container total", optionalSizeText(storage.containerBytes))
                    .help("Everything the app stores on disk, in ~/Library/Containers.")
            } else {
                NoteText(Text(isScanning ? "Scanning…" : "—"))
            }
        }
    }

    private func fileSizeText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(locale))
    }

    private func optionalSizeText(_ bytes: Int?) -> String {
        bytes.map(fileSizeText) ?? "—"
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
    let key: LocalizedStringKey
    let value: String
    init(_ key: LocalizedStringKey, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.callout)
            Spacer(minLength: 0)
            Text(value)
                .font(.callout)
                .monospacedDigit()
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
