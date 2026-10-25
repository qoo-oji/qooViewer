import Foundation

/// ファイルブラウザのツリーのボリュームの行の「アンマウント」(2026-10-25)。
///
/// **どの行に付けるか**: 起動ボリュームではなく `/Volumes` の下にあり、ネットワーク越し、または外付け・取り外せる・取り出せる
/// ボリューム(Finder のサイドバーで取り出しの印が付くものに合わせる)。内蔵のディスクのほかのボリュームには付けない。
/// **何をするか**: そのボリュームだけをアンマウントする(`FileManager.unmountVolume`、選択肢なし)。同じディスクのほかのボリュームは
/// 外さず、ディスクも取り出さない(利用者の指定は「アンマウント」)。App Sandbox の中から権限もダイアログも無しに通る
/// (2026-10-25 実測: SMB の共有を 0.17 秒)。使用中なら失敗し、その理由を返す。
nonisolated enum VolumeUnmounting {
    /// `volumes` のうちアンマウントのボタンを付けるマウント先。ローカルのボリュームには問い合わせる(`resourceValues`)ので
    /// **FileIO の上で呼ぶ**。ネットワーク越しのボリュームには問い合わせない(マウント表だけで決める ―― 応答しない共有で止まらない)。
    static func unmountableMountPoints(of volumes: [URL], mountTable: MountTable) -> Set<String> {
        var result = Set<String>()
        for url in volumes {
            let path = url.standardizedFileURL.path
            guard path != "/", MountTable.path(path, isAtOrUnder: "/Volumes"), path != "/Volumes",
                  let entry = mountTable.entry(containing: path), entry.mountPoint == path
            else { continue }
            if !entry.isLocal {
                result.insert(path)
                continue
            }
            let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey]
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false {
                result.insert(path)
            }
        }
        return result
    }

    /// `volume` をアンマウントする。失敗したらその理由(成功なら nil)。
    static func unmount(_ volume: URL) async -> (any Error)? {
        await withCheckedContinuation { continuation in
            FileManager.default.unmountVolume(at: volume, options: []) { error in
                continuation.resume(returning: error)
            }
        }
    }
}
