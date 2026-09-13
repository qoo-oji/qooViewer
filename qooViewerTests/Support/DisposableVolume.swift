import Foundation
import Testing

@testable import qooViewer

/// **テスト用の使い捨てボリューム**の上に作る、テスト 1 つぶんの作業フォルダ(改善要望7 段階 2、2026-09-13)。
///
/// 一時フォルダ(起動ボリューム)だけでは確かめられないことがあるから要る ―― 同一ボリュームの移動は
/// rename なのでバイトを運ばず、APFS のコピーはクローンで一瞬に終わり、進捗・中止・元の検証の経路が
/// 一度も通らない。exFAT は `renamex_np(RENAME_EXCL)` が ENOTSUP を返す(実測)ので縮退経路が通り、
/// FAT32 は 1 ファイル 4GB 弱の上限を持つ。
///
/// ■ ボリュームはテストの外で付ける
/// テストホストはサンドボックスの中で、そこから起動した hdiutil は止められる(実測: create が
/// 「装置が構成されていません」で失敗し、カーネルのログに `deny(1) mach-lookup com.apple.system.hdiejectd.xpc`)。
/// 外で付けたボリュームへは読み書きできる(同じく実測)。そこでスキームの Test の Pre-action / Post-action が
/// `scripts/test/test-volumes.sh` で付け外しし、ここは決まった名前で探す。
///
/// 見つからなければ `make` は **テストを失敗させる**(黙って飛ばさない ―― qooLibrary では FAT のボリュームの
/// 名前を取り違え、FAT の検証がすべて静かに飛んでいた)。スキームを通さずにテストを走らせた場合がこれに当たる。
///
/// 作業フォルダは手放すと消える。ボリュームは複数のテストで共有するので、**ボリュームの直下には何も残さない**。
nonisolated final class DisposableVolume {
    enum Kind: String {
        /// APFS 128MB。
        case apfs
        /// exFAT 64MB。クローンできない。`RENAME_EXCL` は ENOTSUP。
        case exfat
        /// FAT32 64MB。1 ファイル 4GB 弱。
        case fat32
        /// APFS 20MB。空き容量の検査用(この上で使うテストは直列にする)。
        case tiny
    }

    /// ボリュームの入口。
    let mountPoint: URL
    /// このテストの作業フォルダ(ボリュームの直下の UUID 付きフォルダ)。
    let url: URL

    private init(mountPoint: URL, url: URL) {
        self.mountPoint = mountPoint
        self.url = url
    }

    /// `kind` のボリュームの上に作業フォルダを作る。ボリュームが無ければテストを失敗させて nil。
    static func make(_ kind: Kind, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) -> DisposableVolume? {
        let mountPoint = URL(fileURLWithPath: "/Volumes/qooViewerTest-\(kind.rawValue)", isDirectory: true)
        guard MountTable.current().isMounted(mountPoint.path) else {
            Issue.record(
                "テスト用ボリューム \(mountPoint.path) がありません。スキーム qooViewer の Test から走らせてください(scripts/test/test-volumes.sh attach)。",
                sourceLocation: sourceLocation
            )
            return nil
        }
        let url = mountPoint.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            Issue.record("作業フォルダを作れませんでした: \(error)", sourceLocation: sourceLocation)
            return nil
        }
        return DisposableVolume(mountPoint: mountPoint, url: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// 作業フォルダの中のパス(作りはしない)。
    func file(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let directory = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
