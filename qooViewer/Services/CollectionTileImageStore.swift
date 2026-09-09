import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// 札の中の割り付け(列・行・余白・間隔)の唯一の正典。表示側(CollectionTile)と、
/// 焼いた絵を作る側(CollectionTileImageStore)の**両方がここを見る**。
///
/// 列数・行数はライブラリの縦横比で決まる(CoverAspectRatio.tileColumns)。ここが持つのは、
/// そこへ敷き詰めるときの余白と間隔、そして「焼くときの画素数」の基準。
nonisolated enum CollectionTileLayout {
    /// セルの間隔(ユーザー指摘 2026-09-09で3ptから広げた ―― 詰まりすぎて、6冊が1枚の
    /// 大きな絵のように見えていた)。
    static let cellSpacing: CGFloat = 6
    /// 札の内側の余白。セルの間隔より狭いと、外周だけが窮屈に見えるので少し広く取る。
    static let padding: CGFloat = 8

    /// 焼いた絵の基準になる札の幅(pt)。スライダーの上限
    /// (`WelcomeLibraryState.tileSizeRange.upperBound`)と同じ ―― 一番大きく表示したときに
    /// 甘くならない画素数で焼いておき、小さいときは復号の段で縮める。
    static let referenceTileWidth: CGFloat = 320
    /// Retinaぶんの倍率。
    static let referenceScale: CGFloat = 2

    /// 札の幅からセル1つの幅(pt)を求める。
    static func cellWidth(tileWidth: CGFloat, aspectRatio: CoverAspectRatio) -> CGFloat {
        let columns = CGFloat(aspectRatio.tileColumns)
        return (tileWidth - padding * 2 - cellSpacing * (columns - 1)) / columns
    }

    /// 焼いた絵(**間隔も余白も無い、セルを隙間なく並べただけの1枚**)の画素数。
    ///
    /// ■ なぜ間隔と余白を焼き込まないのか
    /// 余白と間隔はpt固定(8pt / 6pt)で、札の幅が120〜320ptと2.7倍変わっても**変わらない**。
    /// 余白ごと1枚のビットマップに焼くと、それを表示サイズへ縮めた瞬間に余白と間隔まで
    /// 一緒に縮み、小さい札では間隔が2pt弱になる ―― 「詰まりすぎて1枚の大きな絵に見える」と
    /// 言われて広げたばかりのものが、そのまま元へ戻ってしまう。セルの中身だけを焼いて、
    /// 余白と間隔は表示のたびにレイアウトで空ければ、見た目は今までと1ptも変わらない。
    ///
    /// 隙間が無いぶん、この1枚の縦横比は札の幅に依存しない定数になる(列数 : 行数 ÷ 比)ので、
    /// どの大きさで表示しても歪まない。
    static func sheetPixelSize(_ aspectRatio: CoverAspectRatio) -> (width: Int, height: Int) {
        let cell = cellPixelSize(aspectRatio)
        return (cell.width * aspectRatio.tileColumns, cell.height * aspectRatio.tileRows)
    }

    /// 焼いた絵のセル1つぶんの画素数。
    static func cellPixelSize(_ aspectRatio: CoverAspectRatio) -> (width: Int, height: Int) {
        let width = (cellWidth(tileWidth: referenceTileWidth, aspectRatio: aspectRatio) * referenceScale)
            .rounded(.up)
        let height = (width / aspectRatio.value).rounded(.up)
        return (max(1, Int(width)), max(1, Int(height)))
    }

    /// 焼いた絵の中で、`index`番目のセルが占める矩形(**左上原点**)。
    ///
    /// 実際に復号された画像は要求した画素数どおりとは限らない(ImageIOの丸め)ので、
    /// 焼いたときの寸法ではなく**手元にある画像の寸法**から割り出す。境界は
    /// 「i番目の切れ目 = 幅 × i ÷ 列数 の四捨五入」で求め、隣り合うセルが1px重なったり
    /// 隙間になったりしないようにしている。
    static func cellRect(
        index: Int, inImageOfSize size: (width: Int, height: Int), aspectRatio: CoverAspectRatio
    ) -> CGRect {
        let columns = aspectRatio.tileColumns
        let rows = aspectRatio.tileRows
        let column = index % columns
        let row = index / columns
        let x0 = (Double(size.width) * Double(column) / Double(columns)).rounded()
        let x1 = (Double(size.width) * Double(column + 1) / Double(columns)).rounded()
        let y0 = (Double(size.height) * Double(row) / Double(rows)).rounded()
        let y1 = (Double(size.height) * Double(row + 1) / Double(rows)).rounded()
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }
}

