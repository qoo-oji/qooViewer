import Foundation
import SwiftUI

/// サイドパネルのリソースモニタの下部に出す「異常」。v1.29で直した種類のリソースの
/// 過剰消費(設定を無視してメモリが膨らむ・一時ファイルが残る)が再発したとき、ユーザーが
/// ひと目で気づけるようにするためのもの(ユーザー要望)。
///
/// 種類ごとに「何が起きているか」(title)と「それが何を意味するか」(detail)を持つ。
enum ResourceAnomaly: Hashable, Identifiable {
    /// ページ画像のメモリキャッシュが、環境設定の上限を超えたまま。
    case pageImageCacheOverLimit
    /// 進捗バー用サムネイルのキャッシュが上限超過のまま。
    case thumbnailCacheOverLimit
    /// 拡大サムネイルのキャッシュが上限超過のまま。
    case gridThumbnailCacheOverLimit
    /// 環境設定の「前後に先読みするページ数」より広い範囲を先読みしている。
    case prefetchWiderThanSetting
    /// サムネイルのディスクキャッシュがOFFなのに、ディスクにファイルが残っている。
    case diskCacheDisabledButPresent
    /// サムネイルのディスクキャッシュが、上限(+刈り込みの余裕)を超えている。
    case diskCacheOverLimit
    /// 他の(終了済みの)起動が残した一時ファイルがある。起動時に掃除されるはずのもの。
    case staleTemporaryFiles
    /// 本を1冊も開いていないのに、この起動の一時ファイルが残っている。
    case orphanTemporaryFiles

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .pageImageCacheOverLimit: return "Page images exceed the memory limit"
        case .thumbnailCacheOverLimit: return "Thumbnails exceed their memory limit"
        case .gridThumbnailCacheOverLimit: return "Enlarged thumbnails exceed their memory limit"
        case .prefetchWiderThanSetting: return "Preloading more pages than set"
        case .diskCacheDisabledButPresent: return "Disk cache is off but files remain"
        case .diskCacheOverLimit: return "Disk cache exceeds its limit"
        case .staleTemporaryFiles: return "Temporary files from a previous launch remain"
        case .orphanTemporaryFiles: return "Temporary files remain with no book open"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .pageImageCacheOverLimit:
            return "The decoded page images kept in memory have stayed above the “Page images kept in memory” setting for several seconds. The cache should evict older pages as soon as the limit is reached."
        case .thumbnailCacheOverLimit:
            return "The progress-bar thumbnails kept in memory have stayed above their built-in limit for several seconds."
        case .gridThumbnailCacheOverLimit:
            return "The enlarged thumbnails kept in memory have stayed above their built-in limit for several seconds."
        case .prefetchWiderThanSetting:
            return "Pages outside the “Pages to preload before and after” range are being loaded ahead. Preloading should stay within that range."
        case .diskCacheDisabledButPresent:
            return "“Save page thumbnails to disk” is off, but the thumbnail folder still contains files. Turning the setting off should delete them."
        case .diskCacheOverLimit:
            return "The thumbnail folder is larger than the “Maximum size” setting, beyond the slack the cache allows itself before trimming."
        case .staleTemporaryFiles:
            return "Extracted nested archives left by a previous launch are still in the temporary folder. They should be removed automatically at launch."
        case .orphanTemporaryFiles:
            return "Extracted nested archives from this launch are still in the temporary folder although no book is open. They should be removed when a book is closed."
        }
    }
}

/// 異常の判定役。入力(最新のスナップショット・走査結果・設定)から`[ResourceAnomaly]`を出す。
///
/// ■ 誤報を出さないための設計
/// ここは「何も出ない=正常」を信じてもらう場所なので、瞬間的な値で鳴らさない。
/// - メモリキャッシュの上限超過は、NSCacheが**挿入してから**超過ぶんを追い出す都合で、
///   1サンプルだけなら普通に起きる。`persistenceThreshold`回(3秒)連続したときだけ異常にする。
/// - 先読みの判定は「残留しているページ」ではなく「先読みタスクが走っているページ」で見る。
///   残留は上限内ならいくら残っていても正常(それがキャッシュの役目)。
/// - ディスクキャッシュの上限超過は、本体の刈り込みの余裕(`ThumbnailDiskCache.trimThreshold`)を
///   足した値を境目にする。本体が「まだ刈り込まなくてよい」と判断する範囲は異常ではない。
///
/// ウインドウごとに1つ(持続回数の状態を持つため)。
@MainActor
final class ResourceAnomalyDetector {
    /// 連続して何回(=何秒)超過していたら異常とみなすか。
    static let persistenceThreshold = 3

    private var overLimitStreaks: [ResourceAnomaly: Int] = [:]
    private var lastOrphanScanAt: Date?
    private var orphanScanStreak = 0

    struct Input {
        var bookSnapshot: ResourceMonitorSnapshot?
        var storage: StorageUsage?
        var isDiskCacheEnabled: Bool
        var diskCacheLimitBytes: Int
        var openBookCount: Int
    }

    /// 1秒ごとに呼ぶ(持続回数の単位が呼び出し回数なので、呼ぶ間隔を変えたら
    /// `persistenceThreshold`の意味も変わることに注意)。
    func evaluate(_ input: Input) -> [ResourceAnomaly] {
        var found: [ResourceAnomaly] = []

        if let book = input.bookSnapshot {
            if persists(.pageImageCacheOverLimit, book.pageImages.usedBytes > book.pageImages.limitBytes) {
                found.append(.pageImageCacheOverLimit)
            }
            if persists(.thumbnailCacheOverLimit, book.thumbnails.usedBytes > book.thumbnails.limitBytes) {
                found.append(.thumbnailCacheOverLimit)
            }
            if persists(.gridThumbnailCacheOverLimit, book.gridThumbnails.usedBytes > book.gridThumbnails.limitBytes) {
                found.append(.gridThumbnailCacheOverLimit)
            }
            if book.isPrefetchingBeyondRadius {
                found.append(.prefetchWiderThanSetting)
            }
        } else {
            overLimitStreaks.removeAll()
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
            if storage.staleTemporaryEntryCount > 0 {
                found.append(.staleTemporaryFiles)
            }
            // 本を開いている最中(BookLoaderが入れ子の書庫を展開した直後、ViewerViewModelが
            // まだ出来ていない一瞬)は「本が0冊なのに一時ファイルがある」が正しく成立する。
            // 走査2回(30秒)連続で成立したときだけ異常にする。
            if storage.scannedAt != lastOrphanScanAt {
                lastOrphanScanAt = storage.scannedAt
                let isOrphan = input.openBookCount == 0 && storage.sessionTemporaryFileCount > 0
                orphanScanStreak = isOrphan ? orphanScanStreak + 1 : 0
            }
            if orphanScanStreak >= 2 {
                found.append(.orphanTemporaryFiles)
            }
        }

        return found
    }

    /// `condition`が`persistenceThreshold`回連続でtrueならtrue。falseが来たらリセット。
    private func persists(_ anomaly: ResourceAnomaly, _ condition: Bool) -> Bool {
        guard condition else {
            overLimitStreaks[anomaly] = 0
            return false
        }
        let streak = (overLimitStreaks[anomaly] ?? 0) + 1
        overLimitStreaks[anomaly] = streak
        return streak >= Self.persistenceThreshold
    }
}
