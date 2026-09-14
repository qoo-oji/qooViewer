import Combine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ファイルブラウザのアイコン表示の絵を配る窓口(改善要望7 段階 7a、2026-09-14)。アプリで 1 つ(AppStores)。
///
/// ■ どこから絵を持ってくるか(決定事項 Q5 の 2 段構え)
/// 1. その本がコレクションに登録済みで表紙ができていれば、**その表紙**(CollectionCoverStore の JPEG)。棚と同じ絵で、
///    本は 1 バイトも読まない。ディスクキャッシュには入れない(表紙そのものがディスクにある)
/// 2. 無ければディスクキャッシュ(FileBrowserThumbnailDiskCache)、それも無ければ `BookThumbnailer` で作ってキャッシュへ
///
/// ■ メモリ
/// 復号した絵は `PagePixelCache`(厳密な LRU、96MB)に**表示の大きさの段ごと**に持つ。段は長辺 128 / 256 / 512px
/// (アイコンの大きさ 48〜256pt の Retina ぶん)。セルへは使い捨ての CGImage(`makeImage()`)を渡す ―― CGImage を
/// キャッシュに抱えると、表示した絵が 3 倍のメモリを占め続ける(PagePixelBuffer の型コメント)。セルの側で残る絵は
/// `LazyCellImageBudget` で数える(LazyVGrid は画面外のセルの @State を手放さない)。
///
/// ■ 並べ方
/// 作る仕事は同時に `maxConcurrentJobs`(4)件まで。待っている仕事は**後から頼まれたものから**始める(スクロールすると
/// 画面に入ったばかりのセルが先に埋まる)。同じ絵を頼むセルが複数あれば 1 件にまとめる。頼んだセルが全部いなくなった
/// (`.task` が取り消された)仕事は、始まる前なら捨てる。始まった仕事は止めない(FileIO の上の読み取りは中断できない)
/// ―― 結果はキャッシュに入るので無駄にはならない。
///
/// ■ 作れなかった絵
/// 画像の無い書庫・壊れたファイル・読めない場所は、この起動の間は覚えて作り直さない(`failedKeys`。鍵に更新日時と
/// サイズを含むので、中身が変われば試し直す)。永続化しない ―― 外付けを抜いていただけ、は次の起動で直る。
@MainActor
final class FileBrowserThumbnailProvider: ObservableObject {
    /// 絵の出どころが変わった合図(コレクションの表紙ができた・変わった、キャッシュを消した)。セルの `.task(id:)` に
    /// 入れて、変わったら頼み直させる。メモリに残っていれば頼み直しは即座に返る。
    @Published private(set) var revision: UInt64 = 0

    static let maxConcurrentJobs = 4
    nonisolated static let memoryLimitBytes = 96 * 1024 * 1024

    /// 復号の大きさの段(長辺の画素)。
    static let pixelTiers: [CGFloat] = [128, 256, 512]

    /// 表示の大きさ(pt)から段を選ぶ。Retina ぶんの 2 倍を超えるいちばん小さい段(無ければ最大)。
    static func pixelTier(forDisplaySize points: CGFloat, scale: CGFloat = 2) -> CGFloat {
        let needed = points * scale
        return pixelTiers.first { $0 >= needed } ?? pixelTiers[pixelTiers.count - 1]
    }

    private let memory: PagePixelCache
    private let diskCache: FileBrowserThumbnailDiskCache
    private weak var collectionStore: CollectionStore?
    private let coverStore: CollectionCoverStore?
    private var collectionSubscription: AnyCancellable?

    /// 作れなかった絵(型コメント)。上限を超えたら丸ごと忘れる(試し直すだけで害は無い)。
    private var failedKeys: Set<String> = []
    private static let failedKeysLimit = 5000

    /// 1 件の仕事。同じ絵を待つセル(`waiters`)を束ねる。
    private final class Job {
        /// 段を含まない鍵(作れなかったことを覚える単位)。
        let baseKey: String
        let memoryKey: String
        let source: Source
        let pixelSize: CGFloat
        var waiters: [UUID: CheckedContinuation<PagePixelBuffer?, Never>] = [:]
        var isStarted = false

        init(baseKey: String, memoryKey: String, source: Source, pixelSize: CGFloat) {
            self.baseKey = baseKey
            self.memoryKey = memoryKey
            self.source = source
            self.pixelSize = pixelSize
        }
    }

    private enum Source {
        /// コレクションの表紙の JPEG。
        case cover(URL)
        /// 項目そのものから作る。
        case item(URL, BookThumbnailer.Kind)
    }