/// 焼いた札の絵1枚分の注文書。**この内容が同じなら絵も同じ**になるように作る
/// (`signature`がそのままファイル名とメモリキャッシュの鍵になる)。
nonisolated struct CollectionTileImageRequest: Sendable, Equatable {
    /// 札の中のセル1つ。並び順がそのまま左上からの並び。
    struct Cell: Sendable, Equatable {
        var itemID: UUID
        /// 比が合わないときに残す位置(本ごとの上書き ?? ライブラリの既定を解決済み)。
        var anchor: CoverCropAnchor
        /// 保存してあるカバーの縦横比(CollectionItem.coverAspect)。切って捨てるぶんを
        /// 見込んだ復号サイズの計算に使う。
        var coverAspect: Double
    }

    /// **すべて`let`。** 指紋を組み立て時に1度だけ計算する(下記)以上、後から中身を
    /// 差し替えられると指紋と食い違う。
    let collectionID: UUID
    let aspectRatio: CoverAspectRatio
    /// 描くセル(先頭`aspectRatio.tileCellCount`冊まで)。**空きセルは含めない** ――
    /// 冊数が足りないぶんは表示側が空きとして描く。
    let cells: [Cell]

    /// この注文書の指紋。ファイル名とメモリキャッシュの鍵に使う。**組み立て時に1度だけ**
    /// 計算する ―― 札のbodyが組み直されるたびにハッシュを取り直さないため。
    ///
    /// **カバー画像の中身は指紋に入らない**(入れるには表示のたびに6ファイルをstatすることに
    /// なる)。カバーが差し替わったときは、抽出した側から明示的に捨てる
    /// (CollectionStore.invalidateTileImages(forItemID:))。
    let signature: String

    init(collectionID: UUID, aspectRatio: CoverAspectRatio, cells: [Cell]) {
        self.collectionID = collectionID
        self.aspectRatio = aspectRatio
        self.cells = cells
        var text = aspectRatio.rawValue
        for cell in cells {
            text += "|\(cell.itemID.uuidString):\(cell.anchor.rawValue):"
            text += String(format: "%.4f", cell.coverAspect)
        }
        let digest = SHA256.hash(data: Data(text.utf8))
        // 32文字(128bit)あれば衝突は考えなくてよく、ファイル名も短く保てる。
        self.signature = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// コレクションのタイル(札)を**1枚の絵として焼いて持っておく**ための保管庫
/// (ユーザー要望 2026-09-09)。
/// `~/Library/Caches/<bundle id>/CollectionTiles/<collectionID>-<署名>.jpg`
///
/// ■ 何が問題だったか
/// 札1枚は最大6冊のカバーを敷き詰めたもので、これまではセル1つ1つが自前の`.task`を持ち、
/// カバーのJPEGを**個別に**読んで復号し、表示のたびに切り出していた。1画面に札が100枚
/// 載るような棚では、それだけで600回のファイル読み・600回の復号・600本のタスクになり、
/// スクロールが引っかかる・起動直後の最初のフレームが遅れる(ウインドウの復元が目に見える)
/// という形で出ていた。1コレクション = 1ファイル = 1回の復号にすれば、そこが素直に
/// 6分の1になる。
///
/// ■ 焼くのは「セルを隙間なく並べた1枚」だけ
/// 余白・間隔・角丸・地の色・冊数バッジ・選択の枠・名前は焼き込まない
/// (CollectionTileLayout.sheetPixelSizeのコメント参照)。地の色は明暗の外観で解決が変わる
/// `Color.primary.opacity(0.07)`が既定なので、焼き込むと**外観の切り替えだけで全札が
/// 作り直し**になる。焼いた絵から6つの矩形を切り出して並べるのは`CGImage.cropping(to:)`で、
/// 画素のコピーは起きない(CoverImageResolver.cropped(_:to:anchor:)と同じ)。
///
/// ■ なぜApplication SupportではなくCachesなのか
/// カバー本体(CollectionCoverStore)は消えると本の全冊ぶんを読み直すことになるので
/// Application Supportに置いてあるが、焼いた札はその**カバーから作り直せる派生物**で、
/// 消えても数msの合成で戻る。OSが容量逼迫で消してよいものなので、Cachesに置いて上限も
/// 自前で掛ける(ThumbnailDiskCacheと同じ理屈)。
///
/// ■ 作り直しの契機
/// - 中身・並び・切り出す位置・比が変わった → **署名が変わる**ので自動的に別ファイルになる
/// - カバー画像そのものが差し替わった → 署名が変わらないので、抽出した側が明示的に捨てる
///   (CollectionStore.invalidateTileImages(forItemID:))
///
/// actorそのものは(このプロジェクトの既定のMainActor隔離とは無関係に)固有の隔離を持つため、
/// `nonisolated`の指定は不要かつ書けない。
actor CollectionTileImageStore {
    static let jpegQuality: CGFloat = 0.82
    /// ディスク上の上限(既定128MB)。札1枚はおおむね60〜150KBなので、数百コレクションの
    /// 棚を複数持っていても収まる。超えたら最終アクセスが古いものから捨てる。
    static let maxTotalBytes = 128 * 1024 * 1024
    /// 1つのコレクションについてディスクに残す署名違いの数。並び替えの設定が違う2つの
    /// ウインドウが同じ棚を開いていると署名が2つできるので、1では足りない。
    private static let sheetsPerCollection = 2

    /// 合成を同時に走らせてよい数。
    ///
    /// 1回の合成は6枚のカバーを復号して640px弱のビットマップ(約1.5MB)へ描き写す処理で、
    /// 一時メモリは「この数 × (カバー6枚 + 1.5MB)」で頭打ちになる。絞らないと、札が100枚
    /// 載った画面を開いた瞬間に100本の合成が同時に走る(PageLoaderのデコード枠と同じ考え方)。
    private static let maxConcurrentComposes = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// 保存先。`nil`ならこの保管庫は「常にミスするだけの無害な存在」になり、表示側は
    /// これまでどおりカバーを1枚ずつ読む経路へ落ちる(ThumbnailDiskCache.directoryと同じ扱い)。
    ///
    /// `nonisolated let`にしてあるのは、読み書きの本体(復号・JPEGエンコード・ファイルI/O)を
    /// このactorの**外**で実行するため。actorの隔離が要るのは、合成の重複排除
    /// (`inFlight`)と同時実行数の帳簿だけ。
    nonisolated let directory: URL?
    /// 復号済みの絵のメモリキャッシュ。グリッドの作り直し直後に**待たずに**描くための要
    /// (CollectionTileImageCacheの型コメント参照)。
    nonisolated let memoryCache = CollectionTileImageCache(
        countLimit: 400, totalCostLimit: 96 * 1024 * 1024
    )

    private let coverStore: CollectionCoverStore

    /// 合成中の注文(署名 → タスク)。同じ札を2枚同時に焼かない。
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var activeComposes = 0
    private var composeWaiters: [CheckedContinuation<Void, Never>] = []
    /// 起動後に一度でも容量の刈り込みを行ったか。
    private var hasTrimmed = false
    /// 前回の刈り込み以降に焼いた枚数。点検はディレクトリの全走査なので毎回は走らせず、
    /// 起動後の1回目と、そこから一定枚数焼いたときだけ走らせる
    /// (ThumbnailDiskCache.bytesWrittenSinceTrimと同じ考え方。あちらはバイト数、こちらは
    /// 1枚の大きさがほぼ揃っているので枚数で数える)。
    private var bakesSinceTrim = 0
    /// この枚数を焼いたらもう一度点検する。1枚おおむね100KBなので、上限128MBに対して
    /// 超過は20MB程度で頭打ちになる。
    private static let bakesBetweenTrims = 200

    /// - Parameter directory: nilなら実際のアプリの保存先。**テストは必ず一時フォルダを渡すこと**
    ///   (既定のままだと利用者のキャッシュへテスト用の札が残る)。
    init(coverStore: CollectionCoverStore, directory: URL? = nil) {
        self.coverStore = coverStore
        self.directory = directory ?? Self.defaultDirectory()
    }

    /// 実際のアプリの保存先。ここではディレクトリを作らない(最初の書き込み時に作る)。
    nonisolated static func defaultDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "qooViewer"
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("CollectionTiles", isDirectory: true)
    }

    /// 実際のアプリの保存先をフォルダごと消す。**保管庫のインスタンスを持たない画面**
    /// (環境設定「リセット」の「すべてのデータを削除」)から呼ぶための入り口。
    nonisolated static func removeDefaultDirectory() {
        guard let directory = defaultDirectory() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 鍵

    /// メモリキャッシュの鍵。先頭がコレクションのidなのは、`removeAll(withPrefix:)`で
    /// 復号サイズ違いをまとめて落とせるようにするため。
    nonisolated static func cacheKey(_ request: CollectionTileImageRequest, pixelSize: Int) -> String {
        "\(request.collectionID.uuidString)|\(request.signature)|\(pixelSize)"
    }

    nonisolated static func cacheKeyPrefix(collectionID: UUID) -> String {
        "\(collectionID.uuidString)|"
    }

    nonisolated func fileURL(for request: CollectionTileImageRequest) -> URL? {
        directory?.appendingPathComponent(
            "\(request.collectionID.uuidString)-\(request.signature).jpg", isDirectory: false
        )
    }

    // MARK: - 読み出し

    /// メモリにあるぶんだけを**同期で**返す。グリッドが作り直された直後の最初のフレームで、
    /// `.task`の到着を待たずに描くために使う(CollectionTileImageCacheの型コメント参照)。
    nonisolated func cachedImage(forKey key: String) -> CGImage? {
        memoryCache.image(forKey: key)
    }

    /// 焼いた絵を返す。まだ無ければ焼いてから返す。焼けなければnil(表示側はカバーを
    /// 1枚ずつ読む経路へ落ちる)。
    ///
    /// - Parameter pixelSize: 復号する最大辺。呼び出し側が表示サイズから量子化して渡す。
    func image(for request: CollectionTileImageRequest, pixelSize: Int) async -> CGImage? {
        let key = Self.cacheKey(request, pixelSize: pixelSize)
        if let hit = memoryCache.image(forKey: key) { return hit }
        guard let url = fileURL(for: request) else { return nil }

        // `await`のあいだこのactorは解放されるので、1枚の復号が他の札の読み出しを待たせない。
        if let decoded = await Self.decode(url, maxPixelSize: pixelSize) {
            memoryCache.store(decoded, forKey: key)
            return decoded
        }
        await bake(request)
        guard let decoded = await Self.decode(url, maxPixelSize: pixelSize) else { return nil }
        memoryCache.store(decoded, forKey: key)
        return decoded
    }

    @concurrent private nonisolated static func decode(_ url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary)
    }

    // MARK: - 合成

    /// 焼く。同じ署名の合成が既に走っていればそれに合流する。
    private func bake(_ request: CollectionTileImageRequest) async {
        if let existing = inFlight[request.signature] {
            await existing.value
            return
        }
        // 非構造化Taskは呼び出し側のキャンセルを継承しない。ここでは**それが要る** ――
        // 画面外へ流れた札の`.task`が取り消されても、同じ絵を待っている他の札のために
        // 合成そのものは走り切ってほしい(次に現れたときにはディスクから戻る)。
        let task = Task {
            await self.composeAndWrite(request)
        }
        inFlight[request.signature] = task
        await task.value
        inFlight[request.signature] = nil
    }

    private func composeAndWrite(_ request: CollectionTileImageRequest) async {
        guard let directory, let url = fileURL(for: request) else { return }
        await acquireComposeSlot()
        defer { releaseComposeSlot() }
        guard let image = await Self.compose(request, coverStore: coverStore) else { return }
        guard await Self.write(image, to: url) else { return }
        await Self.pruneAndTrim(
            in: directory, collectionID: request.collectionID, trimsTotal: claimTrim()
        )
    }

    /// 6枚のカバーを、隙間なく並べた1枚のビットマップへ描く。
    /// 1枚でも読めなければnil ―― 穴の空いた絵を焼いて残すより、表示側の経路へ落とすほうがよい。
    @concurrent nonisolated static func compose(
        _ request: CollectionTileImageRequest, coverStore: CollectionCoverStore
    ) async -> CGImage? {
        let aspectRatio = request.aspectRatio
        let sheet = CollectionTileLayout.sheetPixelSize(aspectRatio)
        let cell = CollectionTileLayout.cellPixelSize(aspectRatio)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: sheet.width, height: sheet.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: colorSpace,
                // JPEGで保存するので透明度は持たない。空きセル(冊数が足りないぶん)は
                // 表示側が描かないので、地は何色でもよい。
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))

        for (index, item) in request.cells.enumerated() {
            let decodeSize = CoverImageResolver.decodePixelSize(
                croppedWidth: CGFloat(cell.width), targetAspect: aspectRatio.value,
                imageAspect: CGFloat(item.coverAspect)
            )
            guard let cover = await coverStore.image(for: item.itemID, maxPixelSize: decodeSize)
            else { return nil }
            let cropped = CoverImageResolver.cropped(
                cover, to: aspectRatio.value, anchor: item.anchor
            )
            let rect = CollectionTileLayout.cellRect(
                index: index, inImageOfSize: sheet, aspectRatio: aspectRatio
            )
            // CGContextは左下原点。cellRectは左上原点なので上下を入れ替える。
            context.draw(cropped, in: CGRect(
                x: rect.minX, y: CGFloat(sheet.height) - rect.maxY,
                width: rect.width, height: rect.height
            ))
        }
        return context.makeImage()
    }

    /// 一度メモリ上でJPEGにしてから`Data.write(options: .atomic)`で書き出す。直接ファイルへ
    /// 書くと、書き込み途中のファイルを表示側(decode)が読みうる(CollectionCoverStore.writeと
    /// 同じ理由)。
    @concurrent private nonisolated static func write(_ image: CGImage, to url: URL) async -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            return false
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return false }
        do {
            try (output as Data).write(to: url, options: .atomic)
        } catch {
            return false
        }
        return true
    }

    /// いま容量の点検を行ってよいか。走査そのものはこの外(actorの外)で行う。
    private func claimTrim() -> Bool {
        bakesSinceTrim += 1
        guard !hasTrimmed || bakesSinceTrim >= Self.bakesBetweenTrims else { return false }
        hasTrimmed = true
        bakesSinceTrim = 0
        return true
    }

    // MARK: - 同時実行数

    private func acquireComposeSlot() async {
        if activeComposes < Self.maxConcurrentComposes {
            activeComposes += 1
            return
        }
        // 起こされた時点でスロットは自分のもの(releaseComposeSlotがactiveComposesを
        // 減らさずに次を起こす)。PageLoader.acquireDecodeSlotと同じ規約。
        await withCheckedContinuation { continuation in
            composeWaiters.append(continuation)
        }
    }

    private func releaseComposeSlot() {
        if !composeWaiters.isEmpty {
            composeWaiters.removeFirst().resume()
        } else {
            activeComposes -= 1
        }
    }

    // MARK: - 後始末

    /// このコレクションの焼いた絵を捨てる。カバー画像そのものが差し替わったとき
    /// (署名が変わらないので自動では作り直されない)に呼ぶ。
    @concurrent nonisolated func invalidate(collectionIDs: [UUID]) async {
        guard !collectionIDs.isEmpty else { return }
        for id in collectionIDs {
            memoryCache.removeAll(withPrefix: Self.cacheKeyPrefix(collectionID: id))
        }
        guard let directory else { return }
        let prefixes = Set(collectionIDs.map { $0.uuidString + "-" })
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in names where prefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 行の残っていない札を掃除する。起動時に1回だけ呼ぶ(CollectionCoverStore.sweepOrphansと
    /// 同じ役目)。同じ通りがけに容量の刈り込みも済ませる。
    @concurrent nonisolated func sweepOrphans(keeping collectionIDs: Set<UUID>) async {
        guard let directory else { return }
        let keep = Set(collectionIDs.map { $0.uuidString })
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in names where url.pathExtension.lowercased() == "jpg" {
            let base = url.deletingPathExtension().lastPathComponent
            // "<collectionID>-<署名>"。このアプリが書いたものでなければ触らない。
            guard let separator = base.lastIndex(of: "-"),
                  UUID(uuidString: String(base[base.startIndex..<separator])) != nil
            else { continue }
            if !keep.contains(String(base[base.startIndex..<separator])) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        Self.trimIfNeeded(in: directory)
    }

    func removeAll() async {
        memoryCache.removeAll()
        guard let directory else { return }
        await Self.removeDirectory(directory)
    }

    @concurrent private nonisolated static func removeDirectory(_ directory: URL) async {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 焼いたばかりの札の**古い署名**を捨て、必要なら容量の刈り込みも行う。
    @concurrent private nonisolated static func pruneAndTrim(
        in directory: URL, collectionID: UUID, trimsTotal: Bool
    ) async {
        pruneOldSheets(in: directory, collectionID: collectionID)
        if trimsTotal { trimIfNeeded(in: directory) }
    }

    /// 1つのコレクションについて、新しいものから`sheetsPerCollection`枚だけ残す。
    /// 本を1冊足すたびに署名が変わるので、これが無いと古い札が延々と積もる。
    private nonisolated static func pruneOldSheets(in directory: URL, collectionID: UUID) {
        let prefix = collectionID.uuidString + "-"
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        let mine = names
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map { url -> (url: URL, date: Date) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.date > $1.date }
        for file in mine.dropFirst(sheetsPerCollection) {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// 上限を超えていたら、最終更新が古いものから削除する(ThumbnailDiskCache.trimIfNeededと
    /// 同じ形。あちらは上限がユーザー設定で、こちらは固定なので世代管理は持たない)。
    private nonisolated static func trimIfNeeded(in directory: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let size = values.fileSize ?? 0
            files.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > maxTotalBytes else { return }
        // 上限の8割まで落とす(削除のたびにすぐ上限へ戻らないようにするため)。
        let target = maxTotalBytes * 8 / 10
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > target else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}
