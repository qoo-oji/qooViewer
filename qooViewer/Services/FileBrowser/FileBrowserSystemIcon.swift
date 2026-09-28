import AppKit

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
/// そこでどちらも**先のパスを自分で決め**(`aliasTarget`)、先のアイコンにバッジ(CoreTypes の `AliasBadgeIcon.icns`)を
/// 重ねる。先のパスは**先に触らずに**決める ―― 記号リンクは `readlink` の字面を解き、エイリアスはブックマークデータに
/// 記録されたパスを読む(`URL.resourceValues(forKeys:fromBookmarkData:)`)。先が無ければブックマークを解く(マウントも
/// ダイアログも無しで)。そのパスを**段ごとに**、触ってよい場所か(ネットワーク越し・繋がっていないボリューム・TCC の保護下
/// ―― `aliasTarget` の gate)を確かめてから lstat し、途中の記号リンクも同じように追う(`followingSymbolicLinks`)。字面の
/// パスだけで判断すると、`~/nas → /Volumes/NAS` のようなローカルの記号リンクを経由する先を「ローカル」と読み違え、
/// `icon(forFile:)` が応答しない共有で 30 秒待った(レビュー 2026-09-29)。すべて通ってから `icon(forFile:)` を呼ぶ。
/// 場所の規則で**断った**のと、絵が**作れなかった**のは区別する(`AliasIconOutcome`): 断ったものは「失敗」として覚えない
/// ―― 後で共有が繋がる・利用者がその場所に入ることがある。
///
/// ■ 約束事(docs/15「サンドボックスと TCC の約束」)
/// - `NSWorkspace.icon(forFile:)` は応答しない共有の上では 30 秒ブロックしうる(FileBrowserIconProvider の型コメント)
///   ので、**メインアクターでは呼ばない**。スレッドから呼んでよい(AppKit のヘッダーで thread safe とされている)。
/// - バンドルの中・リンクの先を読むのは「ユーザーが入っていないフォルダを読む」ことなので、フォルダの絵と同じく
///   ネットワーク越しのボリュームと TCC の保護下の場所では読まない(`FileBrowserThumbnailProvider.kind(for:...)` が項目を、
///   `renderAlias` が先を、同じ規則 `DirectoryProbe.mayReadUnentered` で見る)。
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

    /// `renderAlias` の結果。`refused`(場所の規則で先を読まなかった)は失敗として覚えない(型コメント)。
    enum AliasIconOutcome: Sendable {
        case made(PagePixelBuffer)
        /// 先が決められない・触ってはいけない場所(型コメント)。種類のアイコン+バッジのまま。
        case refused
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
        guard let target = aliasTarget(
            of: url, currentFolder: currentFolder, mountTable: mountTable,
            protectedPrefixes: protectedPrefixes, categoryPrefixes: categoryPrefixes
        ) else { return .refused }
        let icon = NSWorkspace.shared.icon(forFile: target.path)
        let badge = aliasBadge()
        let pixels = render(pixelSize: pixelSize) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            badge?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        return pixels.map { .made($0) } ?? .unavailable
    }

    /// 記号リンク・エイリアス `url` の先。触ってよい場所(型コメントの gate)を段ごとに確かめながら記号リンクを追い、
    /// 途中で断れば nil。エイリアスは、記録されたパスに何も無いときだけブックマークを解く(同じボリュームの中でファイル ID で探す。
    /// マウントもダイアログも無し ―― `BookmarkResolution` は使わない: あれはアプリが保存したセキュリティスコープ付きの
    /// ブックマーク用で、エイリアスファイルのブックマークにスコープは無い)。解いた先ももう一度同じ規則で見る。
    /// **FileIO の上で呼ぶ**(リンク自身と、先の各段の lstat)。
    static func aliasTarget(
        of url: URL, currentFolder: URL?, mountTable: MountTable,
        protectedPrefixes: [String] = DirectoryProbe.protectedPrefixes,
        categoryPrefixes: Set<String> = DirectoryProbe.categoryProtectedPrefixes
    ) -> URL? {
        // 触ってよい場所か。ネットワーク越し・繋がっていないボリューム(`/Volumes/<名前>` が表に無い。触ると自動マウントや
        // 30 秒の待ちになりうる)・TCC の保護下(見ている場所と同じデスクトップ等の中を除く)は断る。**触らずに**決める。
        func mayRead(_ target: URL) -> Bool {
            !mountTable.isOnAnUnmountedVolume(target)
                && DirectoryProbe.mayReadUnentered(
                    target, from: currentFolder, mountTable: mountTable,
                    prefixes: protectedPrefixes, categoryPrefixes: categoryPrefixes
                )
        }
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return followingSymbolicLinks(symbolicLinkTarget(destination, linkAt: url), mayRead: mayRead)
        }
        guard let data = try? URL.bookmarkData(withContentsOf: url),
              let recorded = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path,
              let recordedTarget = followingSymbolicLinks(URL(fileURLWithPath: recorded), mayRead: mayRead)
        else { return nil }
        if FileManager.default.fileExists(atPath: recordedTarget.path) { return recordedTarget }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale
        ) else { return nil }
        return followingSymbolicLinks(resolved, mayRead: mayRead)
    }

    /// `path` の各段を、`mayRead` で確かめてから lstat し、記号リンクなら先(字面)に差し替えて先頭からやり直す。
    /// 記号リンクの無い絶対パスになったら返す。無い段に着いたら残りは字面のまま(先が無いのは `icon(forFile:)` が白紙を返すだけ)。
    /// 途中で `mayRead` が断る・`maxHops` を超える(ループ)・読めない記号リンクなら nil。**FileIO の上で呼ぶ**。
    static func followingSymbolicLinks(_ path: URL, mayRead: (URL) -> Bool, maxHops: Int = 32) -> URL? {
        var components = lexicalComponents(of: path.path)
        var hops = 0
        var index = 0
        while index < components.count {
            let prefix = URL(fileURLWithPath: "/" + components[0...index].joined(separator: "/"))
            guard mayRead(prefix) else { return nil }
            var status = stat()
            guard lstat(prefix.path, &status) == 0 else { break }
            if status.st_mode & S_IFMT == S_IFLNK {
                hops += 1
                guard hops <= maxHops,
                      let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix.path)
                else { return nil }
                let replaced = lexicalComponents(of: symbolicLinkTarget(destination, linkAt: prefix).path)
                components = replaced + components[(index + 1)...]
                index = 0
                continue
            }
            index += 1
        }
        // 無い段で止まった残りも含めて、最後のパス全体をもう一度確かめる(`icon(forFile:)` はこのパスを stat する)。
        let target = URL(fileURLWithPath: "/" + components.joined(separator: "/"))
        return mayRead(target) ? target : nil
    }

    /// `readlink` の値を絶対パスにする。相対ならリンクのあるフォルダから。`.`・`..` は**字面で**畳む(`standardizingPath` は
    /// `..` を実体で解こうとして先に触る)。
    static func symbolicLinkTarget(_ destination: String, linkAt link: URL) -> URL {
        let absolute = destination.hasPrefix("/")
            ? destination
            : link.deletingLastPathComponent().path + "/" + destination
        return URL(fileURLWithPath: "/" + lexicalComponents(of: absolute).joined(separator: "/"))
    }

    /// パスの段(`.`・`..` を字面で畳んだもの)。
    private static func lexicalComponents(of path: String) -> [String] {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(String(component))
            }
        }
        return components
    }

    /// Finder が記号リンク・エイリアスに重ねる矢印のバッジ(アイコンと同じ枠に描く、左下に矢印のある透明な絵)。
    /// 公開 API には無いので CoreTypes の絵を読む。無ければ nil(先のアイコンだけになる)。
    static func aliasBadge() -> NSImage? {
        NSImage(contentsOf: URL(fileURLWithPath: aliasBadgePath))
    }

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
    private var loading: Set<String> = []
    /// 同時に読むのは `maxConcurrentLoads` 件まで(2026-09-14 の 2 回目の監査。以前は上限が無く、アプリケーションフォルダをリストで
    /// スクロールすると行の数だけ FileIO のスレッドが同時に立った)。待っているものは**後から頼まれたものから**始める(画面に入ったばかりの行)。
    private static let maxConcurrentLoads = 4
    private var runningCount = 0
    private var waiting: [(key: String, render: @Sendable () -> FileBrowserSystemIcon.AliasIconOutcome, completion: @MainActor (NSImage) -> Void)] = []

    private init() {}

    static func key(for entry: FileBrowserEntry) -> String {
        "\(entry.id)|\(entry.modificationDate?.timeIntervalSinceReferenceDate ?? 0)"
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
        guard !loading.contains(key), !failed.contains(key) else { return }
        loading.insert(key)
        // 画素数は先に値で取り出す。`Self.pixelSize` はメインアクターの型の静的プロパティなので、FileIO へ渡す閉包の中では読めない。
        let pixelSize = Self.pixelSize
        let url = entry.url
        let render: @Sendable () -> FileBrowserSystemIcon.AliasIconOutcome
        if entry.isSymbolicLink || entry.isAliasFile {
            let mountTable = MountTable.current()
            render = { FileBrowserSystemIcon.renderAlias(at: url, currentFolder: currentFolder, mountTable: mountTable, pixelSize: pixelSize) }
        } else {
            render = { FileBrowserSystemIcon.render(at: url, pixelSize: pixelSize).map { .made($0) } ?? .unavailable }
        }
        waiting.append((key, render, completion))
        startWaitingLoads()
    }

    private func startWaitingLoads() {
        while runningCount < Self.maxConcurrentLoads, let next = waiting.popLast() {
            runningCount += 1
            let (key, render, completion) = next
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
                // 場所の規則で断った(型コメント)。覚えない ―― 行が作り直されたら、また安い判定からやり直す(先には触っていない)。
                case .refused: return
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
