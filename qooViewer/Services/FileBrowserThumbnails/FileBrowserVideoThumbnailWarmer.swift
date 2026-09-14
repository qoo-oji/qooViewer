import Combine
import Foundation

/// ファイルブラウザの「よく使う項目」の中(サブフォルダも全部)にある**動画の絵を、起動している間に裏で先に作っておく**
/// (改善要望7 段階 7b、2026-09-14。qooLibrary の `BackgroundThumbnailWarmer` を写したもの)。アプリで 1 つ(AppStores)。
///
/// 動画の絵は QuickLook に頼むので 1 本あたりが本より重く、アイコン表示を開いてから作ると並ぶまで待たされる。
/// 作ったものは提供役(FileBrowserThumbnailProvider)と同じディスクキャッシュに入り、セルはそれを読むだけになる。
///
/// ■ いつ動くか
/// 起動時、よく使う項目が変わったとき、環境設定「動画のサムネイルを作る」かディスクキャッシュを ON にしたとき
/// (`update(roots:isEnabled:)`。合図が続けて来ても 2 秒待ってから 1 回だけ回る)。どちらかを OFF にしたら止める。
/// ディスクキャッシュが OFF だと作っても捨てるだけなので動かない。起動している間だけ(常駐はしない)。
/// 回っている間に増えた動画は、次に回るまで(またはアイコン表示で見えるまで)作らない。
///
/// ■ 控えめに
/// **1 本ずつ**・`.background` の Task・借りるスレッドは `.utility`。アイコン表示の頼み(同時 4 件)とは別に走り、
/// 同時に使うのは最大 1 本ぶん。作り済み(ディスクキャッシュにある)ものは JPEG を読まずに飛ばす。
///
/// ■ 形式ごとに諦める(この起動の間だけ)
/// 同じ拡張子が **1 度も成功しないまま 3 回失敗**したら、その拡張子はこの起動では試さない(作れる QuickLook 拡張が
/// 無い mkv が数百本並んでいても、1 本 8 秒の待ちを繰り返さない)。**覚えておかない** ―― 拡張があるかを尋ねる公開 API は
/// 無いので、「次の起動でまた試す」ことが「拡張を入れたら出るようになる」のいちばん確かな形になる(qooLibrary と同じ判断)。
///
/// ■ 辿らないところ
/// - ネットワーク越しのボリューム(ファイルを丸ごと読むので、共有への読み取りがいちばん増える)。よく使う項目そのものが
///   そうなら丸ごと、途中にマウントされたボリュームがあればその下
/// - TCC の保護下の場所(ホームを登録していても「デスクトップ」「書類」の中は読まない ―― 利用者が入ってもいないのに
///   許可のダイアログが出る)。**よく使う項目そのものが保護下の場所の中にあれば、同じ場所の中は辿る**(許可は済んでいる)
/// - 隠しファイル・隠しフォルダ(`~/Library` を含む)・パッケージの中・記号リンクの先
/// - 実体が手元に無いファイル(頼まれていないダウンロードを起こさない。失敗としても数えない)
@MainActor
final class FileBrowserVideoThumbnailWarmer {
    /// 同じ拡張子で、1 度も成功しないまま何回失敗したら諦めるか。
    nonisolated static let formatFailureThreshold = 3
    nonisolated static let restartDebounce: Duration = .seconds(2)

    /// 1 回の掃引に要るもの。掃引はメインアクターの外で走るので、Sendable な値で渡す。
    nonisolated struct Dependencies: Sendable {
        let diskCache: FileBrowserThumbnailDiskCache
        let loader: any VideoThumbnailLoading
        let isRemote: @Sendable (URL) -> Bool
        let isDataless: @Sendable (URL) -> Bool
        let protectedPrefixes: [String]
        let formatFailureThreshold: Int

        static func live(diskCache: FileBrowserThumbnailDiskCache = .shared) -> Dependencies {
            Dependencies(
                diskCache: diskCache,
                loader: CompositeVideoThumbnailLoader(),
                isRemote: { MountTable.current().isRemote($0) },
                isDataless: { VideoThumbnailer.isDataless($0) },
                protectedPrefixes: DirectoryProbe.protectedPrefixes,
                formatFailureThreshold: FileBrowserVideoThumbnailWarmer.formatFailureThreshold
            )
        }
    }

    /// 1 回の掃引の結果(**テストのための口**。ログにも使う)。
    nonisolated struct SweepReport: Sendable, Equatable {
        var generated: [URL] = []
        var failed: [URL] = []
        var skippedExtensions: Set<String> = []
    }

    private let dependencies: Dependencies
    private let debounce: Duration
    private var roots: [URL] = []
    private var isEnabled = false
    private var sweepTask: Task<Void, Never>?
    private(set) var lastReport: SweepReport?
    private var subscription: AnyCancellable?

    init(dependencies: Dependencies, debounce: Duration = FileBrowserVideoThumbnailWarmer.restartDebounce) {
        self.dependencies = dependencies
        self.debounce = debounce
    }

