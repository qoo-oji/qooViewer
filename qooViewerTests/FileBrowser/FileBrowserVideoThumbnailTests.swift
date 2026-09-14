import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import qooViewer

/// ファイルブラウザの動画の絵(段階 7b。Services/FileBrowserThumbnails/)。
///
/// 実物の作り方(QuickLook・VideoToolbox)は、結果が入っている QuickLook 拡張と実物の動画に左右されるので自動テストの
/// 対象にしない(qooLibrary と同じ方針。実機で確かめる)。ここで固定するのは、形式の見分け方・寸法の読み方・作り方の
/// 並び・提供役と先に作る役の決まりごと。作り方は作り物(`ScriptedVideoLoader`)に差し替える。
///
/// **拡張子は必ず mp4 を使う。** mkv の `.movie` への準拠は、mkv を扱うアプリが入っているかで変わる(qooLibrary の CI で落ちた)。
@MainActor
struct FileBrowserVideoThumbnailTests {
    // MARK: - 形式の見分け方

    /// qooLibrary の実機の蔵書にあった、`.mp4` を名乗る Matroska の先頭 32 バイト。
    private static let realMatroskaHeader: [UInt8] = [
        0x1A, 0x45, 0xDF, 0xA3, 0xA3, 0x42, 0x86, 0x81,
        0x01, 0x42, 0xF7, 0x81, 0x01, 0x42, 0xF2, 0x81,
        0x04, 0x42, 0xF3, 0x81, 0x08, 0x42, 0x82, 0x88,
        0x6D, 0x61, 0x74, 0x72, 0x6F, 0x73, 0x6B, 0x61,
    ]

    /// 同じく、健全な mp4 の先頭 16 バイト。
    private static let realISOBMFFHeader: [UInt8] = [
        0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70,
        0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x02, 0x00,
    ]

    @Test("先頭バイト列でコンテナを見分ける。RIFF の音声を AVI と取り違えない")
    func sniffsContainers() {
        #expect(MediaContainerSniffer.sniff(Self.realMatroskaHeader) == .matroska)
        #expect(MediaContainerSniffer.sniff(Self.realISOBMFFHeader) == .isoBMFF)
        #expect(MediaContainerSniffer.sniff(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("AVI ".utf8)) == .avi)
        #expect(MediaContainerSniffer.sniff(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)) == nil)
        #expect(MediaContainerSniffer.sniff([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66]) == .asf)
        #expect(MediaContainerSniffer.sniff(Array("FLV".utf8) + [0x01]) == .flv)
    }

    @Test("短すぎる・無関係なバイト列では nil", arguments: [
        [UInt8](), [0x1A, 0x45, 0xDF], Array("RIFF".utf8), [0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79],
        Array("hello, this is not a video".utf8),
    ])
    func sniffRejectsTruncatedBytes(_ bytes: [UInt8]) {
        #expect(MediaContainerSniffer.sniff(bytes) == nil)
    }

    @Test("拡張子が実体と合っていれば宣言し直さない。食い違えばシステムの具体的な型を宣言する")
    func declaresContentTypeOnlyOnMismatch() throws {
        #expect(MediaContainer.matroska.contentTypeToDeclare(forFileNamed: "a.MKV") == nil)
        #expect(MediaContainer.isoBMFF.contentTypeToDeclare(forFileNamed: "a.mov") == nil)
        // 実体は mp4 なのに .mkv を名乗る(mp4 の型は OS の標準なので、どの機でも引ける)。
        let declared = MediaContainer.isoBMFF.contentTypeToDeclare(forFileNamed: "video.mkv")
        #expect(declared == (try #require(UTType(filenameExtension: "mp4"))))
        #expect(MediaContainer.isoBMFF.contentTypeToDeclare(forFileNamed: "video")?.identifier == "public.mpeg-4")
    }

