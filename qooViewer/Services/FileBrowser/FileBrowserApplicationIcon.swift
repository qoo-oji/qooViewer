import AppKit

/// ファイルブラウザに出す**アプリケーション(.app)の本物のアイコン**(2026-09-14、ユーザー要望)。
///
/// ■ なぜ別に読むのか
/// 種類のアイコン(FileBrowserIconProvider)は**ファイルシステムに触らない**約束で、拡張子から引く。`.app` はそれだと
/// どれも同じ汎用のアプリのアイコンになり、アプリケーションフォルダを開くと見分けがつかなかった。アプリ固有のアイコンは
/// バンドルの中(Info.plist・Assets.car・.icns)を読まないと分からないので、`NSWorkspace.icon(forFile:)` を**FileIO の上で**
/// 呼び、決まった画素数の絵に描き写してから持ち帰る。
///
/// ■ 約束事(docs/15「サンドボックスと TCC の約束」)
/// - `NSWorkspace.icon(forFile:)` は応答しない共有の上では 30 秒ブロックしうる(FileBrowserIconProvider の型コメント)
///   ので、**メインアクターでは呼ばない**。スレッドから呼んでよい(AppKit のヘッダーで thread safe とされている)。
/// - バンドルの中を読むのは「ユーザーが入っていないフォルダを読む」ことなので、フォルダの絵と同じく
///   ネットワーク越しのボリュームと TCC の保護下の場所では読まない(`FileBrowserThumbnailProvider.kind(for:...)`)。
/// - `NSImage` は描くときに遅れて中身を読むことがあるので、**FileIO の上で描き終えた画素**(`PagePixelBuffer`)だけを渡す。
nonisolated enum FileBrowserApplicationIcon {
    /// アプリケーションのバンドルか。**名前だけで決める**(ファイルに触らない)。記号リンクは先が別の場所なので除く。
    static func isApplication(name: String, isPackage: Bool, isSymbolicLink: Bool) -> Bool {
        isPackage && !isSymbolicLink && (name as NSString).pathExtension.lowercased() == "app"
    }

    /// アイコンを `pixelSize` 四方の画素に描く。**FileIO の上で呼ぶ**(型コメント)。
    static func render(at url: URL, pixelSize: Int) -> PagePixelBuffer? {
        guard pixelSize > 0 else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return PagePixelBuffer(
            width: pixelSize, height: pixelSize, grayscale: false,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        ) { context in
            context.interpolationQuality = .high
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            icon.draw(
                in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
                from: .zero, operation: .sourceOver, fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// リスト表示の行に出すアプリのアイコン(16pt)。アプリで 1 つ。
///
/// アイコン表示は `FileBrowserThumbnailProvider`(大きさの段・LRU)を通すが、リストの行は 1 枚 32px(約 4KB)と小さく、
/// NSTableView のセルへ直接入れるので、ここで簡単に覚えておく。鍵はパスと更新日時(アプリを入れ替えたら読み直す)。
@MainActor
final class FileBrowserListApplicationIcons {
    static let shared = FileBrowserListApplicationIcons()

    static let pointSize: CGFloat = 16
    static let pixelSize = 32
    /// 覚えておく数の上限。超えたら丸ごと忘れる(読み直すだけで害は無い)。
    private static let countLimit = 2000

    private var cache: [String: NSImage] = [:]
    /// 読めなかった(アイコンが取れなかった)もの。この起動の間は試し直さない。
    private var failed: Set<String> = []
    private var loading: Set<String> = []
    /// 同時に読むのは `maxConcurrentLoads` 件まで(2026-09-14 の 2 回目の監査。以前は上限が無く、アプリケーションフォルダをリストで
    /// スクロールすると行の数だけ FileIO のスレッドが同時に立った)。待っているものは**後から頼まれたものから**始める(画面に入ったばかりの行)。
    private static let maxConcurrentLoads = 4
    private var runningCount = 0
    private var waiting: [(key: String, url: URL, completion: @MainActor (NSImage) -> Void)] = []

    private init() {}

    static func key(for entry: FileBrowserEntry) -> String {
        "\(entry.id)|\(entry.modificationDate?.timeIntervalSinceReferenceDate ?? 0)"
    }

    func cachedIcon(for entry: FileBrowserEntry) -> NSImage? {
        cache[Self.key(for: entry)]
    }

    /// 読んで、読めたら `completion` を呼ぶ。既に読んでいる最中・読めなかったものは何もしない。
    func load(_ entry: FileBrowserEntry, completion: @escaping @MainActor (NSImage) -> Void) {
        let key = Self.key(for: entry)
        if let cached = cache[key] {
            completion(cached)
            return
        }
        guard !loading.contains(key), !failed.contains(key) else { return }
        loading.insert(key)
        waiting.append((key, entry.url, completion))
        startWaitingLoads()
    }

    private func startWaitingLoads() {
        while runningCount < Self.maxConcurrentLoads, let next = waiting.popLast() {
            runningCount += 1
            let (key, url, completion) = next
            // 画素数は先に値で取り出す。`Self.pixelSize` はメインアクターの型の静的プロパティなので、FileIO へ渡す閉包の中では読めない。
            let pixelSize = Self.pixelSize
            Task { [weak self] in
                let pixels = await FileIO.perform { FileBrowserApplicationIcon.render(at: url, pixelSize: pixelSize) }
                guard let self else { return }
                self.runningCount -= 1
                self.loading.remove(key)
                defer { self.startWaitingLoads() }
                guard let pixels, let image = pixels.makeImage() else {
                    self.failed.insert(key)
                    return
                }
                if self.cache.count >= Self.countLimit { self.cache.removeAll() }
                let icon = NSImage(cgImage: image, size: NSSize(width: Self.pointSize, height: Self.pointSize))
                self.cache[key] = icon
                completion(icon)
            }
        }
    }
}