    /// よく使う項目と環境設定の変化を受け取って動かす(AppStores が 1 度だけ呼ぶ)。
    /// **テストの中の実物のアプリでは呼ばない**(開発機の本物のよく使う項目を読み、本物のキャッシュに書いてしまう)。
    func connect(favorites: FavoriteLocationStore, preferences: AppPreferences) {
        subscription = favorites.$items
            .combineLatest(preferences.$fileBrowserVideoThumbnailsEnabled, preferences.$fileBrowserThumbnailCacheEnabled)
            .sink { [weak self] items, videoEnabled, cacheEnabled in
                MainActor.assumeIsolated {
                    self?.update(roots: items.map(\.url), isEnabled: videoEnabled && cacheEnabled)
                }
            }
    }

    /// 対象と ON/OFF を渡す。変わっていなければ何もしない。変わっていれば止めて、ON なら(待ってから)回し直す。
    func update(roots newRoots: [URL], isEnabled newIsEnabled: Bool) {
        guard newRoots != roots || newIsEnabled != isEnabled || sweepTask == nil else { return }
        roots = newRoots
        isEnabled = newIsEnabled
        restart()
    }

    /// 回し直す(走っている掃引は止める)。
    func restart() {
        sweepTask?.cancel()
        guard isEnabled, !roots.isEmpty else {
            sweepTask = nil
            return
        }
        let roots = self.roots
        let dependencies = self.dependencies
        let debounce = self.debounce
        sweepTask = Task(priority: .background) { [weak self] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else { return }
            let report = await Self.sweep(roots: roots, dependencies: dependencies)
            guard !Task.isCancelled else { return }
            self?.lastReport = report
        }
    }

    func stop() {
        sweepTask?.cancel()
    }

    /// いまの(止めたものを含む)掃引が降りるまで待つ(**テストのための口**)。
    func awaitCurrentSweep() async {
        await sweepTask?.value
    }

    // MARK: - 掃引(メインアクターの外)

    @concurrent nonisolated static func sweep(roots: [URL], dependencies: Dependencies) async -> SweepReport {
        var report = SweepReport()
        var failuresByExtension: [String: Int] = [:]
        var succeededExtensions: Set<String> = []
        // よく使う項目が入れ子になっていても 1 本を 2 回見ない。
        var seen: Set<String> = []

        for root in roots {
            if Task.isCancelled { return report }
            if dependencies.isRemote(root) { continue }
            let prefixes = dependencies.protectedPrefixes
            let isRemote = dependencies.isRemote
            let videos = await FileIO.perform(qos: .utility) {
                videoFiles(under: root, protectedPrefixes: prefixes, isRemote: isRemote)
            }
            for video in videos {
                if Task.isCancelled { return report }
                guard seen.insert(video.path).inserted else { continue }
                let ext = video.pathExtension.lowercased()
                if report.skippedExtensions.contains(ext) { continue }
                let isDataless = dependencies.isDataless
                let (key, dataless) = await FileIO.perform(qos: .utility) {
                    (FileBrowserThumbnailKey.of(video, mountTable: MountTable.current()), isDataless(video))
                }
                // 追い出されたファイルは、失敗としても数えない(数えると形式ごとの諦めを誤って引き起こす)。
                guard !dataless, let key else { continue }
                if await dependencies.diskCache.contains(key) { continue }
                // 途中でディスクキャッシュが OFF になったら、作っても捨てるだけなのでやめる。
                guard await dependencies.diskCache.isEnabled else { return report }

                if let jpeg = await FileBrowserThumbnailProvider.videoThumbnailJPEG(of: video, loader: dependencies.loader) {
                    await dependencies.diskCache.store(jpeg, for: key)
                    report.generated.append(video)
                    succeededExtensions.insert(ext)
                } else {
                    report.failed.append(video)
                    failuresByExtension[ext, default: 0] += 1
                    if !succeededExtensions.contains(ext),
                       failuresByExtension[ext, default: 0] >= dependencies.formatFailureThreshold {
                        report.skippedExtensions.insert(ext)
                    }
                }
            }
        }
        return report
    }

    /// `root` の下の動画ファイル(並びはパスの自然順)。**ブロッキングするので FileIO の上で呼ぶ。**
    /// 辿らないところは型コメント。
    nonisolated static func videoFiles(
        under root: URL, protectedPrefixes: [String], isRemote: (URL) -> Bool
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let rootPrefix = DirectoryProbe.protectedPrefix(containing: root, prefixes: protectedPrefixes)
        // 拡張子ごとの判定(UTType の問い合わせ)を 1 回にする。
        var isVideoByExtension: [String: Bool] = [:]
        var results: [URL] = []
        for case let url as URL in enumerator {
            if Cancellation.isRequestedInCurrentScope { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                let prefix = DirectoryProbe.protectedPrefix(containing: url, prefixes: protectedPrefixes)
                if (prefix != nil && prefix != rootPrefix) || isRemote(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let isVideo = isVideoByExtension[ext] ?? {
                let answer = VideoThumbnailer.isVideoFile(url.lastPathComponent)
                isVideoByExtension[ext] = answer
                return answer
            }()
            if isVideo { results.append(url) }
        }
        results.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return results
    }
}
