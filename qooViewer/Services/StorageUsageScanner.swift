import Foundation

/// サンドボックスのコンテナ(`~/Library/Containers/<bundle id>/Data`)がディスク上で占めている
/// 容量の内訳。サイドパネルのリソースモニタが表示する。
///
/// すべてバイト数。`nil`は「測れなかった」(ディレクトリが無い・読めない)で、0とは区別する。
nonisolated struct StorageUsage: Equatable, Sendable {
    /// コンテナ全体(下の内訳の合計+その他)。
    var containerBytes: Int?
    /// この起動が作った一時ファイル(入れ子の書庫の展開物。`TemporaryFileStore.sessionDirectory`)。
    var sessionTemporaryBytes: Int
    /// この起動の一時ファイルの個数(「本を開いていないのに残っている」の判定用)。
    var sessionTemporaryFileCount: Int
    /// 他の(もう生きていない)セッションが残した一時ファイル。起動時に掃除されるので通常0。
    /// 0でないこと自体が異常なので、内訳としては表示せず異常判定にだけ使う。
    var staleTemporaryBytes: Int
    var staleTemporaryEntryCount: Int
    /// サムネイルのディスクキャッシュ(ThumbnailDiskCache)。
    var thumbnailCacheBytes: Int?
    /// SwiftDataのストア(`default.store` + `-wal` + `-shm`)。
    var databaseBytes: Int?
    var scannedAt: Date

    /// コンテナ全体から、内訳として名前の付いているものを除いた残り。
    var otherBytes: Int? {
        guard let containerBytes else { return nil }
        let known = sessionTemporaryBytes + staleTemporaryBytes + (thumbnailCacheBytes ?? 0) + (databaseBytes ?? 0)
        return max(containerBytes - known, 0)
    }
}

/// `StorageUsage`を実際に測る。ディレクトリの全走査を伴うので、**必ずメインアクターの外**
/// (`Task.detached`)で呼ぶこと。走査の重さはコンテナの中身に比例し、サムネイルキャッシュを
/// 上限いっぱい(2000MB、数万ファイル)まで使っていれば1秒前後かかりうる。
///
/// ■ シンボリックリンクは辿らない
/// コンテナの`Library/Application Support/`には`AddressBook`・`iCloud`など**コンテナの外を
/// 指すシンボリックリンク**がOSによって置かれている(実機で確認)。辿ると他所の容量を
/// 数えてしまうか、サンドボックスに拒否される。`FileManager.enumerator`はリンク先へ
/// 降りないが、リンク自体のサイズ(数十バイト)が`fileSize`に乗るので、`isSymbolicLinkKey`で
/// 明示的に除外している。
///
/// nonisolated: 状態を持たない。`Task.detached`の中から呼ぶため。
nonisolated enum StorageUsageScanner {
    /// 内訳の切り分けに使う場所。走査は`Task.detached`で行うが、`ThumbnailDiskCache.shared`や
    /// `QooViewerApp.modelConfiguration`の参照はメインアクターに縛られているものがあるため、
    /// 呼び出し側がメインアクター上で作って渡す。
    struct Locations: Sendable {
        var containerRoot: URL
        var sessionTemporaryDirectory: URL
        var temporaryRoot: URL
        var thumbnailCacheDirectory: URL?
        var databaseStoreURL: URL
    }

    /// 呼び出し側のTaskが取り消されたら、途中で打ち切ってnilを返す(ディレクトリの列挙の
    /// 途中でTask.isCancelledを見る)。「今すぐ更新」の連打で走査が丸ごと並走しないため。
    static func scan(_ locations: Locations) -> StorageUsage? {
        let session = directorySize(at: locations.sessionTemporaryDirectory)
        let stale = staleTemporarySize(in: locations.temporaryRoot)
        let container = directorySize(at: locations.containerRoot)
        guard !Task.isCancelled else { return nil }
        return StorageUsage(
            containerBytes: container.map(\.bytes),
            sessionTemporaryBytes: session?.bytes ?? 0,
            sessionTemporaryFileCount: session?.fileCount ?? 0,
            staleTemporaryBytes: stale.bytes,
            staleTemporaryEntryCount: stale.entryCount,
            thumbnailCacheBytes: locations.thumbnailCacheDirectory.flatMap { directorySize(at: $0)?.bytes },
            databaseBytes: databaseSize(storeURL: locations.databaseStoreURL),
            scannedAt: Date()
        )
    }

    private struct DirectorySize {
        var bytes: Int
        var fileCount: Int
    }

    private static let sizeKeys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]

    /// ディレクトリが存在しなければnil(「無い」と「空」を区別する)。
    private static func directorySize(at directory: URL) -> DirectorySize? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: Array(sizeKeys), options: []
              )
        else { return nil }
        var total = 0
        var count = 0
        for case let url as URL in enumerator {
            if Task.isCancelled { return nil }
            guard let values = try? url.resourceValues(forKeys: sizeKeys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true
            else { continue }
            total += values.fileSize ?? 0
            count += 1
        }
        return DirectorySize(bytes: total, fileCount: count)
    }

    /// `tmp/`直下で、他セッションの残骸と判定されるエントリの合計。判定は起動時の掃除と
    /// 同じ`TemporaryFileStore.isStaleEntry`。
    private static func staleTemporarySize(in temporaryRoot: URL) -> (bytes: Int, entryCount: Int) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporaryRoot, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        var bytes = 0
        var count = 0
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = values?.isDirectory ?? false
            guard TemporaryFileStore.isStaleEntry(entry, isDirectory: isDirectory) else { continue }
            count += 1
            bytes += isDirectory ? (directorySize(at: entry)?.bytes ?? 0) : (values?.fileSize ?? 0)
        }
        return (bytes, count)
    }

    /// ストア本体が無ければnil。WAL/SHMは無いことも普通なので、あるぶんだけ足す。
    private static func databaseSize(storeURL: URL) -> Int? {
        func size(_ url: URL) -> Int? {
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
        guard let base = size(storeURL) else { return nil }
        let directory = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        return base
            + (size(directory.appendingPathComponent(name + "-wal")) ?? 0)
            + (size(directory.appendingPathComponent(name + "-shm")) ?? 0)
    }
}
