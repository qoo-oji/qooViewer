import CryptoKit
import Foundation

/// ファイルブラウザの絵の鍵(改善要望7 段階 7a)。**`<ボリューム>-<inode>-<更新日時>-<サイズ>`**(検討メモ §6.3)。
///
/// パスではなく inode で持つのは、名前を変えた・移動した項目の絵を作り直さないため。inode だけにしないのは、
/// 外で中身を差し替えたファイルに古い絵が出続けるのと、消した項目の inode が別の項目に使い回されて無関係な絵が
/// 出るのを避けるため(qooLibrary はこれで誤った絵が残った)。ボリュームは `MountTable.volumeIdentifier`
/// (マウント順で変わらない UUID。`st_dev` は他のボリュームを先に挿すだけで変わる)。
nonisolated struct FileBrowserThumbnailKey: Hashable, Sendable {
    let volume: String
    let inode: UInt64
    /// 更新日時(ナノ秒)。
    let modified: Int64
    let size: Int64
    /// 同じ項目から作る別の絵(コレクション表紙に指定した本の中のページ。`"shelfPage:<ページのキー>"`)。
    /// nil は項目の先頭の絵(従来の鍵。**nil のときはファイル名の計算に入れない**ので、既存のキャッシュはそのまま当たる)。
    var variant: String? = nil

    /// 絵の作り方の世代。**選び方や大きさを変えたら上げる**(古い絵は鍵が合わなくなり、刈り込みで消える)。
    static let generation = 1

    /// 項目の今の状態から鍵を作る。**リンクを辿らない**(lstat)。ブロッキングするので FileIO の上で呼ぶ。
    static func of(_ url: URL, mountTable: MountTable) -> FileBrowserThumbnailKey? {
        var info = stat()
        guard lstat(url.path, &info) == 0, let volume = mountTable.volumeIdentifier(url) else { return nil }
        return FileBrowserThumbnailKey(
            volume: volume, inode: info.st_ino,
            // **桁あふれで落とさない**(2026-09-14 の監査 12)。APFS は mtime をクランプするが、SMB / NFS / 他社ドライバの壊れた日時では
            // `tv_sec * 10^9` が Int64 を超えてトラップした。鍵は同じ日時に同じ値が出れば足りるので、折り返す演算で作る。
            modified: Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec),
            size: Int64(info.st_size)
        )
    }

    /// ディスクの上のファイル名。ボリュームの識別子には `/` や `:` が入りうるので、ハッシュにする。
    var fileName: String {
        var text = "\(Self.generation)|\(volume)|\(inode)|\(modified)|\(size)"
        if let variant { text += "|\(variant)" }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
}

