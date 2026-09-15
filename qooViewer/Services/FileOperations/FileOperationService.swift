import Foundation

/// **ファイルブラウザのファイル操作はすべてここを通る**(改善要望7 段階 2、2026-09-13。
/// qooLibrary の `FileOperationService` を、qooViewer の計画 §2.3 に合わせて写したもの)。
///
/// ■ 状態を持たない actor
/// 各メソッドの本体は「段取り」だけで、ブロッキングする仕事(FileManager・stat・copyfile)は
/// **必ず `FileIO.perform` の中**で行う(`FileIO` の型コメント: 協調プールを塞ぐとアプリの async 処理が
/// 全部止まる)。`FileIO.perform` は呼び出し元を必ず中断させるので、I/O のあいだこの actor も
/// 手放される。状態を 1 つも持たないので手放しても正しさは損なわれず、**1 件のハング(応答しない共有)が
/// 他の操作を巻き添えにしない**。代わりに同時に走る操作が交錯しうるが、`RENAME_EXCL` / `COPYFILE_EXCL` が
/// 「取りこぼした衝突で健康なファイルを書き潰す」ことを構造的に防ぐので、最悪でも EEXIST で済む。
///
/// 見分け方: `@Sendable` なクロージャ(FileIO.perform の中)から呼べるのは static / nonisolated だけなので、
/// **この型の static メンバは「ブロッキング側」、素のメソッドは「段取り側」**と読める。
///
/// ■ 決めごとの出典
/// 実測の根拠はすべて qooLibrary(docs/plans/file-browser-study.md §4.2 の表)。個々の理由は各所のコメント。
actor FileOperationService {
    private let environment: FileOperationEnvironment
    /// false で必ず実コピーにする。**テストのための逃げ道**(進捗・中止・元の検証は、クローンできない
    /// 経路でしか通らない)。本番は既定のまま。
    private let allowsCloning: Bool

    init(environment: FileOperationEnvironment = .live, allowsCloning: Bool = true) {
        self.environment = environment
        self.allowsCloning = allowsCloning
    }

    /// ゴミ箱へ送る操作の期限。UI の文脈が無いプロセスでは `NSWorkspace.recycle` の完了ハンドラが
    /// 永久に来ない(qooLibrary 実測)ので、待つのをやめられるようにする。
    nonisolated static let trashTimeout: Duration = .seconds(120)

    // MARK: - 新規フォルダ

    /// フォルダを 1 つ作る。**既にあれば失敗する**(`withIntermediateDirectories: true` は既存でも
    /// エラーにならないので、そのままだと同名の「新規フォルダ」が黙って何も起きない。qooLibrary で発見)。
    @discardableResult
    func createDirectory(at url: URL) async throws -> URL {
        do {
            _ = try FileNameValidation.validated(url.lastPathComponent)
        } catch let failure as FileNameValidation.Failure {
            throw FileOperationError.invalidName(url.lastPathComponent, reason: failure)
        }
        return try await FileIO.perform {
            let parent = url.deletingLastPathComponent()
            guard Self.itemExists(at: parent) else { throw FileOperationError.itemMissing(parent) }
            try FileOperationPreflight.checkWritable(parent)
            guard !Self.itemExists(at: url) else { throw FileOperationError.alreadyExists(url) }
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                // 確かめてから作るまでの間に誰かが作った場合も、ここで「既にある」として断る。
                if Self.itemExists(at: url) { throw FileOperationError.alreadyExists(url) }
                throw error
            }
            return url
        }
    }

    // MARK: - コピー・移動

    func copy(_ items: [URL], to folder: URL, options: FileOperationOptions = .init()) async throws -> TransferOutcome {
        let allowsCloning = allowsCloning
        return try await transfer(items, to: folder, options: options, isMove: false) { source, target, onBytes in
            try FileCopyEngine.copy(from: source, to: target, allowsCloning: allowsCloning, onBytesCopied: onBytes)
        }
    }

    /// ロックされた項目は `options.unlockingLocked` のときだけ運ぶ(`movingIsBlockedByLock`)。
    func move(_ items: [URL], to folder: URL, options: FileOperationOptions = .init()) async throws -> TransferOutcome {
        let allowsCloning = allowsCloning
        let unlocking = options.unlockingLocked
        return try await transfer(items, to: folder, options: options, isMove: true) { source, target, onBytes in
            try Self.withLocksLifted(from: source, to: target, allowed: unlocking) {
                try Self.moveItem(from: source, to: target, allowsCloning: allowsCloning, onBytesCopied: onBytes)
            }
        }
    }

    /// 移動でロックが邪魔をするか(2026-09-14)。同じボリュームなら rename(2) なので項目自身のロックだけが断り(EPERM)、
    /// 別のボリュームはコピーしてから元を消すので、中のロックされた子で元の削除が止まる。
    nonisolated static func movingIsBlockedByLock(_ item: URL, to folder: URL, mounts: MountTable) -> Bool {
        isOnSameVolume(item, folder, mounts: mounts) ? isLocked(item) : containsLockedItem(item)
    }

    /// 項目と宛先のフォルダが同じボリュームの上か。**リンクを解いてから**マウント表で比べる(2026-09-14 の 2 回目の監査。
    /// `MountTable.areOnSameVolume` はパスの文字列で比べるので、別のボリュームを指すフォルダのリンクの下の項目を「同じボリューム」と
    /// 見て、空き容量と中のロックの確認を飛ばしていた)。項目自身がリンクならリンクとして運ぶので、解くのは親だけ。
    /// ブロッキングする(リンクの解決)ので FileIO の上で呼ぶ。
    nonisolated static func isOnSameVolume(_ item: URL, _ folder: URL, mounts: MountTable) -> Bool {
        let resolvedItem = item.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(item.lastPathComponent)
        return mounts.areOnSameVolume(resolvedItem, folder.resolvingSymlinksInPath())
    }

    /// ロックを外して `body` を走らせ、運べたら運んだ先の同じ場所で、運べなかったら元の場所で掛け直す。
    /// `allowed` が false でロックが邪魔をするなら、触る前に「ロックされています」で断る(以前は OS の EPERM が
    /// 「権限がありません」と出るだけで、何が邪魔なのか分からなかった ―― 計画 §4.11)。
    private nonisolated static func withLocksLifted(
        from source: URL, to target: URL, allowed: Bool, _ body: () throws -> FileCopyEngine.Outcome
    ) throws -> FileCopyEngine.Outcome {
        // 同じボリュームなら邪魔をするのは項目自身のロックだけなので、**木を歩かない**(2026-09-14 の監査。以前は同じボリュームの
        // 移動でも中を全部列挙してから、項目自身以外を捨てていた)。
        let sameVolume = isOnSameVolume(source, target.deletingLastPathComponent(), mounts: .current())
        let blocking = sameVolume ? (isLocked(source) ? [source] : []) : lockedItems(atOrUnder: source)
        guard !blocking.isEmpty else { return try body() }
        guard allowed else { throw FileOperationError.itemLocked(source) }
        // 外すのは邪魔をするものだけ(同じボリュームなら中のロックはそのまま一緒に動く)。
        // 相対パスは、リンクを解いた親の後ろに名前を付けて比べる(列挙が返す子の URL は /var と /private/var のように
        // 頭の書き方が元の URL と揃うとは限らない。項目そのものはリンクでもリンク先へ行かないよう、名前は解かない)。
        func resolved(_ url: URL) -> String {
            url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        }
        let base = resolved(source)
        let relative = blocking.map { String(resolved($0).dropFirst(base.count)) }
        let lifted = zip(blocking, relative).filter { setLocked($0.0, false) }.map(\.1)
        func relock(under root: URL) {
            for path in lifted { setLocked(URL(fileURLWithPath: root.path + path), true) }
        }
        do {
            let outcome = try body()
            switch outcome {
            case .completed: relock(under: target)
            case .cancelled: relock(under: source)
            // 写し終えたが元が途中まで残った。両方の同じ場所で掛け直す(無くなった側は setLocked が何もしない)。
            case .copiedButSourceRemains: relock(under: target); relock(under: source)
            }
            return outcome
        } catch {
            relock(under: itemExists(at: source) ? source : target)
            throw error
        }
    }

    // MARK: - 名前の変更

    /// - Parameter name: **`appendingPathComponent` に渡す前に検証する**(`/` を含むとパス区切りと解釈され、
    ///   名前の変更のつもりが別フォルダへの移動になる)。
    /// - Parameter unlockingLocked: ロックされた項目は rename(2) が EPERM で断る。true(利用者が確認で「続ける」と答えた、
    ///   または取り消しで自分が名前を変えたものを戻す)ならロックを外して変え、変えた先で掛け直す。false なら「ロックされています」。
    /// - Parameter keepsNameExactly: 前後の空白を落とさない(一括リネーム。`FileNameValidation.validatedExactly`)。
    func rename(_ item: URL, to name: String, unlockingLocked: Bool = false, keepsNameExactly: Bool = false) async throws -> RenameReceipt {
        let validName: String
        do {
            validName = keepsNameExactly ? try FileNameValidation.validatedExactly(name) : try FileNameValidation.validated(name)
        } catch let failure as FileNameValidation.Failure {
            throw FileOperationError.invalidName(name, reason: failure)
        }
        let target = item.deletingLastPathComponent().appendingPathComponent(validName)
        return try await FileIO.perform {
            guard Self.itemExists(at: item) else { throw FileOperationError.itemMissing(item) }
            let parent = item.deletingLastPathComponent()
            try FileOperationPreflight.checkWritable(parent)
            if let limit = FileOperationPreflight.nameByteLimit(at: parent, mounts: .current()), validName.utf8.count > limit {
                throw FileOperationError.nameTooLongForDestination(name: validName, lengthBytes: validName.utf8.count, limitBytes: limit)
            }
            let wasLocked = Self.isLocked(item)
            if wasLocked {
                guard unlockingLocked, Self.setLocked(item, false) else { throw FileOperationError.itemLocked(item) }
            }
            let code: Int32
            if Self.refersToSameEntry(item, target), Self.namesDifferOnlyInCaseOrNormalization(item.lastPathComponent, validName) {
                // **書き換え先がその項目自身なら衝突ではない。** 大文字小文字を区別しないボリューム
                // (APFS の既定)で `comic.cbz` → `Comic.cbz`、どの形式でも NFD → NFC だけの改名は、
                // 宛先の存在確認が「自分自身」を見つける。ここで衝突と判定すると Finder でできる改名が
                // できない(qooLibrary で監査により発見)。RENAME_EXCL も自分自身に EEXIST を返しうるので素の rename(2)。
                code = Darwin.rename(item.path, target.path) == 0 ? 0 : errno
            } else {
                code = Self.exclusiveRename(from: item, to: target)
            }
            if wasLocked { Self.setLocked(code == 0 ? target : item, true) }
            if code == EEXIST { throw FileOperationError.alreadyExists(target) }
            guard code == 0 else { throw FileOperationError.posixFailure(item: item, errnoCode: code) }
            return RenameReceipt(original: item, renamed: target, identity: FileIdentity.of(target))
        }
    }

    // MARK: - ゴミ箱

    /// ゴミ箱へ送る。**ゴミ箱の無い場所では送らずに `trashUnavailable` を投げる**(呼び出し側が先に
    /// `TrashAvailability` で見て、確認のうえ `deletePermanently` へ振り分ける。TrashAvailability の型コメント)。
    ///
    /// 一部だけ送れた場合も、送れた分の受領書は捨てない(捨てると、ゴミ箱へ行ったのに Undo で戻せない)。
    ///
    /// - Parameter unlockingLocked: **ロックされた項目**(`uchg`)は `NSWorkspace.recycle` も `trashItem` も
    ///   「アクセス権がありません」で断る(2026-09-14 実測。中にロックされた項目があるだけのフォルダは送れる)。
    ///   false ならロックされた項目は送らずに「ロックされています」の失敗にする。true(利用者が「続ける」と答えた)
    ///   なら、ロックを外して送り、**ゴミ箱の中でロックを掛け直す**(Finder もゴミ箱の中でロックを保つ。
    ///   戻したときにロックも戻る)。送れなかった項目はその場でロックを戻す。
    func trash(_ items: [URL], unlockingLocked: Bool = false) async throws -> TrashOutcome {
        guard let first = items.first else { return TrashOutcome() }
        let environment = environment
        let hasTrash = await FileIO.perform { TrashAvailability.hasTrash(forAll: items, using: environment.hasTrash) }
        guard hasTrash else { throw FileOperationError.trashUnavailable(first) }

        var outcome = TrashOutcome()
        let locked = await FileIO.perform { Set(items.filter { Self.isLocked($0) }) }
        let refusesLocked = !locked.isEmpty && !unlockingLocked
        let sending = refusesLocked ? items.filter { !locked.contains($0) } : items
        let unlocked: Set<URL> = !locked.isEmpty && unlockingLocked
            ? await FileIO.perform { Set(locked.filter { Self.setLocked($0, false) }) }
            : []
        if refusesLocked {
            for item in items where locked.contains(item) {
                outcome.failures.append(FailedItem(url: item, reason: FileOperationError.itemLocked(item).localizedDescription))
            }
        }
        guard !sending.isEmpty else { throw FileOperationError.itemLocked(first) }

        // recycle は完了ハンドラの非同期 API なので FileIO.perform には載せない(待っているスレッドが無い)。
        // 代わりに期限を付ける。
        let result: (mapping: [URL: URL], error: (any Error)?)
        do {
            result = try await FileIO.withDeadline(Self.trashTimeout) { await environment.recycle(sending) }
        } catch {
            // 待つのをやめた。外したロックは、まだ元の場所にあるものだけ戻す。
            _ = await FileIO.perform { unlocked.filter { Self.itemExists(at: $0) }.map { Self.setLocked($0, true) } }
            throw error
        }
        if !unlocked.isEmpty {
            await FileIO.perform {
                for item in unlocked {
                    // ゴミ箱へ行ったならその中で、行かなかったなら元の場所で掛け直す。
                    _ = Self.setLocked(result.mapping[item] ?? item, true)
                }
            }
        }
        let mapping = result.mapping
        let identities = await FileIO.perform { mapping.compactMapValues { FileIdentity.of($0) } }
        for item in sending {
            if let trashed = result.mapping[item] {
                outcome.receipts.append(TrashReceipt(originalURL: item, trashURL: trashed, identity: identities[item]))
            } else if let error = result.error {
                outcome.failures.append(FailedItem(url: item, reason: error.localizedDescription))
            } else {
                // 失敗の報告も対応表も無い(ゴミ箱の無い場所で OS の確認を経て消えた、など)。
                // 送れたかもしれないが戻す手段が無いので、Undo の対象にしない受領書として残す。
                outcome.receipts.append(TrashReceipt(originalURL: item, trashURL: nil))
            }
        }
        if outcome.receipts.isEmpty, let error = result.error { throw error }
        return outcome
    }

    /// ゴミ箱を経由しない完全削除。**取り消せない** ―― 呼び出し側は必ず事前に確認を取る
    /// (「この項目はすぐに削除されます。この操作は取り消せません。」計画 §4)。
    ///
    /// 1 件の失敗で全体を止めない(消えた項目と消えなかった項目を分けて返す)。部分的な成功は巻き戻せない。
    ///
    /// - Parameter unlockingLocked: false なら、ロックされた項目(自身か、フォルダなら中のどれか)は消さずに
    ///   「ロックされています」の失敗にする(`removeItem` はロックされた子に当たった時点で止まり、そこまでの子だけが
    ///   消えた中途半端な木を残すので、**触る前に**断る)。true(利用者が「続ける」と答えた)なら、消す直前に
    ///   まとめて外す。消せなかったら外したロックを戻す(「消えてもいないのにロックだけ外れた」を残さない)。
    func deletePermanently(_ items: [URL], unlockingLocked: Bool = false) async -> DeletionOutcome {
        var outcome = DeletionOutcome()
        for item in items {
            let failure: String? = await FileIO.perform {
                guard Self.itemExists(at: item) else {
                    return String(localized: "The item could not be found.", language: AppLanguage.currentLocale)
                }
                // ロックの確かめ・外す・消すを**1 つのかたまり**にする(往復を分けると、その隙間で止まったときに
                // ロックだけ外れた状態が残る)。
                var cleared: [URL] = []
                if Self.containsLockedItem(item) {
                    guard unlockingLocked else { return FileOperationError.itemLocked(item).localizedDescription }
                    cleared = Self.lockedItems(atOrUnder: item).filter { Self.setLocked($0, false) }
                }
                do {
                    try Self.removeAbsorbingTransientFailure(at: item)
                    return nil
                } catch {
                    for url in cleared where Self.itemExists(at: url) { _ = Self.setLocked(url, true) }
                    return error.localizedDescription
                }
            }
            if let failure {
                outcome.failures.append(FailedItem(url: item, reason: failure))
            } else {
                outcome.deleted.append(item)
            }
        }
        return outcome
    }

    /// ゴミ箱から元の場所へ戻す(TrashCommand の Undo)。**元の場所に何かあれば上書きしない**(失敗として返す)。
    func restoreFromTrash(_ receipts: [TrashReceipt]) async -> RestoreOutcome {
        var outcome = RestoreOutcome()
        for receipt in receipts {
            guard let trashURL = receipt.trashURL else {
                outcome.failures.append(FailedItem(
                    url: receipt.originalURL,
                    reason: String(localized: "The item’s location in the Trash is unknown.", language: AppLanguage.currentLocale)
                ))
                continue
            }
            let failure: String? = await FileIO.perform {
                // 送ったそのものがまだゴミ箱にあるか(TrashReceipt.identity)。
                guard FileIdentity.matches(trashURL, receipt.identity) else {
                    return String(localized: "The item is no longer in the Trash.", language: AppLanguage.currentLocale)
                }
                guard Self.itemExists(at: receipt.originalURL.deletingLastPathComponent()) else {
                    return String(localized: "The original folder no longer exists.", language: AppLanguage.currentLocale)
                }
                // ロックしたまま送った項目(trash の unlockingLocked)は、ゴミ箱の中でもロックされていて rename できない。
                // 外して戻し、戻した先で掛け直す。戻せなければゴミ箱の中で掛け直す。
                let wasLocked = Self.isLocked(trashURL) && Self.setLocked(trashURL, false)
                var code = Self.exclusiveRename(from: trashURL, to: receipt.originalURL)
                if code == EXDEV {
                    // ゴミ箱が元と別のボリューム(実ホームの ~/.Trash とボリュームの .Trashes は通常同じ
                    // ボリュームだが、ネットワークホーム等の例外に備える)。
                    if Self.itemExists(at: receipt.originalURL) {
                        code = EEXIST
                    } else {
                        code = (try? FileManager.default.moveItem(at: trashURL, to: receipt.originalURL)) != nil ? 0 : EIO
                    }
                }
                if wasLocked { _ = Self.setLocked(code == 0 ? receipt.originalURL : trashURL, true) }
                return code == 0 ? nil : PosixFailure.reason(code)
            }
            if let failure {
                outcome.failures.append(FailedItem(url: receipt.originalURL, reason: failure))
            } else {
                outcome.restored.append(receipt.originalURL)
            }
        }
        return outcome
    }

    // MARK: - 一括転送の骨組み

    /// 移動・コピーの共通の段取り。**ブロッキングする仕事は preflight / resolve / carry の 3 つに追い出してあり、
    /// どれも FileIO.perform の中で走る。** 1 項目あたりの往復は通常 2 回(衝突の判定、運ぶ処理)。
    private func transfer(
        _ items: [URL],
        to folder: URL,
        options: FileOperationOptions,
        isMove: Bool,
        perform: @escaping @Sendable (URL, URL, @escaping (Int64) -> Void) throws -> FileCopyEngine.Outcome
    ) async throws -> TransferOutcome {
        guard !items.isEmpty else { return TransferOutcome() }
        let allowsCloning = allowsCloning
        let tracker = try await FileIO.perform(cancellation: options.cancellation) {
            try Self.preflight(items: items, destination: folder, sink: options.progress, isMove: isMove, allowsCloning: allowsCloning)
        }
        tracker.begin()

        let environment = environment
        var outcome = TransferOutcome()
        var firstError: (any Error)?
        /// 「以降すべてに適用」で決まった答え。この 1 回の操作の中だけで覚える。
        var blanketDecision: ConflictDecision?
        /// この操作で置いた項目の実体(衝突の判定に使う)。**足していく**(2026-09-15 の 3 回目の監査。以前は項目ごとに受領書全部から
        /// 作り直していたので、項目数の 2 乗 ―― 数万件の移動で数十秒を集合作りに使った)。
        var placed = Set<FileIdentity>()

        for (index, item) in items.enumerated() {
            if options.cancellation.isRequested || Task.isCancelled {
                outcome.wasCancelled = true
                outcome.unprocessed = Array(items[index...])
                break
            }
            tracker.startItem(item)
            let target = folder.appendingPathComponent(item.lastPathComponent)
            do {
                let resolution = try await resolveDestination(
                    item, target, decision: blanketDecision ?? ConflictDecision(options.conflictPolicy), options: options,
                    isMove: isMove, placedByThisOperation: placed, environment: environment
                )
                if let remembered = resolution.rememberedDecision { blanketDecision = remembered }
                guard let resolved = resolution.destination else {
                    outcome.skipped.append(item)
                    tracker.finishItem()
                    continue
                }
                let carried = try await FileIO.perform(cancellation: options.cancellation) {
                    try Self.carry(item, to: resolved, using: perform, tracker: tracker, environment: environment)
                }
                guard let carried else {
                    outcome.wasCancelled = true
                    outcome.unprocessed = Array(items[index...])
                    break
                }
                outcome.receipts.append(carried.receipt)
                if let identity = carried.receipt.identity { placed.insert(identity) }
                tracker.finishItem()
                if let problem = carried.problem {
                    // 写しは宛先に揃っている(受領書は返した)が、元を消せなかった・置き換えた元をゴミ箱へ送れなかった。
                    // 失敗として止める ―― 利用者は「移動した」「置き換えた」つもりで、元に同じ名前が(一部だけ)残っている・
                    // 隠れた退避が残っていることを知らないと、後で混乱する。
                    outcome.failures.append(FailedItem(url: item, reason: problem))
                    outcome.unprocessed = Array(items[(index + 1)...])
                    break
                }
            } catch {
                firstError = error
                outcome.failures.append(FailedItem(url: item, reason: error.localizedDescription))
                outcome.unprocessed = Array(items[(index + 1)...])
                break
            }
        }
        // 最後の項目の衝突で「中止」を選ぶと、次の区切りが来ないまま終わる。そのままだと「スキップ」と同じ結果になり、
        // まとめた操作(CompositeFileCommand)が済んだ子を巻き戻さなかったので、中止として返す(2026-09-14)。
        if !outcome.wasCancelled, options.cancellation.isRequested { outcome.wasCancelled = true }
        // 1 件も動かずに失敗したなら、受け取るべき受領書が無いので素の失敗として投げる
        // (呼び出し側は理由をそのまま見せればよい)。
        if outcome.receipts.isEmpty, outcome.skipped.isEmpty, let firstError { throw firstError }
        return outcome
    }

    /// **1 バイトも書く前に、分かる失敗はここで全部断る。** 一括処理の途中で失敗すると、そこまでの分と
    /// それ以降の分で状態が割れる。そもそも始めないのがいちばん安全。
    ///
    /// 総量の走査は 5 万件なら数秒かかるので、この関数全体がブロッキング。
    private nonisolated static func preflight(items: [URL], destination: URL, sink: ProgressSink?, isMove: Bool, allowsCloning: Bool) throws -> ProgressTracker {
        guard itemExists(at: destination) else { throw FileOperationError.itemMissing(destination) }
        try FileOperationPreflight.checkWritable(destination)
        // 宛先への問い合わせ(pathconf)は 1 回だけ。ネットワークでは 1 回ごとに往復しうるので項目ごとに尋ねない。
        let pathLimit = FileOperationPreflight.maxPathBytes(at: destination)
        let mounts = MountTable.current()
        for item in items {
            guard itemExists(at: item) else { throw FileOperationError.itemMissing(item) }
            // **ボリュームそのもの(マウントポイント)は移動しない**(2026-09-14 の 2 回目の監査 9)。Finder でボリュームを ⌘C して ⌥⌘V、
            // ⌘ を押してドロップすると、全部写してから元を空にしていた(マウントポイントの removeItem は中身を全部消してから EBUSY)。
            // 画面の側でもボリュームの行は外しているが、ペーストボードや他のアプリからのドロップはここでしか止まらない。
            if isMove, mounts.isMounted(MountTable.normalized(item.standardizedFileURL.path)) {
                throw FileOperationError.volumeCannotBeMoved(item)
            }
            try FileOperationPreflight.checkNotInsideSource(item, destination: destination)
            // 書くときは一時名(FileCopyEngine.stagingPrefix)で書くので、その名前でも入るか。1 バイトも書かない同じボリュームの移動は除く。
            let writes = !(isMove && isOnSameVolume(item, destination, mounts: mounts))
            try checkPathFits(destination: destination, relativePath: item.lastPathComponent, item: item, limit: pathLimit, staged: writes)
        }
        // **同一ボリューム内の移動は 1 バイトも書かない**(rename)ので、走査も空き容量の検査もしない。
        // 判定はマウント表で(volumeUUID は SMB で nil になり、クローン非対応の exFAT では「一瞬で終わる」判定が
        // 偽になる ―― それで空きの少ないボリューム内の正当な移動を「空き容量不足」で断っていた。qooLibrary で発見)。
        let writesNoBytes = isMove && items.allSatisfy { isOnSameVolume($0, destination, mounts: mounts) }
        let tracker = ProgressTracker(
            sink: sink, items: items, destination: destination, writesNoBytes: writesNoBytes, mayClone: allowsCloning
        )
        if let deepest = tracker.deepestRelativePath {
            try checkPathFits(destination: destination, relativePath: deepest.path, item: deepest.item, limit: pathLimit, staged: true)
        }
        if let largest = tracker.largestFile, let limit = FileOperationPreflight.maximumFileSize(at: destination), largest.size > limit {
            throw FileOperationError.fileTooLargeForDestination(item: largest.item, size: largest.size, limit: limit)
        }
        if let longest = tracker.longestName, let limit = FileOperationPreflight.nameByteLimit(at: destination, mounts: mounts),
           longest.name.utf8.count > limit {
            throw FileOperationError.nameTooLongForDestination(name: longest.name, lengthBytes: longest.name.utf8.count, limitBytes: limit)
        }
        // 足りないと分かっているなら書かずに断る(4GB を空き 2.8GB へ運んで 2.91GB 書いてから失敗していた。qooLibrary)。
        // 見せる「必要な量」は余裕を足した値(比べた値と同じ)。足さずに見せると「1.5 GB 必要ですが、空きは 1.5 GB です」と
        // 足りているように読めた(2026-09-14、圧縮の実機検証)。
        if let required = tracker.requiredBytes, let available = FileOperationPreflight.availableCapacity(at: destination) {
            let needed = required + FileOperationPreflight.freeSpaceMargin(at: destination)
            if available < needed {
                throw FileOperationError.insufficientFreeSpace(required: needed, available: available, destination: destination)
            }
        }
        return tracker
    }

    /// - Parameter staged: 一時名で書く(先頭の要素が一時名に置き換わっても入るか)。見せる上限は一時名のぶんを引いた値
    ///   (「1020 バイト、上限は 1023」のように、入りそうに読める数字を見せない)。
    private nonisolated static func checkPathFits(destination: URL, relativePath: String, item: URL, limit: Int, staged: Bool = false) throws {
        let resulting = FileOperationPreflight.resultingPathBytes(destination: destination, relativePath: relativePath)
        let topNameBytes = relativePath.prefix { $0 != "/" }.utf8.count
        let extra = staged ? max(0, FileCopyEngine.stagingNameBytes - topNameBytes) : 0
        guard resulting + extra > limit else { return }
        throw FileOperationError.pathTooLong(item: item, resultingBytes: resulting, limitBytes: limit - extra)
    }

    // MARK: - 衝突

    /// 衝突を解いた結果。`.replace` なら、失敗したときに戻せるよう退避先も持つ。
    private nonisolated struct ResolvedDestination: Sendable {
        let target: URL
        let backupOfReplaced: URL?
        /// 置き換える項目のロックを外して退避した(片付けでゴミ箱の中・戻した先で掛け直す)。
        var unlockedReplaced = false
        /// 退避を消すことになったら、中のロックも外してよい(利用者が確認で「続ける」と答えた)。
        var mayUnlockInsideReplaced = false
    }

    private nonisolated struct Resolution: Sendable {
        /// nil = スキップ。
        let destination: ResolvedDestination?
        /// 「以降すべてに適用」で答えが決まったなら、その答え。
        let rememberedDecision: ConflictDecision?
    }

    private nonisolated enum ConflictCheck: Sendable {
        case decided(ResolvedDestination)
        case skip
        case needsUserDecision
    }

    /// **ブロッキングする部分(存在確認・退避・名前探し)とユーザーを待つ部分を分けてある。** 前者は
    /// FileIO の上、後者(conflictResolver の await)はこの actor の上。尋ねたあとにもう一度調べるのは、
    /// 考えている間に宛先が変わっているかもしれないため。
    private func resolveDestination(
        _ source: URL, _ target: URL, decision: ConflictDecision, options: FileOperationOptions, isMove: Bool,
        placedByThisOperation placed: Set<FileIdentity>, environment: FileOperationEnvironment
    ) async throws -> Resolution {
        var check = try await FileIO.perform {
            try Self.checkConflict(source, target, decision: decision, isMove: isMove, placed: placed, environment: environment)
        }
        var remembered: ConflictDecision?
        if case .needsUserDecision = check {
            guard let resolver = options.conflictResolver else {
                throw FileOperationError.conflictResolutionRequired(destination: target)
            }
            let answer = await resolver(FileConflict(source: source, destination: target))
            guard answer.policy != .ask else { throw FileOperationError.conflictResolutionRequired(destination: target) }
            if answer.applyToRemaining { remembered = answer }
            check = try await FileIO.perform {
                try Self.checkConflict(source, target, decision: answer, isMove: isMove, placed: placed, environment: environment)
            }
        }
        switch check {
        case .decided(let resolved): return Resolution(destination: resolved, rememberedDecision: remembered)
        case .skip: return Resolution(destination: nil, rememberedDecision: remembered)
        case .needsUserDecision: throw FileOperationError.conflictResolutionRequired(destination: target)
        }
    }

    /// 「置き換える」で既存の項目のロックが邪魔をするか。**触る前に**確かめる(FileBrowserOperations が確認に使う)。
    /// 退避(rename)は項目自身のロックだけが断る。ゴミ箱の無い場所では退避を消すので、中のロックも途中で止める
    /// (`removeItem` はロックされた子で止まり、そこまでの子だけが消えた木を残す)。
    nonisolated static func replacingIsBlockedByLock(_ target: URL, deletesImmediately: Bool) -> Bool {
        deletesImmediately ? containsLockedItem(target) : isLocked(target)
    }

    /// 「置き換える」の退避用の隠しフォルダの名前の頭。
    nonisolated static let replaceHolderPrefix = ".qooViewer-replace-"

    private nonisolated static func checkConflict(
        _ source: URL, _ target: URL, decision: ConflictDecision, isMove: Bool, placed: Set<FileIdentity>,
        environment: FileOperationEnvironment
    ) throws -> ConflictCheck {
        let policy = decision.policy
        let journal = environment.replaceJournal
        // 存在は**リンクを辿らずに**見る。fileExists はリンクを辿るので、リンク切れのシンボリックリンクが
        // 名前を占めていると「空いている」と誤判定し、直後の EXCL が EEXIST で失敗する。
        guard itemExists(at: target) else { return .decided(ResolvedDestination(target: target, backupOfReplaced: nil)) }
        // 同じ場所へ運ぼうとしている(自分のフォルダへのドロップ)。移動なら方針によらず何もしない
        // (「両方残す」で `name 2` へ改名してしまわない)。コピーは「両方残す」なら複製、それ以外は何もしない
        // (「置き換える」で自分自身を退避すると、運ぶ元ごと消える)。
        if source.standardizedFileURL.path == target.standardizedFileURL.path, isMove || policy != .keepBoth { return .skip }
        func keepingBoth() -> ConflictCheck {
            let folder = target.deletingLastPathComponent()
            let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let name = FileNameValidation.nextAvailableName(for: target.lastPathComponent, isDirectory: isDirectory) {
                itemExists(at: folder.appendingPathComponent($0))
            }
            return .decided(ResolvedDestination(target: folder.appendingPathComponent(name), backupOfReplaced: nil))
        }
        // **この操作で置いたばかりの項目とぶつかったら、尋ねずに両方残す**(2026-09-14 の 2 回目の監査)。別々のフォルダの同じ名前の
        // 項目(大文字小文字を区別するボリュームの `a` と `A` も)を 1 回で運ぶと、2 件目の衝突の相手は 1 件目そのもので、以前は
        // 「置き換える」(確認の答えでも、先の本物の衝突で選んだ「すべてに適用」でも)で 1 件目を退避し、ゴミ箱の無い宛先では
        // 移動してきた唯一の実体を確認なしに消していた。比べるのは実体なので、ファイルシステムの名前の畳み方(`ß`/`ss` など)に左右されない。
        if !placed.isEmpty, let existing = FileIdentity.of(target), placed.contains(existing) {
            return keepingBoth()
        }
        switch policy {
        case .ask:
            return .needsUserDecision
        case .skip:
            return .skip
        case .keepBoth:
            return keepingBoth()
        case .replace:
            // 置き換える相手が、運ぶ項目を中に含んでいる(`a/b/b` を `a` へ置き換えで運ぶ)。退避すると
            // 運ぶ項目ごと退避されてしまうので断る。
            if MountTable.path(source.standardizedFileURL.path, isAtOrUnder: target.standardizedFileURL.path) {
                throw FileOperationError.alreadyExists(target)
            }
            // **既存を消さずに同じフォルダへ退避してから書く。** 書き込みが失敗・中断したら退避を戻す
            // (壊れたコピーで健康なファイルを書き潰さない。qooLibrary でのユーザー指摘)。同じフォルダ内の
            // 移動なので rename で一瞬。
            //
            // 退避してから片付けるまでの間にアプリが落ちると、元の項目は先頭がドットの名前のまま残る
            // (Finder にも見えない)。**退避を作る前に記録し**(ReplaceBackupJournal)、次の起動で戻す
            // (段階 4b、2026-09-14)。記録が後だと、その間に落ちたときに見失う。
            //
            // 退避先は `.qooViewer-replace-<UUID>/<元の名前>`(隠しフォルダの中に元の名前のまま)。フォルダごと
            // 名前を変えて退避すると、ゴミ箱へ送ったときに「.qooViewer-replace-…」という名前で入り、利用者が
            // 何を置き換えたのか分からない。
            //
            // ロックされた項目は rename できない(EPERM)。「権限がありません」ではなく「ロックされています」と伝える。
            // ゴミ箱の無い場所では退避をすぐに消すので、中のロックも**退避する前に**見る(2026-09-14。以前は退避を消す
            // 途中でロックされた子に当たって止まり、記録が残って次の起動で警告された ―― 計画 §4.11)。
            // 利用者が確認で「続ける」と答えていれば(unlockingLocked)、項目自身のロックを外して退避する。
            let deletesImmediately = !environment.hasTrash(target.deletingLastPathComponent())
            var unlockedReplaced = false
            if replacingIsBlockedByLock(target, deletesImmediately: deletesImmediately) {
                guard decision.unlockingLocked else { throw FileOperationError.itemLocked(target) }
                if isLocked(target) {
                    guard setLocked(target, false) else { throw FileOperationError.itemLocked(target) }
                    unlockedReplaced = true
                }
            }
            let holder = target.deletingLastPathComponent().appendingPathComponent("\(replaceHolderPrefix)\(UUID().uuidString)", isDirectory: true)
            let backup = holder.appendingPathComponent(target.lastPathComponent)
            journal.record(backup: backup, target: target)
            guard mkdir(holder.path, 0o700) == 0 else {
                let code = errno
                journal.forget(backup: backup)
                if unlockedReplaced { setLocked(target, true) }
                throw FileOperationError.posixFailure(item: target, errnoCode: code)
            }
            let code = exclusiveRename(from: target, to: backup)
            guard code == 0 else {
                rmdir(holder.path)
                // 退避を作れなかったのだから記録も要らない(残すと、無い退避を次の起動で探す)。
                journal.forget(backup: backup)
                if unlockedReplaced { setLocked(target, true) }
                throw FileOperationError.posixFailure(item: target, errnoCode: code)
            }
            return .decided(ResolvedDestination(
                target: target, backupOfReplaced: backup, unlockedReplaced: unlockedReplaced, mayUnlockInsideReplaced: decision.unlockingLocked
            ))
        }
    }

    // MARK: - 1 項目を運ぶ(ブロッキング側)

    /// 1 項目を運んだ結果。
    private nonisolated struct Carried: Sendable {
        let receipt: TransferReceipt
        /// 運べたが、片付けの一部ができなかった(表示言語の理由)。別ボリュームへの移動で元を消せなかった、
        /// 「置き換える」で置き換えられた元をゴミ箱へ送れなかった(隠れた退避として残した)。
        let problem: String?
    }

    /// 1 項目を運ぶ。中止されたら nil(書きかけは片付け、`.replace` の退避は戻してある)。
    private nonisolated static func carry(
        _ item: URL,
        to resolved: ResolvedDestination,
        using perform: (URL, URL, @escaping (Int64) -> Void) throws -> FileCopyEngine.Outcome,
        tracker: ProgressTracker,
        environment: FileOperationEnvironment
    ) throws -> Carried? {
        let outcome: FileCopyEngine.Outcome
        do {
            // **元が変わっていないかの検証は、退避を片付ける前に済んでいる**(FileCopyEngine.copy が置く前に確かめる)。
            // 片付けたあとで失敗させると、置き換えられた元と新しいコピーの両方を失う(qooLibrary で監査により発見)。
            outcome = try perform(item, resolved.target) { tracker.addBytes($0) }
        } catch {
            try restoreReplacedItem(resolved, journal: environment.replaceJournal)
            throw error
        }

        guard outcome.hasCompleteCopy else {
            // 中止。書きかけは FileCopyEngine が一時名ごと消してある(宛先の名前には何も置いていない)。
            try restoreReplacedItem(resolved, journal: environment.replaceJournal)
            return nil
        }

        var replacedInTrash: URL?
        var replacedItemKept: String?
        if let backup = resolved.backupOfReplaced {
            // 退避は**消さずにゴミ箱へ**(「置き換える」の直後の Undo で、置き換えられた元を手で戻せる)。
            // ゴミ箱へ送れない場所(SMB)では消すしかない ―― そこで「置き換える」を選ぶ前の確認は段階 4 の UI の仕事。
            let hasTrash = environment.hasTrash(backup.deletingLastPathComponent())
            if hasTrash {
                replacedInTrash = environment.trashItemSynchronously(backup)
            }
            if let replacedInTrash, resolved.unlockedReplaced {
                // ゴミ箱の中でロックを掛け直す(trash の unlockingLocked と同じ。戻したときにロックも戻る)。
                setLocked(replacedInTrash, true)
            }
            if hasTrash, replacedInTrash == nil {
                // **ゴミ箱のある場所で送れなかったら、消さずに残す**(2026-09-14 の監査 8)。以前はここから完全削除へ落ちていて、
                // 利用者は「ゴミ箱に入る」と確認したつもりの元の項目を、確認なしに失っていた。退避と記録はそのまま残し
                // (次の起動の復旧が「隠れた項目が残っている」と知らせる)、いまも失敗として伝える。
                // 実測では新品の exFAT / FAT32 / APFS でも `trashItem` は通り、項目自身が `uchg` のとき(-5000)くらいしか失敗しない。
                replacedItemKept = FileOperationError.replacedItemKept(
                    backup: backup.deletingLastPathComponent(), target: resolved.target
                ).localizedDescription
                // 外したロックは残す退避の上で掛け直す(2026-09-15 の 3 回目の監査。起動時の復旧はロックを知らない)。
                if resolved.unlockedReplaced { setLocked(backup, true) }
            } else if replacedInTrash == nil {
                // 消す。**中にロックされた項目があれば、許しがあるときだけ外してから**(無ければ消し始めない ――
                // 途中で止まって半分だけ消えた木を残すより、記録ごと残して次の起動で知らせるほうがよい)。
                let locked = lockedItems(atOrUnder: backup)
                if locked.isEmpty || resolved.mayUnlockInsideReplaced {
                    for url in locked { setLocked(url, false) }
                    try? removeAbsorbingTransientFailure(at: backup)
                }
            }
            // 片付いたときだけ記録を落とす。**消せなければ残す**(次の起動の復旧が、元の場所が埋まっているので
            // 「隠れた項目が残っている」と知らせる)。
            if !itemExists(at: backup) { environment.replaceJournal.forget(backup: backup) }
            rmdir(backup.deletingLastPathComponent().path)
        }
        let receipt = TransferReceipt(
            source: item, destination: resolved.target, replacedItemInTrash: replacedInTrash, identity: FileIdentity.of(resolved.target),
            replacedItemIdentity: replacedInTrash.flatMap(FileIdentity.of)
        )
        if case let .copiedButSourceRemains(_, reason) = outcome {
            return Carried(receipt: receipt, problem: [reason, replacedItemKept].compactMap(\.self).joined(separator: " "))
        }
        return Carried(receipt: receipt, problem: replacedItemKept)
    }

    /// 書き終えなかったときに、退避した元の項目を戻す。戻せなければ `replaceBackupOrphaned` を投げる
    /// (元の失敗より「元の項目が見えない名前で残っている」ほうが伝えるべき事実)。
    /// 戻せなかったときは記録を残す(次の起動の復旧がもう一度試す。相手がネットワークなら、次は繋がっているかもしれない)。
    ///
    /// **宛先の名前にあるものは消さない**(2026-09-14 の 2 回目の監査 8)。以前はそこにあるものを書きかけとみなして消してから戻していたが、
    /// 書きかけは FileCopyEngine が一時名で片付けるので、ここに何かあるならそれは他人が置いた項目。消さずに退避を残し、
    /// `replaceBackupOrphaned` で伝える。
    private nonisolated static func restoreReplacedItem(_ resolved: ResolvedDestination, journal: ReplaceBackupJournal) throws {
        guard let backup = resolved.backupOfReplaced else { return }
        if exclusiveRename(from: backup, to: resolved.target) != 0 {
            // 戻せずに退避を残すなら、外したロックはそこで掛け直す(3 回目の監査)。
            if resolved.unlockedReplaced { setLocked(backup, true) }
            throw FileOperationError.replaceBackupOrphaned(backup: backup.deletingLastPathComponent(), target: resolved.target)
        }
        if resolved.unlockedReplaced { setLocked(resolved.target, true) }
        journal.forget(backup: backup)
        rmdir(backup.deletingLastPathComponent().path)
    }

    /// 移動の実体。**同一ボリュームなら rename(2) で一瞬**。別ボリュームは「コピーしてから元を消す」しかなく、
    /// そこは FileCopyEngine に任せて進捗と中止を効かせる。中止されたら元を消さない。
    nonisolated static func moveItem(
        from source: URL, to target: URL, allowsCloning: Bool = true, onBytesCopied: @escaping (Int64) -> Void
    ) throws -> FileCopyEngine.Outcome {
        let renameCode = exclusiveRename(from: source, to: target)
        if renameCode == 0 { return .completed(bytes: 0) }
        guard renameCode == EXDEV else { throw FileOperationError.posixFailure(item: source, errnoCode: renameCode) }

        // **運ぶ前後で元が変わっていないことは FileCopyEngine.copy が置く前に確かめる。** 書き込み中のファイル(ダウンロード中など)を
        // 運ぶと copyfile はその時点の姿を写して成功を返し、元を消すと書き足された分が永久に失われる
        // (72.3MB を写したあと元は 84.9MB まで伸びた。qooLibrary 実測)。
        // 元の削除で、写した後に変わった元の項目を消さないための確かめ方(`SourceChangeCheck`。時刻を使うなら写し始める前に取る)。
        let changeCheck = sourceChangeCheck(for: source, mounts: .current())
        let outcome = try FileCopyEngine.copy(from: source, to: target, allowsCloning: allowsCloning, onBytesCopied: onBytesCopied)
        guard case .completed = outcome else { return outcome }
        do {
            try removeTransferredSource(source, copiedTo: target, changeCheck: changeCheck)
        } catch {
            // **元を消し始めたあとは、写した側を絶対に消さない。** `removeItem` は木の削除が途中で失敗しても消した分を
            // 戻さないので、ここで宛先を片付けると元からも宛先からも兄弟が消える(2026-09-14 の監査で実測: `uappnd` の
            // ファイルを含むフォルダの移動で、元も宛先もそのファイルだけになり 6 ファイルが消失。以前はここで宛先を消していた)。
            // 引き金は他のクライアントやこのアプリが掴んでいる SMB 上のファイル(EBUSY / ENOTEMPTY)、途中で現れた
            // `.DS_Store`、`uappnd`・ACL の付いた子。写しを残して「元を消せなかった」と伝える(受領書は返す)。
            guard case let .completed(bytes) = outcome else { return outcome }
            return .copiedButSourceRemains(
                bytes: bytes,
                reason: FileOperationError.sourceRemainsAfterMove(item: source, reason: removalFailureReason(error)).localizedDescription
            )
        }
        return outcome
    }

    /// **宛先があれば失敗する改名。** 成功なら 0、失敗ならその errno。
    ///
    /// 素の rename(2) は宛先を黙って上書きする。`renamex_np(RENAME_EXCL)` を使い、**SMB では宛先が無いときに
    /// ENOTSUP が返る**(宛先があるときは EEXIST なので、衝突のケースしか測らないと「動く」と誤認する ――
    /// qooLibrary では共有の中の移動がすべて壊れていた)ので、そのときだけ lstat で確かめてから rename(2)。
    /// 縮退で失うのはアトミック性だけ(lstat と rename の間のマイクロ秒の窓)。
    nonisolated static func exclusiveRename(from source: URL, to target: URL) -> Int32 {
        if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let code = errno
        guard code == ENOTSUP || code == EOPNOTSUPP else { return code }
        return renameCheckingDestinationFirst(from: source, to: target)
    }

    /// `exclusiveRename` の縮退経路。**この経路だけを切り離して確かめられるよう internal**
    /// (非対応のボリュームは衝突時に EEXIST を返すので、exclusiveRename 越しの衝突テストは縮退経路へ入らない)。
    nonisolated static func renameCheckingDestinationFirst(from source: URL, to target: URL) -> Int32 {
        var existing = stat()
        if lstat(target.path, &existing) == 0 { return EEXIST }
        return Darwin.rename(source.path, target.path) == 0 ? 0 : errno
    }

    // MARK: - 削除まわり(ブロッキング側)

    /// **一過性の削除失敗だけを吸収して消す。** SMB では中身のあるフォルダの削除が 5 回に 1 回 EPERM で
    /// 失敗し、100ms 後には必ず通る(自分で消した子がサーバ側で片付くまでの隙間。qooLibrary 実測 6/6)。
    /// **ENOTEMPTY は試し直さない** ―― 外のアプリが中のファイルを開いたままのときに出て、待っても直らない。
    nonisolated static func removeAbsorbingTransientFailure(at item: URL) throws {
        var attempt = 0
        while true {
            do {
                try FileManager.default.removeItem(at: item)
                return
            } catch {
                guard itemExists(at: item) else { return }
                attempt += 1
                guard attempt <= 3, isTransientRemovalFailure(error), !Cancellation.isRequestedInCurrentScope else { throw error }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    /// 別ボリュームへ写し終えた元を消す。**フォルダは、写した先にもある項目だけを下から 1 つずつ消す**(2026-09-14 の 2 回目の監査 7)。
    ///
    /// 以前は `removeItem` で木ごと消していたので、写し終えてから消し終えるまでの間に元のフォルダへ作られた項目(ダウンロードの続き、
    /// 他のアプリの書き出し)も消え、どこにも残らなかった。写した先に無い項目が残れば、その親の rmdir が ENOTEMPTY で断るので、元は残り
    /// 「元を消せなかった」として伝わる(両方に残る側に倒れる)。種類が入れ替わった項目にも触らない。**リンクは辿らない**(lstat・unlink)。
    /// 最初の失敗で止める(`removeItem` と同じ。消した分は写した先にある)。
    ///
    /// **名前は `readdir` で取る**(2026-09-15 の 3 回目の監査)。`FileManager.contentsOfDirectory` は APFS の上でも `._*` を返さない(実測)ので、
    /// 以前は元の `._` ファイルが消す対象に入らず、`._` だけが残ったフォルダへ `rmdir` を呼んでいた(カーネルが孤立した AppleDouble を
    /// 片付ける経路。exFAT の使い捨てボリュームでその `rmdir` が戻らなくなり、Finder ごと固まった ―― 原因は未確定)。
    /// **フォルダは中が空だと確かめてから `rmdir` する**(空でなければ呼ばずに ENOTEMPTY で止める)。`._` は同じフォルダの中で最後に消す
    /// (本体を消すと対の `._` もカーネルが消すので、先に `._` だけを消して本体の拡張属性を失う形を作らない)。
    ///
    /// - Parameter changeCheck: **写した後に変わった元のファイル・リンクは消さずに止める**(3 回目の監査。`MoveVerification` は置く前に
    ///   1 回見るだけなので、その後の保存・ダウンロードの完了を消していた)。確かめ方はボリュームで変わる(`SourceChangeCheck`)。
    ///   フォルダは見ない(自分が中を消すと ctime が変わる)。同じ木の中のハードリンクの兄弟は、片方を消すと残りの ctime も変わるので
    ///   失敗として残る(残す側に倒れるだけ)。
    nonisolated static func removeTransferredSource(_ source: URL, copiedTo copy: URL, changeCheck: SourceChangeCheck = .none) throws {
        var info = stat()
        guard lstat(source.path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            var copied = stat()
            let copyExists = lstat(copy.path, &copied) == 0
            if sourceChanged(info, copied: copyExists ? copied : nil, check: changeCheck) {
                throw FileOperationError.sourceChangedDuringOperation(source)
            }
            try removeAbsorbingTransientFailure(at: source)
            return
        }
        // (相対パス, 子を積み終えたか)。子を積んだフォルダは帰りがけにもう一度出てきて、そこで消す。
        var pending: [(relative: String, expanded: Bool)] = [("", false)]
        while let (relative, expanded) = pending.popLast() {
            let sourcePath = relative.isEmpty ? source.path : source.path + "/" + relative
            let copyPath = relative.isEmpty ? copy.path : copy.path + "/" + relative
            var copied = stat()
            var original = stat()
            guard lstat(copyPath, &copied) == 0, lstat(sourcePath, &original) == 0 else { continue }
            let isDirectory = original.st_mode & S_IFMT == S_IFDIR
            guard isDirectory == (copied.st_mode & S_IFMT == S_IFDIR) else { continue }
            if isDirectory, !expanded {
                pending.append((relative, true))
                // 積む順の逆に取り出されるので、`._` を先に積んで後に消す。
                let names = try directoryEntryNames(atPath: copyPath).sorted { $0.hasPrefix("._") && !$1.hasPrefix("._") }
                pending.append(contentsOf: names.map { (relative.isEmpty ? $0 : relative + "/" + $0, false) })
                continue
            }
            if isDirectory {
                guard try directoryEntryNames(atPath: sourcePath).isEmpty else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTEMPTY), userInfo: [NSFilePathErrorKey: sourcePath])
                }
            } else if sourceChanged(original, copied: copied, check: changeCheck) {
                throw FileOperationError.sourceChangedDuringOperation(URL(fileURLWithPath: sourcePath))
            }
            try removeEntryAbsorbingTransientFailure(sourcePath, isDirectory: isDirectory)
        }
    }

    /// フォルダの中の名前を `readdir` で(`.` と `..` を除き、**`._*` も含めて**)。開けなければ errno で投げる。
    nonisolated static func directoryEntryNames(atPath path: String) throws -> [String] {
        guard let directory = opendir(path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// 別ボリュームへ写した元を消す前に、写した後に元が変わっていないかをどう確かめるか(`removeTransferredSource`)。
    nonisolated enum SourceChangeCheck {
        /// 確かめない(元がネットワークにあり、日時はサーバの都合で差し替わる)。
        case none
        /// この時刻(写し始める前)より後に ctime が変わった元を残す。ctime を利用者やアプリが書き換えられないボリューム(APFS・HFS+ など)。
        /// 更新日時を保つ書き込み(Finder のコピー、`cp -p`)も ctime は今になるので捕まえる。
        case changedSince(timespec)
        /// 大きさと更新日時を写しと比べる。**FAT・exFAT は ctime が更新日時そのもの**(2026-09-15 の 4 回目の監査で実測: `touch -t` で
        /// 更新日時を 1 時間前・3 時間後に動かすと ctime も同じだけ動く。Apple の msdosfs も `va_change_time = va_modify_time`)なので
        /// 時刻と比べられない。比べると、未来の日時のファイル(カメラの時計のずれ、ローカル時刻で書く FAT32 を持って西へ移動した)は
        /// 毎回「変わった」になって移動が 1 件目で止まり、過去の日時を保つ上書きは見逃して新しい中身ごと消していた。
        /// copyfile は更新日時を写すので、写した後に変わっていなければ一致する(宛先の粒度で切り捨てられる分は許す)。
        case matchesCopy
    }

    /// ctime が更新日時そのもので、時刻と比べられないファイルシステム(`f_fstypename`)。
    nonisolated static let fileSystemsWithoutChangeTime: Set<String> = ["msdos", "exfat"]

    /// 写しの更新日時が元とずれてよい幅。FAT32 の粒度(2 秒、切り捨て)。exFAT は 10ms、HFS+ は 1 秒。
    nonisolated static let modificationDateToleranceNanoseconds: Int64 = 2_000_000_000

    /// `source` を別ボリュームへ運ぶときの確かめ方。**時刻を使う場合は写し始める前に呼ぶ**(その時点の時刻を控える)。
    nonisolated static func sourceChangeCheck(for source: URL, mounts: MountTable) -> SourceChangeCheck {
        guard let entry = mounts.entry(containing: source), entry.isLocal else { return .none }
        if fileSystemsWithoutChangeTime.contains(entry.fileSystemType.lowercased()) { return .matchesCopy }
        return .changedSince(currentRealTime())
    }

    /// 元の 1 項目(フォルダ以外)が、写した後に変わったとみなすか。`copied` は写した側の同じ項目(無ければ nil)。
    nonisolated static func sourceChanged(_ original: stat, copied: stat?, check: SourceChangeCheck) -> Bool {
        switch check {
        case .none:
            return false
        case let .changedSince(reference):
            return isLater(original.st_ctimespec, than: reference)
        case .matchesCopy:
            // 写した側が無い・種類が違うなら、写しと同じとは言えない(残す側に倒す)。FAT・exFAT にリンクは無いので普通のファイルだけを比べる。
            guard let copied else { return true }
            guard original.st_mode & S_IFMT == S_IFREG else { return false }
            guard copied.st_mode & S_IFMT == S_IFREG, original.st_size == copied.st_size else { return true }
            let difference = nanoseconds(original.st_mtimespec) - nanoseconds(copied.st_mtimespec)
            return abs(difference) > modificationDateToleranceNanoseconds
        }
    }

    /// 今の時刻(ファイルシステムの ctime と比べる)。
    nonisolated static func currentRealTime() -> timespec {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return now
    }

    private nonisolated static func isLater(_ time: timespec, than reference: timespec) -> Bool {
        time.tv_sec != reference.tv_sec ? time.tv_sec > reference.tv_sec : time.tv_nsec > reference.tv_nsec
    }

    private nonisolated static func nanoseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }

    /// 1 項目だけを消す(フォルダは空のときだけ)。一過性の失敗の扱いは `removeAbsorbingTransientFailure` と同じ。
    private nonisolated static func removeEntryAbsorbingTransientFailure(_ path: String, isDirectory: Bool) throws {
        var attempt = 0
        while (isDirectory ? rmdir(path) : unlink(path)) != 0 {
            let code = errno
            if code == ENOENT { return }
            attempt += 1
            guard attempt <= 3, code == EPERM || code == EBUSY, !Cancellation.isRequestedInCurrentScope else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// 削除の失敗を表示言語の短い文へ(Foundation の説明は OS の言語なので、errno が分かればそちらを使う)。
    nonisolated static func removalFailureReason(_ error: any Error) -> String {
        let nsError = error as NSError
        let underlying = nsError.domain == NSPOSIXErrorDomain ? nsError : nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        if let underlying, underlying.domain == NSPOSIXErrorDomain { return PosixFailure.reason(Int32(underlying.code)) }
        return nsError.localizedDescription
    }

    nonisolated static func isTransientRemovalFailure(_ error: any Error) -> Bool {
        let nsError = error as NSError
        let underlying = nsError.domain == NSPOSIXErrorDomain ? nsError : nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        guard let underlying, underlying.domain == NSPOSIXErrorDomain else { return false }
        return underlying.code == Int(EPERM) || underlying.code == Int(EBUSY)
    }

    /// 書きかけを片付ける。失敗しても投げない(呼び出し側は既に別の失敗・中止を伝えている)。
    /// **自分が書いたものにだけ使う**(FileCopyEngine の失敗時の片付けもここを通る)。
    ///
    /// **書きかけに写った保護を外してから消し直す**(2026-09-14 の 2 回目の監査で実測)。copyfile はフォルダを写し終えるたびに
    /// そのフォルダの権限(0555 など)を掛け、ロック(`uchg`)も写すので、途中で止めた木は `removeItem` が EACCES / EPERM で
    /// 途中までしか消せず、宛先の名前のまま中途半端な木が残っていた(受領書が無いので取り消しでも誰も片付けない。
    /// 「置き換える」なら宛先を空けられず、元の項目が隠しフォルダに残ったままになった)。
    /// 保護を外すのは自分が書いた木だからできること ―― 他人の項目には使わない。
    nonisolated static func removePartialWrite(at url: URL) {
        try? removeAbsorbingTransientFailure(at: url)
        guard itemExists(at: url) else { return }
        liftWriteProtection(under: url)
        try? removeAbsorbingTransientFailure(at: url)
    }

    /// `root` と中の項目から、削除を断るもの(ロック・追記のみのフラグ、持ち主の書き込み・読み取り・実行権の無いフォルダ)を外す。
    /// **リンクを辿らない**(lstat / lchflags、chmod はフォルダにだけ)。フォルダは外してから中を読む(0000 のフォルダも開ける)。
    /// 再帰せずに自分のスタックで歩く(深い木でスレッドのスタックを使い切らない)。
    nonisolated static func liftWriteProtection(under root: URL) {
        let blockingFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
        var pending = [root.path]
        while let path = pending.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if info.st_flags & blockingFlags != 0 {
                lchflags(path, info.st_flags & ~blockingFlags)
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            if info.st_mode & S_IRWXU != S_IRWXU {
                chmod(path, (info.st_mode & 0o7777) | S_IRWXU)
            }
            // `._*` も拾う(`directoryEntryNames`。FileManager は返さない)。
            guard let children = try? directoryEntryNames(atPath: path) else { continue }
            pending.append(contentsOf: children.map { (path as NSString).appendingPathComponent($0) })
        }
    }

    // MARK: - ロック(ブロッキング側)

    /// Finder の「ロック」(`uchg`)が掛かっているか。**リンクを辿らない**(lstat)。
    nonisolated static func isLocked(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) != 0
    }

    /// ロックを掛ける・外す。**リンクを辿らない**(lchflags。リンク先のロックを外してしまわない)。成功なら true。
    @discardableResult
    nonisolated static func setLocked(_ url: URL, _ locked: Bool) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        let flags = locked ? info.st_flags | UInt32(UF_IMMUTABLE) : info.st_flags & ~UInt32(UF_IMMUTABLE)
        return flags == info.st_flags || lchflags(url.path, flags) == 0
    }

    /// その項目自身か、フォルダなら中のどれかがロックされているか(見つけた時点で打ち切る)。
    nonisolated static func containsLockedItem(_ url: URL) -> Bool {
        isLocked(url) || !lockedItems(atOrUnder: url, stopAtFirst: true).isEmpty
    }

    /// その項目自身と、フォルダなら中のロックされた項目。**シンボリックリンクの先へは入らない**
    /// (`removeItem` はリンク自体しか消さないので、リンク先のロックを外す理由が無い。qooLibrary でレビューにより発見)。
    nonisolated static func lockedItems(atOrUnder url: URL, stopAtFirst: Bool = false) -> [URL] {
        var result: [URL] = isLocked(url) ? [url] : []
        if stopAtFirst, !result.isEmpty { return result }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [])
        else { return result }
        for case let child as URL in enumerator where isLocked(child) {
            result.append(child)
            if stopAtFirst { break }
        }
        return result
    }

    /// シンボリックリンク自体も「ある」と数える(fileExists はリンクを辿るので、リンク切れを「無い」と誤る)。
    nonisolated static func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// 名前の違いが大文字小文字と Unicode の正規化(NFC / NFD)だけか(改名の「自分自身」の判定)。
    ///
    /// **同じ実体を指すだけでは足りない**(2026-09-14 の監査)。同じフォルダの中のハードリンクの兄弟も同じ inode なので、
    /// 以前は `a.txt` → `b.txt`(b が a のハードリンク)を「自分自身」として素の rename(2) に回し、rename(2) は同じ実体への
    /// 改名を**何もせずに成功**として返す(POSIX)ので、名前は変わらないまま「変えた」と報告し、取り消しの記録も積んでいた。
    /// Swift の `==` は正規化の違いを同じと見るので、大文字小文字をそろえて比べれば足りる。
    nonisolated static func namesDifferOnlyInCaseOrNormalization(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }

    /// 2 つのパスが同じ実体か(大文字小文字・正規化違いの改名の判定)。どちらかが無ければ別。
    private nonisolated static func refersToSameEntry(_ a: URL, _ b: URL) -> Bool {
        var left = stat()
        var right = stat()
        guard lstat(a.path, &left) == 0, lstat(b.path, &right) == 0 else { return false }
        return left.st_ino == right.st_ino && left.st_dev == right.st_dev
    }
}
