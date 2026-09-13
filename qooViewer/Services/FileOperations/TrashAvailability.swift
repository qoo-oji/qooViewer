import AppKit
import Foundation

/// その場所にゴミ箱があるか(改善要望7 段階 2、2026-09-13。qooLibrary の `TrashAvailability` を写し、判定を直したもの)。
///
/// SMB(Samba/QNAP・Apple・Windows の 3 系統すべて)にはゴミ箱が無い。そこで `NSWorkspace.recycle` を
/// 呼ぶと macOS が「すぐに削除されます」の確認を出し、承諾すると**完全削除して成功を返すが、ゴミ箱の中の
/// URL は 0 件**で返る ―― アプリの確認を通らず、しかも Undo が黙って何もしない。先に確かめれば 3 つとも
/// 消える(qooLibrary 実測)。
///
/// ■ `url(for: .trashDirectory, create: false)` だけで決めない(実測 2026-09-13、macOS 26.6、テストホスト = サンドボックスの中)
/// qooLibrary はこの問い合わせの成否だけで決めていたが、**まだ一度もゴミ箱を使っていないローカルのボリュームでも
/// 失敗する**(`.Trashes` がまだ無いため。NSCocoaErrorDomain 3328)。一方 `recycle` はそこで `.Trashes` を作って
/// 普通にゴミ箱へ入れる:
///
/// | 作ったばかりのボリューム | `create: false` | `create: true` | `recycle` |
/// |---|---|---|---|
/// | APFS | 3328 | ―― | `.Trashes/501/` へ入る |
/// | exFAT | 3328 | 3328(ENOTDIR) | `.Trashes/501/` へ入る |
/// | FAT32 | 3328 | 3328(ENOTDIR) | `.Trashes/501/` へ入る |
///
/// 問い合わせだけで決めると、買ってきたばかりの USB メモリで「すぐに削除されます」の確認が出てしまう。
/// そこで、問い合わせが通ればある、通らなければ**マウント表でローカルならある**(recycle が作る)、
/// ネットワーク越しならない、とする。ネットワークホームのようにネットワーク越しでもゴミ箱が働く場所は、
/// 問い合わせが通る(既に `.Trashes` がある)ので拾える。
///
/// - Note: ボリュームへの問い合わせなので `FileIO` の上から呼ぶ。
nonisolated enum TrashAvailability {
    static func hasTrash(for url: URL, mounts: MountTable = .current()) -> Bool {
        // create: false ―― 確かめたいだけで、利用者のボリュームに .Trashes を作らない。
        if (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)) != nil {
            return true
        }
        return mounts.isLocal(url)
    }

    /// 1 つでもゴミ箱の無い場所にあれば false(混在で一部だけゴミ箱へ行くのは結果が読めないので、
    /// 全部まとめて「すぐに削除されます」の確認へ倒す)。マウントポイントごとに 1 回だけ尋ねる。
    static func hasTrash(forAll urls: [URL], using hasTrash: (URL) -> Bool = { hasTrash(for: $0) }) -> Bool {
        let mounts = MountTable.current()
        var checked: Set<String> = []
        for url in urls {
            let key = mounts.entry(containing: url)?.mountPoint ?? "/"
            guard checked.insert(key).inserted else { continue }
            if !hasTrash(url) { return false }
        }
        return true
    }
}

/// FileOperationService が外の世界(ゴミ箱)に触る 2 つの口。
///
/// **テストは実ゴミ箱に触れない**(開発機の `~/.Trash` がテストの残骸で埋まる。CLAUDE.md の
/// 「テストは共有の状態に触れない」)。テストは `.pseudoTrash(at:)` で一時フォルダをゴミ箱の代わりにし、
/// ゴミ箱の有無の判定と「戻す」の経路だけを確かめる(計画 §2.6)。
nonisolated struct FileOperationEnvironment: Sendable {
    /// その場所にゴミ箱があるか。FileIO の上で呼ばれる。
    var hasTrash: @Sendable (URL) -> Bool
    /// ゴミ箱へ送る。元の URL → ゴミ箱の中の URL の対応表と、失敗(一部だけ送れた場合も)を返す。
    /// 完了ハンドラが来ないことがある API なので、呼び出し側が期限を付ける。
    var recycle: @Sendable ([URL]) async -> (mapping: [URL: URL], error: (any Error)?)
    /// 「置き換える」で退避した元の項目をゴミ箱へ送る(同期。FileIO の上で呼ばれる)。
    /// 送った先を返す。送れなければ nil(呼び出し側は完全削除へ落とす)。
    var trashItemSynchronously: @Sendable (URL) -> URL?
    /// 「置き換える」の退避の記録(ReplaceBackupJournal)。テストは自分の一時フォルダの記録を使う。
    var replaceJournal: ReplaceBackupJournal = .shared

    /// 本物。`FileManager.trashItem` ではなく `NSWorkspace.recycle` を使うのは、Finder の「戻す」と
    /// 互換にするため(qooLibrary と同じ)。**サンドボックスでも実ホームの `~/.Trash` が返り、戻せる**(同実測)。
    static let live = FileOperationEnvironment(
        hasTrash: { TrashAvailability.hasTrash(for: $0) },
        recycle: { urls in
            await withCheckedContinuation { continuation in
                // recycle は completionHandler をメインスレッドへ返す。呼ぶ側のスレッドは問わない。
                DispatchQueue.main.async {
                    NSWorkspace.shared.recycle(urls) { mapping, error in
                        continuation.resume(returning: (mapping, error))
                    }
                }
            }
        },
        trashItemSynchronously: { url in
            var resulting: NSURL?
            guard (try? FileManager.default.trashItem(at: url, resultingItemURL: &resulting)) != nil else { return nil }
            return resulting as URL?
        }
    )

    /// テスト用: `trashFolder` をゴミ箱の代わりにする。`hasTrash` は `hasTrash` で決める。
    /// 退避の記録は、指定が無ければゴミ箱の代わりのフォルダの隣に置く(本物の記録にもほかのテストの記録にも触れない)。
    static func pseudoTrash(
        at trashFolder: URL,
        hasTrash: @escaping @Sendable (URL) -> Bool = { _ in true },
        replaceJournal: ReplaceBackupJournal? = nil
    ) -> FileOperationEnvironment {
        @Sendable func moveIntoTrash(_ url: URL) -> URL? {
            let name = FileNameValidation.nextAvailableName(for: url.lastPathComponent) { candidate in
                (try? FileManager.default.attributesOfItem(atPath: trashFolder.appendingPathComponent(candidate).path)) != nil
            }
            let destination = trashFolder.appendingPathComponent(name)
            guard (try? FileManager.default.moveItem(at: url, to: destination)) != nil else { return nil }
            return destination
        }
        return FileOperationEnvironment(
            hasTrash: hasTrash,
            recycle: { urls in
                var mapping: [URL: URL] = [:]
                for url in urls {
                    guard let trashed = moveIntoTrash(url) else {
                        return (mapping, CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]))
                    }
                    mapping[url] = trashed
                }
                return (mapping, nil)
            },
            trashItemSynchronously: { moveIntoTrash($0) },
            replaceJournal: replaceJournal ?? ReplaceBackupJournal(
                storageURL: trashFolder.deletingLastPathComponent().appendingPathComponent("replace-backups-\(UUID().uuidString).json")
            )
        )
    }
}