/// ファイルブラウザの絵のディスクキャッシュ(改善要望7 段階 7a、2026-09-14)。
/// `~/Library/Caches/<bundle id>/FileBrowserThumbnails/<先頭 2 文字>/<鍵のハッシュ>.jpg`(長辺 512px、JPEG 0.8)。
///
/// ■ ページサムネイル(ThumbnailDiskCache)と違い、**既定で有効**(上限 200MB)
/// あちらは「黙って数百 MB になっていた」という報告で既定を OFF にした。こちらは書庫の多いフォルダを開くたびに
/// 全冊の索引を読み直すことになるので、ユーザーの判断(2026-09-14)で既定を ON にし、代わりに環境設定「キャッシュ」に
/// ON/OFF・上限・使用量・削除を並べて**見える**ようにした。OFF にするとその場で消える。
///
/// 刈り込みの規則(上限を超えたら最終アクセスの古い順に 8 割まで)と、読み書きを actor の外で行う作りは
/// ThumbnailDiskCache と同じ(刈り込みの本体はあちらの `trimIfNeeded` を使う)。
actor FileBrowserThumbnailDiskCache {
    static let shared = FileBrowserThumbnailDiskCache()

    static let maxPixelSize: CGFloat = 512
    static let jpegQuality: CGFloat = 0.8

    struct Configuration: Sendable, Equatable {
        var isEnabled: Bool
        var maxTotalBytes: Int
    }

    /// configure が届くまでは無効(起動直後、設定を読む前に書き始めない。ThumbnailDiskCache と同じ)。
    private var configuration = Configuration(isEnabled: false, maxTotalBytes: 200 * 1024 * 1024)
    private var hasConfigured = false
    private var lastConfigurationGeneration: UInt64 = 0
    private var hasTrimmed = false
    private var bytesWrittenSinceTrim = 0

    /// 置き場所。`nil` なら常にミスする。リソースモニタ(StorageUsageScanner)が内訳の切り分けに読む。
    nonisolated let directory: URL?

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            .map { base in
                base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "qooViewer", isDirectory: true)
                    .appendingPathComponent("FileBrowserThumbnails", isDirectory: true)
            }
    }

    /// 保存先を指定して作る。**テストのための口**(実物のキャッシュに書かない)。`isEnabled` の既定は有効。
    init(directory: URL?, configuration: Configuration = Configuration(isEnabled: true, maxTotalBytes: 200 * 1024 * 1024)) {
        self.directory = directory
        self.configuration = configuration
        hasConfigured = true
    }

    private nonisolated func fileURL(for key: FileBrowserThumbnailKey) -> URL? {
        guard let directory else { return nil }
        let name = key.fileName
        return directory.appendingPathComponent(String(name.prefix(2)), isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - 読み書き

    /// 保存してある JPEG。無ければ nil。読めたら最終アクセスとして更新日時を触る(刈り込みの基準)。
    /// `@concurrent`: 呼び出し側(メインアクター)の上でファイルを読まない(ThumbnailDiskCache.thumbnail のコメント)。
    @concurrent nonisolated func data(for key: FileBrowserThumbnailKey) async -> Data? {
        guard await isEnabled, let url = fileURL(for: key), let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    /// 保存してあるか(読まず、最終アクセスも触らない)。先に作っておく役(FileBrowserVideoThumbnailWarmer)が、作り済みの
    /// 動画を飛ばすのに使う ―― 数千本を見て回るたびに JPEG を読んだり刈り込みの順番を動かしたりしない。
    @concurrent nonisolated func contains(_ key: FileBrowserThumbnailKey) async -> Bool {
        guard await isEnabled, let url = fileURL(for: key) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @concurrent nonisolated func store(_ data: Data, for key: FileBrowserThumbnailKey) async {
        guard await isEnabled, let url = fileURL(for: key) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 書き込み途中のファイルを読み手に見せない(.atomic は一時ファイルから rename する)。
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        // 書いている間に OFF になった(その場で消した後に書いた)なら、書いたものも消す(2026-09-14 の 2 回目の監査。以前は OFF にした
        // 瞬間に走っていた書き込みが、空にしたはずのキャッシュに残った)。
        guard await isEnabled else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let limit = await claimTrim(afterWriting: data.count), let directory else { return }
        ThumbnailDiskCache.trimIfNeeded(in: directory, maxTotalBytes: limit)
    }

    var isEnabled: Bool { configuration.isEnabled }

    /// 先に作っておく役(FileBrowserVideoThumbnailWarmer)が、1 回の掃引で書いてよいバイト数。**上限の半分から、いまの使用量を引いた残り**
    /// (2026-09-14 の 2 回目の監査 22)。以前の先読み役は上限を知らずに書き続け、上限を超える量の動画がよく使う項目にあると、刈り込みが
    /// 作ったばかりの絵やアイコン表示の絵を追い出し、次の起動でまた作り直す、を繰り返した。残りの半分はアイコン表示が見たものに空けておく。
    /// 使用量はディスクを数える(掃引の始めに 1 回だけ呼ぶ)。
    @concurrent nonisolated func bytesAvailableForWarming() async -> Int {
        guard let directory else { return 0 }
        let limit = await configuration.maxTotalBytes
        return max(0, limit / 2 - Self.totalBytes(in: directory))
    }

    // MARK: - 設定(AppPreferences が押し込む)

    /// OFF になったらその場で消し、有効化・上限を下げたときは書き込みを待たずに刈り込む。起動後の最初の 1 回は
    /// 値が変わっていなくても後始末を走らせる。古い世代の呼び出しは捨てる(ThumbnailDiskCache.configure と同じ)。
    func configure(isEnabled: Bool, maxTotalBytes: Int, generation: UInt64) {
        guard generation > lastConfigurationGeneration else { return }
        lastConfigurationGeneration = generation
        let previous = configuration
        let isFirst = !hasConfigured
        hasConfigured = true
        configuration = Configuration(isEnabled: isEnabled, maxTotalBytes: maxTotalBytes)
        guard let directory, isFirst || previous != configuration else { return }
        guard isEnabled else {
            hasTrimmed = false
            bytesWrittenSinceTrim = 0
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
            return
        }
        guard isFirst || !previous.isEnabled || maxTotalBytes < previous.maxTotalBytes else { return }
        hasTrimmed = true
        bytesWrittenSinceTrim = 0
        Task.detached(priority: .utility) {
            ThumbnailDiskCache.trimIfNeeded(in: directory, maxTotalBytes: maxTotalBytes)
        }
    }

    private func claimTrim(afterWriting bytes: Int) -> Int? {
        guard configuration.isEnabled else { return nil }
        bytesWrittenSinceTrim += bytes
        guard !hasTrimmed || bytesWrittenSinceTrim >= ThumbnailDiskCache.trimThreshold(for: configuration.maxTotalBytes)
        else { return nil }
        hasTrimmed = true
        bytesWrittenSinceTrim = 0
        return configuration.maxTotalBytes
    }

    // MARK: - 使用量と削除(環境設定「キャッシュ」)

    @concurrent nonisolated func totalBytes() async -> Int {
        guard let directory else { return 0 }
        return Self.totalBytes(in: directory)
    }

    private nonisolated static func totalBytes(in directory: URL) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys)
        else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    /// 丸ごと消す。削除は actor の外で行い、終わってから戻る(呼び出し側が使用量を測り直す)。
    func removeAll() async {
        guard let directory else { return }
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
        hasTrimmed = false
        bytesWrittenSinceTrim = 0
    }
}
