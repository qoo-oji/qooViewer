import AppKit
import Combine

/// ファイルブラウザに出す、**システムが項目ごとに決めるアイコン**: アプリケーション(.app)の本物のアイコン(2026-09-14、ユーザー要望)と、
/// 記号リンク・エイリアスの**先の項目のアイコンに矢印のバッジを重ねたもの**(2026-09-29、ユーザー要望。Finder の「情報を見る」と同じ絵)。
///
/// ■ なぜ別に読むのか
/// 種類のアイコン(FileBrowserIconProvider)は**ファイルシステムに触らない**約束で、拡張子から引く。`.app` はそれだと
/// どれも同じ汎用のアプリのアイコンになり、アプリケーションフォルダを開くと見分けがつかなかった。アプリ固有のアイコンは
/// バンドルの中(Info.plist・Assets.car・.icns)を読まないと分からないので、`NSWorkspace.icon(forFile:)` を**FileIO の上で**
/// 呼び、決まった画素数の絵に描き写してから持ち帰る。記号リンク・エイリアスは自分の名前に拡張子が無いことが多く、
/// 種類だけで引くと白紙の書類になっていた。先の項目が何かはリンクを読まないと分からない。
///
/// ■ 記号リンク・エイリアスの先の決め方(2026-09-29 実測、docs/15「記号リンクとエイリアス」)
/// `NSWorkspace.icon(forFile:)` に記号リンクのパスを渡すと先のアイコンにバッジを重ねて返すが、Finder が作ったエイリアスは
/// 先がフォルダ・アプリのときしか解かれず、先がファイルなら白紙+バッジだった(エイリアス自身の名前で種類を引いている)。
/// そこでどちらも**先のパスを自分で決め**(`FileBrowserLinkResolver.backgroundTarget`: 触ってよい場所だけを段ごとに確かめる)、
/// 先のアイコンにバッジ(CoreTypes の `AliasBadgeIcon.icns`)を重ねる。
/// 場所の規則で**断った**のと、絵が**作れなかった**のは区別する(`AliasIconOutcome`): 断ったものは「失敗」として覚えない
/// ―― 後で共有が繋がる・利用者がその場所に入ることがある。
///
/// ■ 約束事(docs/15「サンドボックスと TCC の約束」)
/// - `NSWorkspace.icon(forFile:)` は応答しない共有の上では 30 秒ブロックしうる(FileBrowserIconProvider の型コメント)
///   ので、**メインアクターでは呼ばない**。スレッドから呼んでよい(AppKit のヘッダーで thread safe とされている)。
/// - バンドルの中・リンクの先を読むのは「ユーザーが入っていないフォルダを読む」ことなので、フォルダの絵と同じく
///   ネットワーク越しのボリュームと TCC の保護下の場所では読まない(`FileBrowserThumbnailProvider.kind(for:...)` が項目を、
///   `FileBrowserLinkResolver.backgroundTarget` が先を、同じ規則 `DirectoryProbe.mayReadUnentered` で見る)。
/// - `NSImage` は描くときに遅れて中身を読むことがあるので、**FileIO の上で描き終えた画素**(`PagePixelBuffer`)だけを渡す。
nonisolated enum FileBrowserSystemIcon {
    /// アプリケーションのバンドルか。**名前だけで決める**(ファイルに触らない)。記号リンクは先が別の場所なので除く
    /// (記号リンクの `.app` は `.alias` として先のアイコンになる)。
    static func isApplication(name: String, isPackage: Bool, isSymbolicLink: Bool) -> Bool {
        isPackage && !isSymbolicLink && (name as NSString).pathExtension.lowercased() == "app"
    }

    /// アプリのアイコンを `pixelSize` 四方の画素に描く。**FileIO の上で呼ぶ**(型コメント)。
    static func render(at url: URL, pixelSize: Int) -> PagePixelBuffer? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return render(pixelSize: pixelSize) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// `renderAlias` の結果。`refused`(場所の規則で先を読まなかった)と `unresolved`(先が決められない)は失敗として覚えない(型コメント)。
    enum AliasIconOutcome: Sendable {
        case made(PagePixelBuffer)
        /// 触ってはいけない場所(型コメント)。種類のアイコン+バッジのまま。リストはボリュームの着脱まで覚える。
        case refused
        /// 先が決められない(壊れたエイリアス・記号リンクの輪)。種類のアイコン+バッジのまま。覚えない ―― 先が戻れば決まる
        /// (`FileBrowserLinkResolver.Outcome` のコメント)。
        case unresolved
        /// 先は決まったが絵が作れなかった。
        case unavailable
    }

    /// 記号リンク・エイリアス `url` の先のアイコンに矢印のバッジを重ねて `pixelSize` 四方の画素に描く。**FileIO の上で呼ぶ**。
    ///
    /// - Parameter currentFolder: 利用者が見ているフォルダ。先がデスクトップ・書類・ダウンロードの中なら、同じ場所の中を
    ///   見ているときだけ読む(フォルダの絵と同じ規則)。
    static func renderAlias(
        at url: URL, currentFolder: URL?, mountTable: MountTable, pixelSize: Int,
        protectedPrefixes: [String] = DirectoryProbe.protectedPrefixes,
        categoryPrefixes: Set<String> = DirectoryProbe.categoryProtectedPrefixes
    ) -> AliasIconOutcome {
        let target: URL
        switch FileBrowserLinkResolver.backgroundOutcome(
            of: url, currentFolder: currentFolder, mountTable: mountTable,
            protectedPrefixes: protectedPrefixes, categoryPrefixes: categoryPrefixes
        ) {
        case .target(let resolved): target = resolved
        case .refused: return .refused
        case .unresolvable: return .unresolved
        }
        let icon = NSWorkspace.shared.icon(forFile: target.path)
        let badge = aliasBadge()
        let pixels = render(pixelSize: pixelSize) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            badge?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        return pixels.map { .made($0) } ?? .unavailable
    }

    /// Finder が記号リンク・エイリアスに重ねる矢印のバッジ(アイコンと同じ枠に描く、左下に矢印のある透明な絵)。
    /// 公開 API には無いので CoreTypes の絵を読む。無ければ nil(先のアイコンだけになる)。
    ///
    /// ファイルは 1 回だけ読む(`aliasBadgeData`。2026-09-29 の監査: 以前はリンク 1 件ごとに読んでいた)。`NSImage` は呼ぶたびに作る
    /// ―― FileIO の別々のスレッドから同時に描くので、1 つの `NSImage` を共有しない。
    static func aliasBadge() -> NSImage? {
        aliasBadgeData.flatMap { NSImage(data: $0) }
    }

    /// バッジの icns の中身(初回に 1 度読む。`static let` の初期化はスレッド安全)。
    private static let aliasBadgeData: Data? = try? Data(contentsOf: URL(fileURLWithPath: aliasBadgePath))

    static let aliasBadgePath = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AliasBadgeIcon.icns"

    /// `pixelSize` 四方の画素に `draw` で描く。
    private static func render(pixelSize: Int, draw: (NSRect) -> Void) -> PagePixelBuffer? {
        guard pixelSize > 0 else { return nil }
        return PagePixelBuffer(
            width: pixelSize, height: pixelSize, grayscale: false,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        ) { context in
            context.interpolationQuality = .high
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            draw(NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// リスト表示の行に出すシステムのアイコン(アプリ・記号リンク・エイリアス。16pt)。アプリで 1 つ。
///
/// アイコン表示は `FileBrowserThumbnailProvider`(大きさの段・LRU)を通すが、リストの行は 1 枚 32px(約 4KB)と小さく、
/// NSTableView のセルへ直接入れるので、ここで簡単に覚えておく。鍵はパスと更新日時(アプリを入れ替えたら読み直す)。
@MainActor
final class FileBrowserListSystemIcons {
    static let shared = FileBrowserListSystemIcons()

    static let pointSize: CGFloat = 16
    static let pixelSize = 32
    /// 覚えておく数の上限。超えたら丸ごと忘れる(読み直すだけで害は無い)。
    private static let countLimit = 2000

    private var cache: [String: NSImage] = [:]
    /// 読めなかった(アイコンが取れなかった)もの。この起動の間は試し直さない。
    private var failed: Set<String> = []
    /// 場所の規則で先を読まなかった記号リンク・エイリアス(`AliasIconOutcome.refused`)。鍵は項目の鍵と見ているフォルダ(規則の
    /// 材料)。**ボリュームが付いたり外れたりしたら忘れる**(繋がっていなかった先が繋がる)。失敗とは別に持つ ―― 2026-09-29 の監査:
    /// 覚えないと、共有を指すリンクの行が描き直されるたびに FileIO でリンクを読み直していた。
    private var refused: Set<String> = []
    private var loading: Set<String> = []
    private var volumeObservation: AnyCancellable?
    /// 同時に読むのは `maxConcurrentLoads` 件まで(2026-09-14 の 2 回目の監査。以前は上限が無く、アプリケーションフォルダをリストで
    /// スクロールすると行の数だけ FileIO のスレッドが同時に立った)。待っているものは**後から頼まれたものから**始める(画面に入ったばかりの行)。
    private static let maxConcurrentLoads = 4
    private var runningCount = 0
    private var waiting: [(
        key: String, refusedKey: String, render: @Sendable () -> FileBrowserSystemIcon.AliasIconOutcome,
        completion: @MainActor (NSImage) -> Void
    )] = []

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        volumeObservation = Publishers.MergeMany(
            workspace.publisher(for: NSWorkspace.didMountNotification),
            workspace.publisher(for: NSWorkspace.didUnmountNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refused.removeAll() }
        }
    }

    static func key(for entry: FileBrowserEntry) -> String { entry.identityKey }

    /// 断った記録の鍵(`refused`)。
    private static func refusedKey(_ key: String, currentFolder: URL?) -> String {
        key + "|" + (currentFolder?.path ?? "")
    }

    func cachedIcon(for entry: FileBrowserEntry) -> NSImage? {
        cache[Self.key(for: entry)]
    }

    /// 読んで、読めたら `completion` を呼ぶ。既に読んでいる最中・読めなかったものは何もしない。
    /// - Parameter currentFolder: 見ているフォルダ(記号リンク・エイリアスの先を読んでよいかの判断。`FileBrowserSystemIcon.renderAlias`)。
    func load(_ entry: FileBrowserEntry, currentFolder: URL?, completion: @escaping @MainActor (NSImage) -> Void) {
        let key = Self.key(for: entry)
        if let cached = cache[key] {
            completion(cached)
            return
        }
        let refusedKey = Self.refusedKey(key, currentFolder: currentFolder)
        guard !loading.contains(key), !failed.contains(key), !refused.contains(refusedKey) else { return }
        loading.insert(key)
        // 画素数は先に値で取り出す。`Self.pixelSize` はメインアクターの型の静的プロパティなので、FileIO へ渡す閉包の中では読めない。
        let pixelSize = Self.pixelSize
        let url = entry.url
        let render: @Sendable () -> FileBrowserSystemIcon.AliasIconOutcome
        if entry.isLink {
            let mountTable = MountTable.current()
            render = { FileBrowserSystemIcon.renderAlias(at: url, currentFolder: currentFolder, mountTable: mountTable, pixelSize: pixelSize) }
        } else {
            render = { FileBrowserSystemIcon.render(at: url, pixelSize: pixelSize).map { .made($0) } ?? .unavailable }
        }
        waiting.append((key, refusedKey, render, completion))
        startWaitingLoads()
    }

    private func startWaitingLoads() {
        while runningCount < Self.maxConcurrentLoads, let next = waiting.popLast() {
            runningCount += 1
            let (key, refusedKey, render, completion) = next
            Task { [weak self] in
                let outcome = await FileIO.perform { render() }
                guard let self else { return }
                self.runningCount -= 1
                self.loading.remove(key)
                defer { self.startWaitingLoads() }
                let image: CGImage?
                switch outcome {
                case .made(let pixels): image = pixels.makeImage()
                case .unavailable: image = nil
                // 先が決められない(壊れたエイリアス)。覚えない ―― 行が描き直されたらやり直す(先が戻っていれば決まる)。
                case .unresolved: return
                // 場所の規則で断った(型コメント)。ボリュームの着脱まで覚えておき、行が描き直されてもリンクを読み直さない(`refused`)。
                case .refused:
                    if self.refused.count >= Self.countLimit { self.refused.removeAll() }
                    self.refused.insert(refusedKey)
                    return
                }
                guard let image else {
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
