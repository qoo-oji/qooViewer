import Foundation
import SwiftUI

/// サイドパネル・ホームのインスペクタのリソースモニタの下部に出す「異常」。v1.29で直した種類のリソースの
/// 過剰消費(設定を無視してメモリが膨らむ・一時ファイルが残る)が再発したとき、ユーザーが
/// ひと目で気づけるようにするためのもの(ユーザー要望)。
///
/// 種類ごとに「何が起きているか」(title)と「それが何を意味するか」(detail)を持つ。
///
/// 2026-10-11 のリソースモニタの点検で、このウインドウの本の 3 つのキャッシュとページのサムネイルのディスクキャッシュだけだった
/// 判定を、メモリの内訳(MemoryUsageRegistry)の上限付きの全員、ファイルブラウザのディスクキャッシュ、ページ一覧のキャッシュ、
/// コレクションのタイル、ネットワークボリュームの写しへ広げた(利用者の要望)。
enum ResourceAnomaly: Hashable, Identifiable {
    /// 上限付きのメモリキャッシュが、上限を超えたまま(どの持ち主のものでも。種類ごとに 1 つにまとめる)。
    case memoryOverLimit(MemoryUsageKind)
    /// 環境設定の「前後に先読みするページ数」より広い範囲を先読みしている(このウインドウの本)。
    case prefetchWiderThanSetting
    /// サムネイルのディスクキャッシュがOFFなのに、ディスクにファイルが残っている。
    case diskCacheDisabledButPresent
    /// サムネイルのディスクキャッシュが、上限(+刈り込みの余裕)を超えている。
    case diskCacheOverLimit
    /// ファイルブラウザのサムネイルのディスクキャッシュがOFFなのに、ファイルが残っている。
    case fileBrowserCacheDisabledButPresent
    /// ファイルブラウザのサムネイルのディスクキャッシュが、上限(+刈り込みの余裕)を超えている。
    case fileBrowserCacheOverLimit
    /// ページ一覧のキャッシュが上限を大きく(2 倍)超えている。
    case pageListCacheFarOverLimit
    /// コレクションのタイルが上限を大きく(2 倍)超えている。
    case collectionTilesFarOverLimit
    /// 他の(終了済みの)起動が残した一時ファイルがある。起動時に掃除されるはずのもの。
    case staleTemporaryFiles
    /// 本を読んでいるものが無いのに、この起動の入れ子の書庫の一時ファイルが残っている。
    case orphanTemporaryFiles
    /// 読み込み層(StagedFileRegistry)が知らないネットワークボリュームの写しが残っている。
    case orphanNetworkCopies

    var id: Self { self }

    /// メモリの上限超過を判定する種類(上限を持ち、上限を超えないはずのもの)。入れ子の書庫は 1 本が上限より大きいことがあり
    /// (その 1 本はメモリへ置かずに一時ファイルにするが、判定の材料が別)、ここでは見ない。
    static let memoryKindsWithLimit: [MemoryUsageKind] = [
        .pageImages, .thumbnails, .gridThumbnails, .fileBrowserThumbnails, .collectionCovers, .collectionTiles,
    ]

    var title: LocalizedStringKey {
        switch self {
        case .memoryOverLimit(let kind):
            switch kind {
            case .pageImages: return "Page images exceed the memory limit"
            case .thumbnails: return "Thumbnails exceed their memory limit"
            case .gridThumbnails: return "Enlarged thumbnails exceed their memory limit"
            case .fileBrowserThumbnails: return "File browser and smart library thumbnails exceed their memory limit"
            case .collectionCovers: return "Collection covers exceed their memory limit"
            case .collectionTiles: return "Collection tiles exceed their memory limit"
            default: return "Memory exceeds its limit"
            }
        case .prefetchWiderThanSetting: return "Preloading more pages than set"
        case .diskCacheDisabledButPresent: return "Disk cache is off but files remain"
        case .diskCacheOverLimit: return "Disk cache exceeds its limit"
        case .fileBrowserCacheDisabledButPresent: return "File browser thumbnail cache is off but files remain"
        case .fileBrowserCacheOverLimit: return "File browser thumbnail cache exceeds its limit"
        case .pageListCacheFarOverLimit: return "Page list cache is far over its limit"
        case .collectionTilesFarOverLimit: return "Collection tiles are far over their limit"
        case .staleTemporaryFiles: return "Temporary files from a previous launch remain"
        case .orphanTemporaryFiles: return "Temporary files remain with no book open"
        case .orphanNetworkCopies: return "Copies of network volume books remain"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .memoryOverLimit(let kind):
            switch kind {
            case .pageImages:
                return "The decoded page images kept in memory have stayed above the “Page images kept in memory” setting for several seconds. The cache should evict older pages as soon as the limit is reached."
            case .thumbnails:
                return "The progress-bar thumbnails kept in memory have stayed above their built-in limit for several seconds."
            case .gridThumbnails:
                return "The enlarged thumbnails kept in memory have stayed above their built-in limit for several seconds."
            default:
                return "A memory cache has stayed above its built-in limit for several seconds. The cache should evict the pictures used longest ago as soon as the limit is reached."
            }
        case .prefetchWiderThanSetting:
            return "Pages outside the “Pages to preload before and after” range are being loaded ahead. Preloading should stay within that range."
        case .diskCacheDisabledButPresent:
            return "“Save page thumbnails to disk” is off, but the thumbnail folder still contains files. Turning the setting off should delete them."
        case .diskCacheOverLimit:
            return "The thumbnail folder is larger than the “Maximum size” setting, beyond the slack the cache allows itself before trimming."
        case .fileBrowserCacheDisabledButPresent:
            return "“Cache File Browser Thumbnails on Disk” is off, but its folder still contains files. Turning the setting off should delete them."
        case .fileBrowserCacheOverLimit:
            return "The file browser thumbnail folder is larger than its “Maximum Size” setting, beyond the slack the cache allows itself before trimming."
        case .pageListCacheFarOverLimit:
            return "The page list cache is more than twice its limit. It is trimmed once per launch, so going somewhat over during a long session is normal, but not this much."
        case .collectionTilesFarOverLimit:
            return "The collection tile folder is more than twice its limit. It is trimmed after every few hundred tiles, so going somewhat over is normal, but not this much."
        case .staleTemporaryFiles:
            return "Temporary files left by a previous launch (extracted nested archives or copies of network volume books) are still in the temporary folder. They should be removed automatically at launch."
        case .orphanTemporaryFiles:
            return "Extracted nested archives from this launch are still in the temporary folder although nothing is reading a book. They should be removed when a book is closed."
        case .orphanNetworkCopies:
            return "Local copies of books on a network volume are still in the temporary folder although nothing is reading them any more. They should be removed shortly after a book is closed."
        }
    }
}

