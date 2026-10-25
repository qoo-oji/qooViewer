import Foundation

/// ファイルブラウザのツリーのボリュームの行の「アンマウント」(2026-10-25)。
///
/// **どの行に付けるか**: 起動ボリュームではなく `/Volumes` の下にあり、ネットワーク越し、または外付け・取り外せる・取り出せる
/// ボリューム(Finder のサイドバーで取り出しの印が付くものに合わせる)。内蔵のディスクのほかのボリュームには付けない。
/// **何をするか**: そのボリュームだけをアンマウントする(`FileManager.unmountVolume`、選択肢なし)。同じディスクのほかのボリュームは
/// 外さず、ディスクも取り出さない(利用者の指定は「アンマウント」)。App Sandbox の中から権限もダイアログも無しに通る
/// (2026-10-25 実測: SMB の共有を 0.17 秒)。使用中なら失敗し、その理由を返す。
nonisolated enum VolumeUnmounting {
    /// アンマウントの前に記述子を手放すのを待つ上限(`unmount`)。
    static let releaseLimit: Duration = .seconds(5)

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
    ///
    /// - 先に、ネットワーク上の書庫の読み込み層が猶予の間だけ持っている記述子を手放させる(`StagedFileRegistry.releaseHolds`。
    ///   本を閉じた直後に押すと、アプリ自身が持つ記述子で「使用中」になった ―― 2026-10-25 のレビュー)。
    /// - `.withoutUI`: 失敗の知らせはアプリが出す(docs/09 の作法の文面)。macOS 自身の表示と二重にしない(同レビュー)。
    ///
    /// 記述子を手放すのは `FileIO` の上で(2026-10-25 のハング・クラッシュの監査 A2-7)。この関数は `nonisolated async` なので呼んだ側
    /// (メイン)で走り、最後の強参照が外れた読み込み層の deinit の `close()` が、応答しない共有ではメインで止まりえた。待つのは
    /// `releaseLimit` まで(close が返らなくてもアンマウントは試す ―― 使用中なら失敗の理由が返る)。パスは文字列だけで揃える
    /// (登録簿の鍵は本の URL の `path` そのまま)。
    static func unmount(_ volume: URL, stagedFiles: StagedFileRegistry = .shared) async -> (any Error)? {
        let mountPoint = MountTable.normalized(volume.path)
        _ = try? await FileIO.withDeadline(releaseLimit) {
            await FileIO.perform(qos: .userInitiated) { stagedFiles.releaseHolds(onVolume: mountPoint) }
        }
        return await withCheckedContinuation { continuation in
            FileManager.default.unmountVolume(at: volume, options: [.withoutUI]) { error in
                continuation.resume(returning: error)
            }
        }
    }
}