    @Test("未知の拡張子は dyn. の型になるが、動画ではないので宣言しない")
    func doesNotDeclareDynamicTypes() throws {
        let synthesized = try #require(UTType(filenameExtension: "zzzznotarealextension"))
        #expect(synthesized.identifier.hasPrefix("dyn."))
        #expect(MediaContainer.concreteMovieType(forExtension: "zzzznotarealextension") == nil)
        #expect(MediaContainer.concreteMovieType(forExtension: "mp4")?.identifier == "public.mpeg-4")
    }

    @Test("ファイルの先頭を読んで見分ける。無い・空のファイルは nil")
    func sniffsFiles() throws {
        let temporary = try TemporaryDirectory("video-sniff")
        let misnamed = temporary.file("misnamed.mp4")
        try Data(Self.realMatroskaHeader).write(to: misnamed)
        #expect(MediaContainerSniffer.sniff(fileAt: misnamed) == .matroska)
        let empty = temporary.file("empty.mp4")
        try Data().write(to: empty)
        #expect(MediaContainerSniffer.sniff(fileAt: empty) == nil)
        #expect(MediaContainerSniffer.sniff(fileAt: temporary.file("missing.mp4")) == nil)
    }

    // MARK: - Matroska の寸法

    /// EBML の構造だけを手で組んだ最小の mkv(`EBML header > Segment(大きさ不明) > Tracks > TrackEntry > Video`)。
    private static func minimalMatroska(width: UInt16, height: UInt16, trackType: UInt8 = 1) -> [UInt8] {
        let pixels: [UInt8] = [0xB0, 0x82, UInt8(width >> 8), UInt8(width & 0xFF),
                               0xBA, 0x82, UInt8(height >> 8), UInt8(height & 0xFF)]
        let video: [UInt8] = trackType == 1 ? [0xE0, 0x80 | UInt8(pixels.count)] + pixels : []
        let entryContent: [UInt8] = [0x83, 0x81, trackType] + video
        let entry: [UInt8] = [0xAE, 0x80 | UInt8(entryContent.count)] + entryContent
        let tracks: [UInt8] = [0x16, 0x54, 0xAE, 0x6B, 0x80 | UInt8(entry.count)] + entry
        return [0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x01, 0x02, 0x03, 0x04] + [0x18, 0x53, 0x80, 0x67, 0xFF] + tracks
    }

    @Test("Matroska の映像トラックの寸法を読む")
    func readsMatroskaDimensions() throws {
        #expect(MatroskaDimensionReader.dimensions(in: Self.minimalMatroska(width: 1920, height: 1080)) == CGSize(width: 1920, height: 1080))
        #expect(MatroskaDimensionReader.dimensions(in: Self.minimalMatroska(width: 1980, height: 808)) == CGSize(width: 1980, height: 808))
        let temporary = try TemporaryDirectory("video-mkv")
        let url = temporary.file("fixture.mkv")
        try Data(Self.minimalMatroska(width: 640, height: 480)).write(to: url)
        #expect(MatroskaDimensionReader.dimensions(of: url) == CGSize(width: 640, height: 480))
    }