/// 異常の判定役。入力(最新のスナップショット・メモリの内訳・走査結果・設定)から`[ResourceAnomaly]`を出す。
///
/// ■ 誤報を出さないための設計
/// ここは「何も出ない=正常」を信じてもらう場所なので、瞬間的な値で鳴らさない。
/// - メモリキャッシュの上限超過は、`persistenceThreshold`回(3秒)連続したときだけ異常にする。持ち主ごと・種類ごとに数える。
///   現在のキャッシュ(PagePixelCache など)は入れた直後に追い出すので瞬間的にも超えないはずだが、
///   1枚が上限より大きい場合はその1枚を残す仕様なので、それを誤報にしない。
/// - 先読みの判定は「残留しているページ」ではなく「先読みタスクが走っているページ」で見る。
///   残留は上限内ならいくら残っていても正常(それがキャッシュの役目)。
/// - ディスクキャッシュの上限超過は、本体の刈り込みの余裕(`ThumbnailDiskCache.trimThreshold`)を
///   足した値を境目にする。本体が「まだ刈り込まなくてよい」と判断する範囲は異常ではない。
///   ページ一覧のキャッシュ(起動ごとに 1 度だけ刈り込む)とコレクションのタイル(数百枚ごと)は、刈り込みの間に上限を超えるのが
///   仕様なので、上限の 2 倍を超えたときだけにする(刈り込みが働いていないことを捕まえる)。
/// - 一時ファイルの「持ち主がいない」は走査 2 回(30 秒)連続のときだけ。本を開いている途中(BookLoader が書庫を展開した直後で
///   読む側がまだ届け出ていない)・本を閉じた直後(読み込み層は 30 秒の猶予で写しを残す)を誤報にしない。
///
/// ウインドウごとに1つ(持続回数の状態を持つため)。
@MainActor
final class ResourceAnomalyDetector {
    /// 連続して何回(=何秒)超過していたら異常とみなすか。
    static let persistenceThreshold = 3
    /// 一時ファイルの「持ち主がいない」を何回の走査で続けて見たら異常とみなすか。
    static let orphanScanThreshold = 2

    private struct StreakKey: Hashable {
        var ownerID: UUID
        var kind: MemoryUsageKind
    }

    private var overLimitStreaks: [StreakKey: Int] = [:]
    private var lastOrphanScanAt: Date?
    private var orphanScanStreak = 0
    private var orphanNetworkCopyScanStreak = 0

    struct Input {
        /// このウインドウの本(先読みの判定に使う)。
        var bookSnapshot: ResourceMonitorSnapshot?
        /// メモリの内訳の全員(MemoryUsageRegistry.report())。
        var memory: [MemoryUsageOwner] = []
        var storage: StorageUsage?
        var isDiskCacheEnabled: Bool
        var diskCacheLimitBytes: Int
        var isFileBrowserCacheEnabled: Bool = true
        var fileBrowserCacheLimitBytes: Int = .max
        /// 本を読んでいる持ち主の数(MemoryUsageBreakdown.bookReaderCount)。
        var bookReaderCount: Int
        /// 読み込み層が知っているネットワークボリュームの写しの数(StagedFileRegistry.liveCount)。
        var liveNetworkCopyCount: Int = 0
    }

