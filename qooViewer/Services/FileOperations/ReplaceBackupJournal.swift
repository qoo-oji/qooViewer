import Foundation

/// **「置き換える」の途中でアプリが落ちても、置き換えられるはずだった元の項目を見失わない**
/// (改善要望7 段階 4b、2026-09-14。qooLibrary の同名の型 [NV-92] を写したもの)。
///
/// ■ 何が起きるか
/// `.replace` は健康なファイルを書き潰さないよう、**既存の項目を同じフォルダの
/// `.qooViewer-replace-<UUID>/<元の名前>` へ退避してから書く**。書き終えたら退避をゴミ箱へ、失敗したら元へ戻す
/// (FileOperationService.checkConflict / carry)。その間に落ちると元の項目は隠しフォルダの中に残り、
/// Finder にもこのアプリにも見えない ―― 利用者から見れば**ファイルが消えた**。
/// 別ボリュームへ大きなファイルを置き換えで書くなら、この窓は分単位で開いたままになる。
///
/// ■ なぜ走査ではなく記録なのか
/// 退避は利用者が選んだ書き込み先に作られるので、起動時に探すにはボリュームを走査するしかない。
/// **作る前に「これから作る」と書き、片付けたら消す。** 起動時は記録だけを読めばよく、通常時は
/// 記録のファイル自体が無いので 1 回の stat で終わる。
///
/// ■ 同期 API
/// 呼ぶのは FileIO.perform の中を走るブロッキング側なので await できない。書き込みは `.replace` のときだけ。
nonisolated final class ReplaceBackupJournal: @unchecked Sendable {
    /// 本番の記録。テスト中はプロセスごとの一時フォルダ(`defaultStorageURL`)。
    static let shared = ReplaceBackupJournal()

    /// 記録 1 件。**退避先と戻す場所の両方**を持つ(片方だけでは戻せない)。
    struct Entry: Codable, Hashable, Sendable {
        let backupPath: String
        let targetPath: String
    }

    /// 起動時の復旧で起きたこと。利用者へ伝えることがケースごとに違う。
    enum Outcome: Equatable, Sendable {
        /// 退避が既に無い(正常に片付いていた)。記録だけが残っていた。
        case alreadyClean
        /// 元の場所へ戻した。**利用者から見れば「消えていたファイルが戻った」。**
        case restored(target: URL)
        /// 戻せなかった。退避はその名前のまま残っていて、記録も残す(次の起動でもう一度試す)。
        case orphaned(backup: URL, target: URL, reason: String)
        /// 退避のある場所に今は届かない(ボリュームが外れている・読めない)。**記録を残して黙る**(繋ぎ直した次の起動で戻す)。
        /// 知らせないのは、外付けを繋がずに起動するたびに警告が出続けるため。
        case unreachable(backup: URL)
    }

    private let lock = NSLock()
    let storageURL: URL

    /// - Parameter storageURL: 記録の置き場所。**書き込み先のボリュームには置かない**(切断されたボリュームの
    ///   記録を、そのボリュームの上から読むことはできない)。
    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
    }

    static func defaultStorageURL() -> URL {
        // **テスト中は本物の記録に触れない。** 共有すると、テストが開発機に残っている記録を読んで利用者の本物の
        // ファイルを動かしうる。実行ごとにも分ける(qooLibrary で、異常終了したテストの残した記録を次の実行が
        // 読み、関係の無いテストが落ち続けた)。
        let base: URL
        if RuntimeEnvironment.isRunningTests {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("qooViewerTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        return base.appendingPathComponent("FileOperations", isDirectory: true)
            .appendingPathComponent("replace-backups.json")
    }

    // MARK: - 記録

    /// **退避を作る直前に呼ぶ。** 作った後に書くと、その間に落ちたら記録が無い。
    func record(backup: URL, target: URL) {
        let entry = Entry(backupPath: backup.path, targetPath: target.path)
        mutate { entries in
            entries.removeAll { $0.backupPath == entry.backupPath }
            entries.append(entry)
        }
    }

    /// 退避を片付け終えたら呼ぶ(ゴミ箱へ送った / 元へ戻した / 消した / そもそも作れなかった)。
    func forget(backup: URL) {
        mutate { entries in entries.removeAll { $0.backupPath == backup.path } }
    }

    /// いま記録されている件数。**検証のための口**(「退避を作る前に記録している」は、書いている最中に
    /// 覗く以外に確かめようがない)。
    func pendingBackupCount() -> Int {
        load().count
    }

    // MARK: - 起動時の復旧

    /// 起動時に 1 回だけ呼ぶ(FileIO の上で。退避先が応答しない共有のことがある)。
    ///
    /// **元の場所に何も無いときだけ戻す。** 何かあるなら「書き込みは実は済んでいた(新しい内容)」か
    /// 「利用者が後から別のものを置いた」で、どちらも上書きしてはならない。退避を残したまま `orphaned` で報告する。
    func recoverAll() -> [Outcome] {
        let entries = load()
        guard !entries.isEmpty else { return [] }
        let locale = AppLanguage.currentLocale
        let mounts = MountTable.current()
        var outcomes: [Outcome] = []
        var survivors: [Entry] = []

        for entry in entries {
            let backup = URL(fileURLWithPath: entry.backupPath)
            let target = URL(fileURLWithPath: entry.targetPath)
            let holder = backup.deletingLastPathComponent()
            // 存在はリンクを辿らずに見る(リンク切れのシンボリックリンクも「ある」)。
            //
            // **「無い」と「今は見えない」を分ける**(2026-09-14 の監査で発見)。退避先のボリュームが外れたまま起動すると
            // lstat は ENOENT を返すので、以前はここで「片付いていた」として記録を捨てていた。繋ぎ直しても元の項目は
            // `.qooViewer-replace-<UUID>/` に隠れたまま二度と知らされない(`restoreReplacedItem` が「次は繋がっているかも
            // しれない」と残した記録を、起動時の復旧が打ち消していた)。サンドボックスの許可を取り消したときの
            // EPERM / EACCES も同じく「見えない」側。
            switch Self.presence(of: backup, mounts: mounts) {
            case .present:
                break
            case .unreachable:
                outcomes.append(.unreachable(backup: backup))
                survivors.append(entry)
                continue
            case .absent:
                // 退避用の隠しフォルダだけが残っていることがある(作った直後に落ちた)。空なら片付ける。
                Self.removeHolderIfEmpty(holder)
                outcomes.append(.alreadyClean)
                continue
            }
            if FileOperationService.itemExists(at: target) {
                outcomes.append(.orphaned(
                    backup: backup, target: target,
                    reason: String(localized: "An item with the same name already exists.", language: locale)
                ))
                survivors.append(entry)
                continue
            }
            let code = FileOperationService.exclusiveRename(from: backup, to: target)
            if code == 0 {
                Self.removeHolderIfEmpty(holder)
                outcomes.append(.restored(target: target))
            } else {
                outcomes.append(.orphaned(backup: backup, target: target, reason: PosixFailure.reason(code)))
                survivors.append(entry)
            }
        }
        // **自分が処理した記録だけを取り除く。** 丸ごと差し替えると、復旧の間(ネットワークなら遅い)に
        // 新しい「置き換える」が書いた記録を消してしまう(qooLibrary で監査により発見)。
        let survivorSet = Set(survivors)
        mutate { current in
            current.removeAll { entries.contains($0) && !survivorSet.contains($0) }
        }
        return outcomes
    }

    enum Presence: Equatable {
        case present
        /// 確かに無い(載っているボリュームは繋がっていて、lstat が ENOENT / ENOTDIR)。
        case absent
        /// あるかどうか分からない(ボリュームが外れている、読めない)。
        case unreachable
    }

    /// 退避があるか。**確かに無いと言えるときだけ `.absent`**(記録を捨ててよいのはそのときだけ)。
    static func presence(of backup: URL, mounts: MountTable) -> Presence {
        var info = stat()
        if lstat(backup.path, &info) == 0 { return .present }
        let code = errno
        guard code == ENOENT || code == ENOTDIR else { return .unreachable }
        return mounts.isOnAnUnmountedVolume(backup) ? .unreachable : .absent
    }

    /// 退避用の隠しフォルダ(`.qooViewer-replace-<UUID>`)が空なら消す。rmdir は中身があれば失敗するので、
    /// 利用者のファイルを巻き込むことはない。
    static func removeHolderIfEmpty(_ holder: URL) {
        guard holder.lastPathComponent.hasPrefix(FileOperationService.replaceHolderPrefix) else { return }
        rmdir(holder.path)
    }

    // MARK: - 永続化
    //
    // 壊れていたら空として扱い、**元のファイルは退避して残す**(中身は利用者のファイルの居場所そのもの)。

    private func load() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> [Entry] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            let corrupt = storageURL.deletingLastPathComponent()
                .appendingPathComponent("\(storageURL.lastPathComponent).corrupt-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: storageURL, to: corrupt)
            return []
        }
        return entries
    }

    private func mutate(_ change: (inout [Entry]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        change(&entries)
        saveLocked(entries)
    }

    private func saveLocked(_ entries: [Entry]) {
        // 空になったらファイルごと消す(起動時の読み込みが「無い」で終わる)。
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: storageURL)
            return
        }
        // 書けなくても操作は止めない。**記録は保険であって目的ではない。**
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: storageURL, options: .atomic)
    }
}