    @Test("mkv でない・映像トラックが無い・途中で切れている・大きさが巨大な細工では nil(落ちない)")
    func rejectsBrokenMatroska() {
        #expect(MatroskaDimensionReader.dimensions(in: Array("plain text, not an mkv".utf8)) == nil)
        #expect(MatroskaDimensionReader.dimensions(in: Self.minimalMatroska(width: 1, height: 1, trackType: 2)) == nil)
        #expect(MatroskaDimensionReader.dimensions(in: [0x1A, 0x45, 0xDF, 0xA3, 0x84]) == nil)
        // EBML ヘッダの大きさに 8 バイトの最大値(大きさ不明ではない 0x00FF…FE)を書く。足し算が溢れても落ちないこと。
        let huge: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 0x00]
        #expect(MatroskaDimensionReader.dimensions(in: huge) == nil)
        let hugeSegment: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x80] + [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE]
            + [0x16, 0x54, 0xAE, 0x6B, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE]
        #expect(MatroskaDimensionReader.dimensions(in: hugeSegment) == nil)
    }

    // MARK: - 作り方の並び

    @Test("最初にできた作り方で止まる。できなければ次を試す。既定は QuickLook → 再タグ付け")
    func compositeOrder() async {
        let url = URL(fileURLWithPath: "/nonexistent/clip.mp4")
        let first = ScriptedVideoLoader { _ in nil }
        let second = ScriptedVideoLoader { _ in PageImageFactory.cgImage(number: 3) }
        let third = ScriptedVideoLoader { _ in PageImageFactory.cgImage(number: 4) }
        let image = await CompositeVideoThumbnailLoader(loaders: [first, second, third]).makeThumbnail(for: url, maxPixelSize: 64)
        #expect(image.flatMap { PageColorReader.number(in: $0) } == 3)
        #expect(first.calls.count == 1)
        #expect(second.calls.count == 1)
        #expect(third.calls.isEmpty)

        let loaders = CompositeVideoThumbnailLoader().loaders
        #expect(loaders.count == 2)
        #expect(loaders.first is QuickLookVideoThumbnailLoader)
        #expect(loaders.last is RetaggedHEVCThumbnailLoader)
    }

    // MARK: - 種類

    @Test("動画は名前で決まり、環境設定が OFF なら対象にしない")
    func videoKind() {
        #expect(BookThumbnailer.kind(forName: "clip.mp4", isNavigableFolder: false, isPackage: false, isSymbolicLink: false) == .video)
        #expect(BookThumbnailer.kind(forName: "clip.MOV", isNavigableFolder: false, isPackage: false, isSymbolicLink: false) == .video)
        #expect(BookThumbnailer.kind(
            forName: "clip.mp4", isNavigableFolder: false, isPackage: false, isSymbolicLink: false, includesVideo: false
        ) == nil)
        #expect(BookThumbnailer.kind(forName: "clip.mp4", isNavigableFolder: false, isPackage: false, isSymbolicLink: true) == nil)
        #expect(VideoThumbnailer.isVideoFile("song.mp3") == false)
        #expect(VideoThumbnailer.isVideoFile("noextension") == false)
        #expect(BookThumbnailer.thumbnail(of: URL(fileURLWithPath: "/nonexistent/clip.mp4"), kind: .video, maxPixelSize: 64) == nil)
    }

    // MARK: - 提供役

    private func entry(named name: String, in folder: URL) throws -> FileBrowserEntry {
        try #require(FileBrowserListing.entries(in: folder).first { $0.url.lastPathComponent == name })
    }

    @Test("提供役: 動画の絵を作ってディスクに入れ、別の提供役はディスクから読む。作れなければ覚える")
    func providerMakesVideoThumbnails() async throws {
        let temporary = try TemporaryDirectory("video-provider")
        let folder = try temporary.directory("shelf")
        try Data("not real video bytes".utf8).write(to: folder.appendingPathComponent("ok.mp4"))
        try Data("not real video bytes either".utf8).write(to: folder.appendingPathComponent("broken.mp4"))
        let disk = FileBrowserThumbnailDiskCache(directory: temporary.file("cache"))
        let loader = ScriptedVideoLoader { url in
            url.lastPathComponent == "ok.mp4" ? PageImageFactory.cgImage(number: 6) : nil
        }

        let provider = FileBrowserThumbnailProvider(diskCache: disk, videoLoader: loader)
        let made = try #require(await provider.thumbnail(for: try entry(named: "ok.mp4", in: folder), kind: .video, pixelSize: 128))
        #expect(abs((PageColorReader.number(in: try #require(made.makeImage())) ?? 0) - 6) <= 2)
        #expect(await provider.thumbnail(for: try entry(named: "broken.mp4", in: folder), kind: .video, pixelSize: 128) == nil)
        #expect(await provider.thumbnail(for: try entry(named: "broken.mp4", in: folder), kind: .video, pixelSize: 256) == nil)
        #expect(loader.calls.map(\.lastPathComponent) == ["ok.mp4", "broken.mp4"])

        let another = FileBrowserThumbnailProvider(diskCache: disk, videoLoader: loader)
        #expect(await another.thumbnail(for: try entry(named: "ok.mp4", in: folder), kind: .video, pixelSize: 256) != nil)
        #expect(another.generatedCount == 0)
        #expect(loader.calls.count == 2)
    }

    @Test("提供役: 環境設定の「動画のサムネイルを生成」を写す")
    func providerFollowsPreference() throws {
        let suite = PreferencesSuite()
        let preferences = suite.makePreferences()
        let temporary = try TemporaryDirectory("video-pref")
        let provider = FileBrowserThumbnailProvider(diskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")))
        provider.connect(preferences: preferences)
        #expect(provider.includesVideo)
        preferences.fileBrowserVideoThumbnailsEnabled = false
        #expect(!provider.includesVideo)
    }

    // MARK: - 先に作る役

    private struct WarmerFixture {
        let temporary: TemporaryDirectory
        let root: URL
        let disk: FileBrowserThumbnailDiskCache
        let loader: ScriptedVideoLoader

        @MainActor
        func warmer(
            protectedPrefixes: [String] = [], isRemote: @escaping @Sendable (URL) -> Bool = { _ in false },
            isDataless: @escaping @Sendable (URL) -> Bool = { _ in false }
        ) -> FileBrowserVideoThumbnailWarmer {
            FileBrowserVideoThumbnailWarmer(
                dependencies: .init(
                    diskCache: disk, loader: loader, isRemote: isRemote, isDataless: isDataless,
                    protectedPrefixes: protectedPrefixes, formatFailureThreshold: 3
                ),
                debounce: .zero
            )
        }

        @discardableResult
        func video(_ relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not real video bytes \(relativePath)".utf8).write(to: url)
            return url
        }
    }

    private func warmerFixture(_ label: String, result: @escaping @Sendable (URL) -> CGImage? = { _ in
        PageImageFactory.cgImage(number: 1)
    }) throws -> WarmerFixture {
        let temporary = try TemporaryDirectory(label)
        let root = try temporary.directory("favorite")
        return WarmerFixture(
            temporary: temporary, root: root, disk: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")),
            loader: ScriptedVideoLoader(result)
        )
    }

    private func sweep(_ warmer: FileBrowserVideoThumbnailWarmer, roots: [URL]) async -> FileBrowserVideoThumbnailWarmer.SweepReport? {
        warmer.update(roots: roots, isEnabled: true)
        await warmer.awaitCurrentSweep()
        return warmer.lastReport
    }

    @Test("先に作る役: サブフォルダの動画まで作ってディスクに入れる。作り済みは次の掃引で飛ばす")
    func warmerGeneratesAndSkipsCached() async throws {
        let fixture = try warmerFixture("warm-basic")
        let first = try fixture.video("a.mp4")
        try fixture.video("sub/deeper/b.mp4")
        try Data("text".utf8).write(to: fixture.root.appendingPathComponent("note.txt"))
        let warmer = fixture.warmer()

        let report = try #require(await sweep(warmer, roots: [fixture.root]))
        #expect(report.generated.map(\.lastPathComponent) == ["a.mp4", "b.mp4"])
        let key = try #require(FileBrowserThumbnailKey.of(first, mountTable: MountTable.current()))
        #expect(await fixture.disk.contains(key))

        warmer.restart()
        await warmer.awaitCurrentSweep()
        #expect(warmer.lastReport?.generated.isEmpty == true)
        #expect(fixture.loader.calls.count == 2)
    }

    @Test("先に作る役: ディスクキャッシュの上限の半分までしか書かない。使用量が半分を超えていれば作らない(2 回目の監査 22)")
    func warmerStaysWithinHalfOfTheCacheLimit() async throws {
        // 以前は上限を知らずに書き続け、刈り込みと作り直しを起動のたびに繰り返した。
        let fixture = try warmerFixture("warm-budget")
        for name in ["a.mp4", "b.mp4", "c.mp4"] { try fixture.video(name) }
        let limit = 10 * 1024 * 1024

        func sweepWithUsage(_ usage: Int, label: String) async throws -> FileBrowserVideoThumbnailWarmer.SweepReport {
            let directory = fixture.temporary.file("cache-\(label)")
            // いまの使用量のぶんの、ほかの絵(刈り込みの上限は超えない)。
            let filler = directory.appendingPathComponent("zz/filler.jpg")
            try FileManager.default.createDirectory(at: filler.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: usage).write(to: filler)
            let cache = FileBrowserThumbnailDiskCache(directory: directory, configuration: .init(isEnabled: true, maxTotalBytes: limit))
            let warmer = FileBrowserVideoThumbnailWarmer(
                dependencies: .init(
                    diskCache: cache, loader: fixture.loader, isRemote: { _ in false }, isDataless: { _ in false },
                    protectedPrefixes: [], formatFailureThreshold: 3
                ),
                debounce: .zero
            )
            return try #require(await sweep(warmer, roots: [fixture.root]))
        }

        let full = try await sweepWithUsage(limit / 2, label: "full")
        #expect(full.generated.isEmpty && full.stoppedForCacheBudget, "使用量が上限の半分に届いていれば作らない")
        #expect(fixture.loader.calls.isEmpty)

        let almost = try await sweepWithUsage(limit / 2 - 1, label: "almost")
        #expect(almost.generated.map(\.lastPathComponent) == ["a.mp4"], "取り分(1 バイト)を 1 本で使い切ったら止める")
        #expect(almost.stoppedForCacheBudget)
    }

    @Test("先に作る役: 1 度も成功しない拡張子は 3 回失敗したらこの掃引では諦める。1 度でも成功した拡張子は諦めない")
    func warmerSkipsFailingFormats() async throws {
        let failing = try warmerFixture("warm-fail") { _ in nil }
        for index in 1...5 { try failing.video("clip\(index).mp4") }
        let failReport = try #require(await sweep(failing.warmer(), roots: [failing.root]))
        #expect(failing.loader.calls.count == 3)
        #expect(failReport.skippedExtensions == ["mp4"])

        let mixed = try warmerFixture("warm-mixed") { url in
            url.lastPathComponent.contains("ok") ? PageImageFactory.cgImage(number: 1) : nil
        }
        for name in ["a.mp4", "b-ok.mp4", "c.mp4", "d.mp4", "e.mp4"] { try mixed.video(name) }
        let mixedReport = try #require(await sweep(mixed.warmer(), roots: [mixed.root]))
        #expect(mixed.loader.calls.count == 5)
        #expect(mixedReport.skippedExtensions.isEmpty)
    }

    @Test("先に作る役: ネットワーク越し・途中のマウント・実体の無いファイル・隠しフォルダは辿らない(失敗とも数えない)")
    func warmerSkipsRemoteDatalessAndHidden() async throws {
        let fixture = try warmerFixture("warm-skip")
        try fixture.video("real.mp4")
        try fixture.video(".hidden/secret.mp4")
        try fixture.video("mounted/remote.mp4")
        for index in 1...4 { try fixture.video("cloud\(index).mp4") }
        let warmer = fixture.warmer(
            isRemote: { $0.lastPathComponent == "mounted" },
            isDataless: { $0.lastPathComponent.hasPrefix("cloud") }
        )
        let report = try #require(await sweep(warmer, roots: [fixture.root]))
        #expect(fixture.loader.calls.map(\.lastPathComponent) == ["real.mp4"])
        #expect(report.failed.isEmpty)

        let remoteRoot = fixture.warmer(isRemote: { _ in true })
        _ = await sweep(remoteRoot, roots: [fixture.root])
        #expect(fixture.loader.calls.count == 1)
    }

    @Test("先に作る役: 保護下の場所は、よく使う項目そのものがその中にあるときだけ辿る")
    func warmerRespectsProtectedLocations() throws {
        let fixture = try warmerFixture("warm-protected")
        try fixture.video("open.mp4")
        try fixture.video("Desktop/inside.mp4")
        try fixture.video("Desktop/Movies/deeper.mp4")
        let desktop = MountTable.normalized(fixture.root.appendingPathComponent("Desktop").path)

        let fromAbove = FileBrowserVideoThumbnailWarmer.videoFiles(
            under: fixture.root, protectedPrefixes: [desktop], isRemote: { _ in false }
        )
        #expect(fromAbove.map(\.lastPathComponent) == ["open.mp4"])

        let fromInside = FileBrowserVideoThumbnailWarmer.videoFiles(
            under: fixture.root.appendingPathComponent("Desktop/Movies"), protectedPrefixes: [desktop], isRemote: { _ in false }
        )
        #expect(fromInside.map(\.lastPathComponent) == ["deeper.mp4"])
    }

    @Test("先に作る役: 入れ子のよく使う項目でも 1 本を 1 回だけ。OFF なら動かない。止めたら残りへ進まない")
    func warmerDedupesDisablesAndStops() async throws {
        let fixture = try warmerFixture("warm-stop")
        try fixture.video("a.mp4")
        try fixture.video("sub/b.mp4")
        let nested = fixture.warmer()
        _ = await sweep(nested, roots: [fixture.root, fixture.root.appendingPathComponent("sub")])
        #expect(fixture.loader.calls.map(\.lastPathComponent) == ["a.mp4", "b.mp4"])

        let gated = try warmerFixture("warm-gated")
        try gated.video("a.mp4")
        try gated.video("b.mp4")
        let disabled = gated.warmer()
        disabled.update(roots: [gated.root], isEnabled: false)
        await disabled.awaitCurrentSweep()
        #expect(gated.loader.calls.isEmpty)

        let gate = VideoLoaderGate()
        let stopping = FileBrowserVideoThumbnailWarmer(
            dependencies: .init(
                diskCache: gated.disk, loader: GatedVideoLoader(gate: gate, wrapped: gated.loader),
                isRemote: { _ in false }, isDataless: { _ in false }, protectedPrefixes: [], formatFailureThreshold: 3
            ),
            debounce: .zero
        )
        stopping.update(roots: [gated.root], isEnabled: true)
        await gate.waitUntilFirstCall()
        stopping.stop()
        gate.open()
        await stopping.awaitCurrentSweep()
        #expect(gated.loader.calls.map(\.lastPathComponent) == ["a.mp4"])
    }
}