    /// 1秒ごとに呼ぶ(持続回数の単位が呼び出し回数なので、呼ぶ間隔を変えたら
    /// `persistenceThreshold`の意味も変わることに注意)。
    ///
    /// - Parameter advancingStreaks: false なら持続回数を進めずに今の回数で判定する。1 秒ごとの拍以外(ディスクの走査が
    ///   終わったとき・「今すぐ更新」)から呼ぶときに渡す ―― 以前はそれらも回数を進め、3 秒続く前に上限の超過を異常と出した
    ///   (2026-10-04 の監査 SP-12)。
    func evaluate(advancingStreaks: Bool = true, _ input: Input) -> [ResourceAnomaly] {
        var found: [ResourceAnomaly] = []

        // メモリの上限超過(持ち主ごと・種類ごとに数え、種類ごとに 1 つにまとめて出す)。
        // いなくなった持ち主の回数は捨てる(閉じた本の回数を、次に開いた本へ持ち越さない)。
        let presentOwners = Set(input.memory.map(\.id))
        overLimitStreaks = overLimitStreaks.filter { presentOwners.contains($0.key.ownerID) }
        var overKinds = Set<MemoryUsageKind>()
        for owner in input.memory {
            for item in owner.items where ResourceAnomaly.memoryKindsWithLimit.contains(item.kind) {
                let key = StreakKey(ownerID: owner.id, kind: item.kind)
                let persisted = advancingStreaks
                    ? persists(key, item.isOverLimit) : hasPersisted(key, item.isOverLimit)
                if persisted { overKinds.insert(item.kind) }
            }
        }
        for kind in ResourceAnomaly.memoryKindsWithLimit where overKinds.contains(kind) {
            found.append(.memoryOverLimit(kind))
        }

        if let book = input.bookSnapshot, book.isPrefetchingBeyondRadius {
            found.append(.prefetchWiderThanSetting)
        }

        if let storage = input.storage {
            if let diskCacheBytes = storage.thumbnailCacheBytes {
                if !input.isDiskCacheEnabled, diskCacheBytes > 0 {
                    found.append(.diskCacheDisabledButPresent)
                } else if input.isDiskCacheEnabled,
                          diskCacheBytes > input.diskCacheLimitBytes
                            + ThumbnailDiskCache.trimThreshold(for: input.diskCacheLimitBytes) {
                    found.append(.diskCacheOverLimit)
                }
            }
            if let fileBrowserBytes = storage.fileBrowserThumbnailCacheBytes {
                if !input.isFileBrowserCacheEnabled, fileBrowserBytes > 0 {
                    found.append(.fileBrowserCacheDisabledButPresent)
                } else if input.isFileBrowserCacheEnabled,
                          fileBrowserBytes > input.fileBrowserCacheLimitBytes
                            + ThumbnailDiskCache.trimThreshold(for: input.fileBrowserCacheLimitBytes) {
                    found.append(.fileBrowserCacheOverLimit)
                }
            }
            if let pageListBytes = storage.pageListCacheBytes, pageListBytes > BookPageListCache.maxTotalBytes * 2 {
                found.append(.pageListCacheFarOverLimit)
            }
            if let tileBytes = storage.collectionTileBytes, tileBytes > CollectionTileImageStore.maxTotalBytes * 2 {
                found.append(.collectionTilesFarOverLimit)
            }
            if storage.staleTemporaryEntryCount > 0 {
                found.append(.staleTemporaryFiles)
            }
            // 走査 1 回につき 1 度だけ数える(1 秒ごとに同じ走査結果を渡されても進めない)。
            if storage.scannedAt != lastOrphanScanAt {
                lastOrphanScanAt = storage.scannedAt
                let isOrphan = input.bookReaderCount == 0 && storage.nestedTemporaryFileCount > 0
                orphanScanStreak = isOrphan ? orphanScanStreak + 1 : 0
                let hasOrphanCopies = storage.stagedTemporaryFileCount > input.liveNetworkCopyCount
                orphanNetworkCopyScanStreak = hasOrphanCopies ? orphanNetworkCopyScanStreak + 1 : 0
            }
            if orphanScanStreak >= Self.orphanScanThreshold {
                found.append(.orphanTemporaryFiles)
            }
            if orphanNetworkCopyScanStreak >= Self.orphanScanThreshold {
                found.append(.orphanNetworkCopies)
            }
        }

        return found
    }

    /// `persists`の、回数を動かさない版(`evaluate(advancingStreaks: false, _:)`)。今が超過していて、これまでの拍で
    /// 既に`persistenceThreshold`回続いていれば true。
    private func hasPersisted(_ key: StreakKey, _ condition: Bool) -> Bool {
        condition && (overLimitStreaks[key] ?? 0) >= Self.persistenceThreshold
    }

    /// `condition`が`persistenceThreshold`回連続でtrueならtrue。falseが来たらリセット。
    private func persists(_ key: StreakKey, _ condition: Bool) -> Bool {
        guard condition else {
            overLimitStreaks[key] = 0
            return false
        }
        let streak = (overLimitStreaks[key] ?? 0) + 1
        overLimitStreaks[key] = streak
        return streak >= Self.persistenceThreshold
    }
}