    private var jobs: [String: Job] = [:]
    /// 始まっていない仕事(末尾が新しい)。
    private var queue: [Job] = []
    private var runningCount = 0

    /// 実際に絵を作った回数(**テストのための口**。キャッシュに当たったら数えない)。
    private(set) var generatedCount = 0

    /// - Parameters:
    ///   - diskCache: 既定は実物のキャッシュ。**テストは一時フォルダのものを渡す。**
    ///   - collectionStore / coverStore: 表紙を探す相手。nil なら表紙を見ない(テスト)。
    init(
        diskCache: FileBrowserThumbnailDiskCache = .shared,
        collectionStore: CollectionStore? = nil,
        coverStore: CollectionCoverStore? = nil,
        memoryLimitBytes: Int = FileBrowserThumbnailProvider.memoryLimitBytes
    ) {
        self.diskCache = diskCache
        self.collectionStore = collectionStore
        self.coverStore = coverStore
        memory = PagePixelCache(countLimit: 4000, totalCostLimit: memoryLimitBytes)
        // 表紙ができた・変わったら頼み直させる。`revision` はコレクションの変更のたびに進むので、ここでも間引かずに
        // 進める(メモリに残っている絵は即座に返るので、頼み直しは安い)。
        collectionSubscription = collectionStore?.$revision
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.revision &+= 1 }
            }
    }

    // MARK: - 頼む

    /// この項目の絵を作る必要があるか(作れる種類か)。無ければセルは種類のアイコンのまま。
    ///
    /// フォルダは**中を読む**ので、次の場所では作らない:
    /// - ネットワーク越しのボリューム(セルの数だけ往復する。ツリーの三角と同じ判断)
    /// - TCC の保護下の場所(ホームを開いただけで「デスクトップ」の中を読むと許可のダイアログが出る)。ただし
    ///   デスクトップ・書類・ダウンロードの**中を見ている**ときの、同じ場所の中のフォルダは読む(許可は場所ごとに済んでいる。
    ///   `DirectoryProbe.categoryProtectedPrefixes`)
    static func kind(
        for entry: FileBrowserEntry, currentFolder: URL?, mountTable: MountTable,
        protectedPrefixes: [String] = DirectoryProbe.protectedPrefixes,
        categoryPrefixes: Set<String> = DirectoryProbe.categoryProtectedPrefixes
    ) -> BookThumbnailer.Kind? {
        guard !entry.isVolume,
              let kind = BookThumbnailer.kind(
                forName: entry.url.lastPathComponent, isNavigableFolder: entry.isNavigableFolder,
                isPackage: entry.isPackage, isSymbolicLink: entry.isSymbolicLink
              )
        else { return nil }
        if kind == .folder {
            if mountTable.isRemote(entry.url) { return nil }
            if let prefix = DirectoryProbe.protectedPrefix(containing: entry.url, prefixes: protectedPrefixes) {
                let current = currentFolder.flatMap { DirectoryProbe.protectedPrefix(containing: $0, prefixes: protectedPrefixes) }
                guard categoryPrefixes.contains(prefix), current == prefix else { return nil }
            }
        }
        return kind
    }

    /// 絵を返す。作れなければ nil。呼び出し側(セルの `.task`)が取り消されたら nil で戻る。
    ///
    /// - Parameter pixelSize: `pixelTier(forDisplaySize:)` の段。
    func thumbnail(for entry: FileBrowserEntry, kind: BookThumbnailer.Kind, pixelSize: CGFloat) async -> PagePixelBuffer? {
        let (baseKey, source) = resolveSource(for: entry, kind: kind)
        guard !failedKeys.contains(baseKey) else { return nil }
        let memoryKey = "\(baseKey)|\(Int(pixelSize))"
        if let cached = memory.object(forKey: memoryKey as NSString) { return cached }

        let job: Job
        if let existing = jobs[memoryKey] {
            job = existing
        } else {
            job = Job(baseKey: baseKey, memoryKey: memoryKey, source: source, pixelSize: pixelSize)
            jobs[memoryKey] = job
            queue.append(job)
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PagePixelBuffer?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    dropIfUnwanted(job)
                    return
                }
                job.waiters[waiterID] = continuation
                pump()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID, of: memoryKey) }
        }
    }

    /// 出どころと、段を含まない鍵。表紙は項目の更新日時と無関係に、表紙の差し替え回数で鍵を変える。
    private func resolveSource(for entry: FileBrowserEntry, kind: BookThumbnailer.Kind) -> (String, Source) {
        if kind != .image, let collectionStore, let coverStore,
           let item = collectionStore.items(forBookID: entry.id).first(where: { $0.coverState == .ready }) {
            let revision = collectionStore.coverRevision(for: item)
            return ("cover|\(item.id.uuidString)|\(revision)", .cover(coverStore.url(for: item.id)))
        }
        let modified = entry.modificationDate?.timeIntervalSinceReferenceDate ?? 0
        return ("item|\(entry.id)|\(modified)|\(entry.fileSize ?? -1)", .item(entry.url, kind))
    }

    private func cancelWaiter(_ waiterID: UUID, of memoryKey: String) {
        guard let job = jobs[memoryKey], let continuation = job.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: nil)
        dropIfUnwanted(job)
    }

    /// 待つセルがいなくなった、始まっていない仕事を捨てる。
    private func dropIfUnwanted(_ job: Job) {
        guard job.waiters.isEmpty, !job.isStarted else { return }
        jobs[job.memoryKey] = nil
        queue.removeAll { $0 === job }
    }

    private func pump() {
        while runningCount < Self.maxConcurrentJobs, let job = queue.popLast() {
            job.isStarted = true
            runningCount += 1
            Task { [weak self] in
                guard let self else { return }
                let result = await self.run(job)
                self.finish(job, result: result)
            }
        }
    }

    private func finish(_ job: Job, result: PagePixelBuffer?) {
        runningCount -= 1
        jobs[job.memoryKey] = nil
        if let result {
            memory.store(result, forKey: job.memoryKey as NSString)
        }
        let waiters = job.waiters
        job.waiters = [:]
        for continuation in waiters.values {
            continuation.resume(returning: result)
        }
        pump()
    }

    // MARK: - 作る

    private func run(_ job: Job) async -> PagePixelBuffer? {
        let pixelSize = job.pixelSize
        let baseKey = job.baseKey
        switch job.source {
        case .cover(let url):
            let pixels = await FileIO.perform { () -> PagePixelBuffer? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return ImageDecoder.decodePixels(data, maxPixelSize: pixelSize)
            }
            if pixels == nil { remember(failure: baseKey) }
            return pixels

        case .item(let url, let kind):
            let mountTable = MountTable.current()
            let key = await FileIO.perform { FileBrowserThumbnailKey.of(url, mountTable: mountTable) }
            if let key, let data = await diskCache.data(for: key) {
                if let pixels = await Self.decode(data, maxPixelSize: pixelSize) { return pixels }
            }
            generatedCount += 1
            let made = await FileIO.perform { () -> (jpeg: Data, pixels: PagePixelBuffer)? in
                guard let image = BookThumbnailer.thumbnail(
                    of: url, kind: kind, maxPixelSize: FileBrowserThumbnailDiskCache.maxPixelSize
                ), let jpeg = Self.jpegData(from: image),
                    let pixels = ImageDecoder.decodePixels(jpeg, maxPixelSize: pixelSize)
                else { return nil }
                return (jpeg, pixels)
            }
            guard let made else {
                remember(failure: baseKey)
                return nil
            }
            if let key { await diskCache.store(made.jpeg, for: key) }
            return made.pixels
        }
    }

    @concurrent private nonisolated static func decode(_ data: Data, maxPixelSize: CGFloat) async -> PagePixelBuffer? {
        ImageDecoder.decodePixels(data, maxPixelSize: maxPixelSize)
    }

    private func remember(failure baseKey: String) {
        if failedKeys.count >= Self.failedKeysLimit { failedKeys.removeAll() }
        failedKeys.insert(baseKey)
    }

    /// JPEG にする。**白地に描いてから**書く(JPEG は透明を持てず、透明な PNG の地が黒になる)。
    nonisolated static func jpegData(from image: CGImage) -> Data? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flattened = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, flattened,
            [kCGImageDestinationLossyCompressionQuality: FileBrowserThumbnailDiskCache.jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - キャッシュの削除

    /// メモリの絵と「作れなかった」の記憶を捨てて、セルに頼み直させる(環境設定でキャッシュを消したとき)。
    func purgeMemory() {
        memory.removeAll()
        failedKeys.removeAll()
        revision &+= 1
    }

    /// 仕事がすべて終わるまで待つ(**テストのための口**)。
    func waitUntilIdle() async {
        while runningCount > 0 || !queue.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