// MARK: - 作り物

/// 呼ばれた URL を控え、決めた結果を返す作り方。
nonisolated final class ScriptedVideoLoader: VideoThumbnailLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    private let result: @Sendable (URL) -> CGImage?

    init(_ result: @escaping @Sendable (URL) -> CGImage?) {
        self.result = result
    }

    var calls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        record(url)
        return result(url)
    }

    // NSLock.lock() は async の本体から呼べない(noasync)ので、同期の関数に閉じ込める。
    private func record(_ url: URL) {
        lock.lock()
        recorded.append(url)
        lock.unlock()
    }
}

/// 「作っている最中」を時間ではなく状態で作るための門。
nonisolated final class VideoLoaderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var wasCalled = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in arrive(continuation) }
    }

    func waitUntilFirstCall() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in awaitCall(continuation) }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiters = gateWaiters
        gateWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func arrive(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        wasCalled = true
        let announce = callWaiters
        callWaiters = []
        if isOpen {
            lock.unlock()
            announce.forEach { $0.resume() }
            continuation.resume()
            return
        }
        gateWaiters.append(continuation)
        lock.unlock()
        announce.forEach { $0.resume() }
    }

    private func awaitCall(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if wasCalled {
            lock.unlock()
            continuation.resume()
            return
        }
        callWaiters.append(continuation)
        lock.unlock()
    }
}

nonisolated struct GatedVideoLoader: VideoThumbnailLoading {
    let gate: VideoLoaderGate
    let wrapped: any VideoThumbnailLoading

    func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        await gate.pass()
        return await wrapped.makeThumbnail(for: url, maxPixelSize: maxPixelSize)
    }
}
