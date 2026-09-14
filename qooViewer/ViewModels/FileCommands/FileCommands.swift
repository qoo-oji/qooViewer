import Foundation

// ファイルブラウザの個々の操作(改善要望7 段階 2、2026-09-13。qooLibrary の FileCommands.swift を写したもの)。
// どの操作も、取り消しは**実行時に受け取った受領書だけ**を頼りに組み立てる(実行後に画面や名前から推測しない)。
//
// 圧縮・展開(段階 6)は CompressFilesCommand / ExtractArchivesCommand。

extension FileOperationService {
    /// ファイルブラウザのコマンドが既定で使うインスタンス。状態を持たないので 1 つで足りる。
    nonisolated static let shared = FileOperationService()
}

/// 移動。取り消しは逆向きの移動で、**戻す先に何かできていたら壊さず `name 2` で戻す**(`.keepBoth`)。
/// そうして名前が変わったら「部分的に戻した」として見せる。
@MainActor
final class MoveFilesCommand: FileCommand {
    private let items: [URL]
    private let destination: URL
    private let options: FileOperationOptions
    private let fileOps: FileOperationService
    private(set) var outcome = TransferOutcome()
    /// false: 元のフォルダへ書けず戻せないと分かっていて、利用者が承知で移動した(FileBrowserOperations の transfer)。
    let isUndoable: Bool

    init(
        items: [URL], destination: URL, options: FileOperationOptions, isUndoable: Bool = true,
        fileOps: FileOperationService = .shared
    ) {
        self.items = items
        self.destination = destination
        self.options = options
        self.isUndoable = isUndoable
        self.fileOps = fileOps
    }

    var displayName: String {
        let locale = AppLanguage.currentLocale
        return items.count == 1
            ? String(format: String(localized: "Move of “%@”", language: locale), items[0].lastPathComponent)
            : String(format: String(localized: "Move of %lld Items", language: locale), items.count)
    }

    /// ペースト・D&D の完了音(Finder もペーストで鳴らす)。
    let completionSound: SystemSoundEffect? = .operationComplete

    func execute() async throws -> FileCommandResult {
        outcome = try await fileOps.move(items, to: destination, options: options)
        return .from(outcome)
    }

    func redo(in context: FileCommandContext) async throws -> FileCommandResult {
        outcome = try await fileOps.move(items, to: destination, options: context.applied(to: options))
        return .from(outcome)
    }

    func undo() async throws -> FileUndoResult {
        try await undo(in: FileCommandContext())
    }

    func undo(in context: FileCommandContext) async throws -> FileUndoResult {
        try await TransferUndo.undo(outcome.receipts, fileOps: fileOps, cancellation: context.cancellation) { receipt in
            // 自分が運んだものなので、ロックされていても尋ねずに外して戻す(戻した先で掛け直す)。
            let putBack = try await self.fileOps.move(
                [receipt.destination], to: receipt.source.deletingLastPathComponent(),
                options: FileOperationOptions(
                    conflictPolicy: .keepBoth, progress: context.progress, cancellation: context.cancellation, unlockingLocked: true
                )
            )
            return putBack.wasCancelled ? .cancelled : putBack.receipts.first.map { .restored($0.destination) } ?? .missing
        }
    }
}

/// コピー。取り消しは**作ったものをゴミ箱へ**(完全には消さない ―― 取り消しが新しいデータ喪失を持ち込まない)。
@MainActor
final class CopyFilesCommand: FileCommand {
    private let items: [URL]
    private let destination: URL
    private let options: FileOperationOptions
    private let fileOps: FileOperationService
    private(set) var outcome = TransferOutcome()

    init(items: [URL], destination: URL, options: FileOperationOptions, fileOps: FileOperationService = .shared) {
        self.items = items
        self.destination = destination
        self.options = options
        self.fileOps = fileOps
    }

    var displayName: String {
        let locale = AppLanguage.currentLocale
        return items.count == 1
            ? String(format: String(localized: "Copy of “%@”", language: locale), items[0].lastPathComponent)
            : String(format: String(localized: "Copy of %lld Items", language: locale), items.count)
    }

    let isUndoable = true
    let completionSound: SystemSoundEffect? = .operationComplete

    func execute() async throws -> FileCommandResult {
        outcome = try await fileOps.copy(items, to: destination, options: options)
        return .from(outcome)
    }

    func redo(in context: FileCommandContext) async throws -> FileCommandResult {
        outcome = try await fileOps.copy(items, to: destination, options: context.applied(to: options))
        return .from(outcome)
    }

    func undo() async throws -> FileUndoResult {
        guard !outcome.receipts.isEmpty else { return .impossible(reason: TransferUndo.nothingToRestore) }
        // **作ったそのものだけを**ゴミ箱へ(FileIdentity の型コメント。同じ名前の別の項目に変わっていたら触らない)。
        let receipts = outcome.receipts
        let (ours, changed) = await FileIO.perform { TransferUndo.partitionByIdentity(receipts) }
        let changedFailures = changed.map { FailedItem(url: $0.destination, reason: TransferUndo.changedReason(for: $0.destination)) }
        guard !ours.isEmpty else { return .impossible(reason: changedFailures[0].reason) }
        // コピーの取り消しは受領書をまとめて 1 回でゴミ箱へ(ゴミ箱の無い場所では取り消せない ――
        // 黙って完全削除しない)。ロックされた元をコピーするとロックも写るので、**自分が作ったものに限って**
        // 尋ねずにロックを外して送る(ゴミ箱の中でロックは掛け直される)。
        let trashed: TrashOutcome
        do {
            trashed = try await fileOps.trash(ours.map(\.destination), unlockingLocked: true)
        } catch {
            // 何も送れていない。作ったものは残っているので、原因が片付けば試し直せる(別の項目に変わったものが無ければ)。
            return .impossible(reason: error.localizedDescription, canRetry: changed.isEmpty && TransferUndo.canRetryTrashing(after: error))
        }
        var failures = changedFailures + trashed.failures
        // 「置き換える」で退避した元の項目があれば、空いた場所へ戻す(送れた項目の分だけ)。
        let sent = Set(trashed.receipts.map(\.originalURL))
        let replaced = ours.filter { sent.contains($0.destination) }.compactMap { receipt in
            receipt.replacedItemInTrash.map {
                TrashReceipt(originalURL: receipt.destination, trashURL: $0, identity: receipt.replacedItemIdentity)
            }
        }
        failures += await fileOps.restoreFromTrash(replaced).failures
        if failures.isEmpty { return .complete }
        return trashed.receipts.isEmpty
            ? .impossible(reason: failures[0].reason, canRetry: changed.isEmpty)
            : .partial(succeeded: trashed.receipts.count, failures: failures)
    }
}

/// 圧縮(段階 6)。取り消しは**作った zip をゴミ箱へ**(コピーの取り消しと同じ考え。元の項目には触っていない)。
@MainActor
final class CompressFilesCommand: FileCommand {
    private let items: [URL]
    private let destination: URL
    private let baseName: String
    private let fileExtension: String
    private var progress: ProgressSink?
    private var cancellation: Cancellation
    private let fileOps: FileOperationService
    private(set) var receipt: TransferReceipt?

    init(
        items: [URL], destination: URL, baseName: String, fileExtension: String, progress: ProgressSink? = nil,
        cancellation: Cancellation = Cancellation(), fileOps: FileOperationService = .shared
    ) {
        self.items = items
        self.destination = destination
        self.baseName = baseName
        self.fileExtension = fileExtension
        self.progress = progress
        self.cancellation = cancellation
        self.fileOps = fileOps
    }

    var displayName: String {
        let locale = AppLanguage.currentLocale
        return items.count == 1
            ? String(format: String(localized: "Compression of “%@”", language: locale), items[0].lastPathComponent)
            : String(format: String(localized: "Compression of %lld Items", language: locale), items.count)
    }

    let isUndoable = true
    let completionSound: SystemSoundEffect? = .operationComplete

    func execute() async throws -> FileCommandResult {
        receipt = try await fileOps.compress(
            items, into: destination, baseName: baseName, fileExtension: fileExtension,
            progress: progress, cancellation: cancellation
        )
        guard receipt != nil else { throw CancellationError() }
        return .success
    }

    func redo(in context: FileCommandContext) async throws -> FileCommandResult {
        progress = context.progress
        cancellation = context.cancellation
        return try await execute()
    }

    func undo() async throws -> FileUndoResult {
        guard let receipt else { return .impossible(reason: TransferUndo.nothingToRestore) }
        return await TransferUndo.trashCreated([receipt], fileOps: fileOps)
    }
}

/// 展開(段階 6)。取り消しは**置いた項目をゴミ箱へ**(「ここに展開」は展開先の既存の項目と混ざるので、フォルダ丸ごとではなく
/// 置いたものだけ。「〈名前〉に展開」は作ったフォルダ 1 つ)。書庫そのものには触っていない。
///
/// 使えないエントリ(危険なパス・記号リンク)を捨てたときは、展開が済んでいても一部だけ済んだとして報告に並べる。
@MainActor
final class ExtractArchivesCommand: FileCommand {
    private let archives: [URL]
    private let destination: URL
    private let placement: ArchiveExtractor.Placement
    private let limits: ArchiveExtractionLimits
    private var progress: ProgressSink?
    private var cancellation: Cancellation
    private let fileOps: FileOperationService
    private(set) var receipts: [TransferReceipt] = []

    init(
        archives: [URL], destination: URL, placement: ArchiveExtractor.Placement, limits: ArchiveExtractionLimits = .standard,
        progress: ProgressSink? = nil, cancellation: Cancellation = Cancellation(), fileOps: FileOperationService = .shared
    ) {
        self.archives = archives
        self.destination = destination
        self.placement = placement
        self.limits = limits
        self.progress = progress
        self.cancellation = cancellation
        self.fileOps = fileOps
    }

    var displayName: String {
        let locale = AppLanguage.currentLocale
        return archives.count == 1
            ? String(format: String(localized: "Extraction of “%@”", language: locale), archives[0].lastPathComponent)
            : String(format: String(localized: "Extraction of %lld Archives", language: locale), archives.count)
    }

    let isUndoable = true
    let completionSound: SystemSoundEffect? = .operationComplete

    func execute() async throws -> FileCommandResult {
        let outcome = try await fileOps.extract(
            archives, into: destination, placement: placement, limits: limits, progress: progress, cancellation: cancellation
        )
        receipts = outcome.receipts
        if outcome.wasCancelled, receipts.isEmpty { throw CancellationError() }
        let rejected = outcome.rejections.map { item in
            FailedItem(
                name: "\(item.archive.lastPathComponent): \(item.rejection.path)", reason: item.rejection.reason.message
            )
        }
        let failures = outcome.failures + rejected
        guard !failures.isEmpty || outcome.wasCancelled else { return .success }
        return .partial(succeeded: receipts.count, failures: failures, wasCancelled: outcome.wasCancelled)
    }

    func redo(in context: FileCommandContext) async throws -> FileCommandResult {
        progress = context.progress
        cancellation = context.cancellation
        return try await execute()
    }

    func undo() async throws -> FileUndoResult {
        await TransferUndo.trashCreated(receipts, fileOps: fileOps)
    }
}

/// 移動・コピーの取り消しの共通部分。
@MainActor
private enum TransferUndo {
    /// 操作で**作った**項目をゴミ箱へ送る(圧縮・展開の取り消し)。作ったそのものでなくなった項目には触らない。
    /// 何も送れず、作ったものがまだそのまま残っているなら試し直せる。
    static func trashCreated(_ receipts: [TransferReceipt], fileOps: FileOperationService) async -> FileUndoResult {
        guard !receipts.isEmpty else { return .impossible(reason: nothingToRestore) }
        let (ours, changed) = await FileIO.perform { partitionByIdentity(receipts) }
        let changedFailures = changed.map { FailedItem(url: $0.destination, reason: changedReason(for: $0.destination)) }
        guard !ours.isEmpty else { return .impossible(reason: changedFailures[0].reason) }
        let trashed: TrashOutcome
        do {
            // 展開したものの中にロックされた項目は作らない(書庫のフラグは写さない)が、作った後で利用者がロックしたなら、
            // 自分が作ったものなので尋ねずに外して送る(コピーの取り消しと同じ)。
            trashed = try await fileOps.trash(ours.map(\.destination), unlockingLocked: true)
        } catch {
            return .impossible(reason: error.localizedDescription, canRetry: changed.isEmpty && canRetryTrashing(after: error))
        }
        let failures = changedFailures + trashed.failures
        if failures.isEmpty { return .complete }
        return trashed.receipts.isEmpty
            ? .impossible(reason: failures[0].reason, canRetry: changed.isEmpty)
            : .partial(succeeded: trashed.receipts.count, failures: failures)
    }

    /// ゴミ箱へ送れなかった取り消しを、履歴に残して試し直させてよいか。**ゴミ箱の無い場所(`trashUnavailable`)は何度試しても
    /// 送れない**ので残さない(2026-09-14 の 2 回目の監査 13。以前は「もう一度取り消せます」のまま履歴の一番上に居座り、
    /// その下の操作へ ⌘Z が届かなかった)。黙って完全に削除する代わりにはしない(取り消しが新しいデータ喪失を持ち込まない)。
    nonisolated static func canRetryTrashing(after error: any Error) -> Bool {
        if case .trashUnavailable? = error as? FileOperationError { return false }
        return true
    }

    static var nothingToRestore: String {
        String(localized: "There’s nothing to undo.", language: AppLanguage.currentLocale)
    }

    /// 操作のあとで、同じ場所の項目が別のものに変わっていた・無くなっていた。
    nonisolated static func changedReason(for url: URL) -> String {
        FileOperationService.itemExists(at: url)
            ? String(localized: "The item at this location was replaced after the operation, so it was left as it is.", language: AppLanguage.currentLocale)
            : String(localized: "The item could not be found.", language: AppLanguage.currentLocale)
    }

    /// 受領書を「置いたそのものがまだある」と「変わった・無い」に分ける。ブロッキングするので FileIO の上で呼ぶ。
    nonisolated static func partitionByIdentity(_ receipts: [TransferReceipt]) -> (ours: [TransferReceipt], changed: [TransferReceipt]) {
        var ours: [TransferReceipt] = []
        var changed: [TransferReceipt] = []
        for receipt in receipts {
            if FileIdentity.matches(receipt.destination, receipt.identity) {
                ours.append(receipt)
            } else {
                changed.append(receipt)
            }
        }
        return (ours, changed)
    }

    /// 1 件を戻した結果。
    enum PutBack {
        case restored(URL)
        /// 戻す相手が無かった。
        case missing
        /// 中止ボタンで止めた(項目は運んだ先にそのまま)。
        case cancelled
    }

    /// 受領書ごとに `putBack` で戻す。戻った場所の名前が元と違えば、その項目は「部分的に戻した」。
    /// 置き換えた元の項目がゴミ箱にあれば、戻したあとで空いた場所へ戻す。
    /// 中止されたら残りには手を付けない(何も戻っていなければ履歴に残し、戻った分があれば「部分的に戻した」)。
    static func undo(
        _ receipts: [TransferReceipt],
        fileOps: FileOperationService,
        cancellation: Cancellation = Cancellation(),
        putBack: (TransferReceipt) async throws -> PutBack
    ) async throws -> FileUndoResult {
        guard !receipts.isEmpty else { return .impossible(reason: nothingToRestore) }
        let locale = AppLanguage.currentLocale
        var succeeded = 0
        var moved = 0
        var failures: [FailedItem] = []
        /// 試し直しても戻らない失敗があったか(相手が無い・別の項目に変わった)。
        var hasPermanentFailure = false
        let notProcessed = String(localized: "Not processed.", language: locale)
        // 後に動かしたものから戻す(同じ名前の項目を続けて運んだとき、前のものの場所を先に空けない)。
        let ordered = Array(receipts.reversed())
        receiptLoop: for (index, receipt) in ordered.enumerated() {
            if cancellation.isRequested {
                failures += ordered[index...].map { FailedItem(url: $0.destination, reason: notProcessed) }
                break
            }
            // **運んだそのものだけを戻す**(FileIdentity の型コメント)。確かめるのは戻す直前(前の項目を戻したことで
            // 変わることは無いが、確かめてから動かすまでの間を短くする)。
            let isOurs = await FileIO.perform { FileIdentity.matches(receipt.destination, receipt.identity) }
            guard isOurs else {
                let reason = await FileIO.perform { changedReason(for: receipt.destination) }
                failures.append(FailedItem(url: receipt.destination, reason: reason))
                hasPermanentFailure = true
                continue
            }
            do {
                let restoredAt: URL
                switch try await putBack(receipt) {
                case .restored(let url):
                    restoredAt = url
                case .missing:
                    failures.append(FailedItem(url: receipt.destination, reason: nothingToRestore))
                    hasPermanentFailure = true
                    continue
                case .cancelled:
                    failures += ordered[index...].map { FailedItem(url: $0.destination, reason: notProcessed) }
                    break receiptLoop
                }
                moved += 1
                if restoredAt.lastPathComponent != receipt.source.lastPathComponent {
                    failures.append(FailedItem(
                        url: receipt.source,
                        reason: String(
                            format: String(localized: "An item with the same name was already there, so it was put back as “%@”.", language: locale),
                            restoredAt.lastPathComponent
                        )
                    ))
                } else {
                    succeeded += 1
                }
                if let replaced = receipt.replacedItemInTrash {
                    let restored = await fileOps.restoreFromTrash([
                        TrashReceipt(originalURL: receipt.destination, trashURL: replaced, identity: receipt.replacedItemIdentity)
                    ])
                    failures += restored.failures
                }
            } catch {
                failures.append(FailedItem(url: receipt.destination, reason: error.localizedDescription))
            }
        }
        if failures.isEmpty { return .complete }
        // 1 件も動かせなかったなら「取り消せなかった」。名前を変えて戻せた項目があれば「部分的に戻した」。
        // 動かせなかった理由が全部「動かそうとして断られた」(権限など。項目は運んだ先にそのまま)なら試し直せる。
        return moved == 0
            ? .impossible(reason: failures[0].reason, canRetry: !hasPermanentFailure)
            : .partial(succeeded: succeeded, failures: failures)
    }
}

/// 名前の変更。取り消しは逆向きの名前の変更。
@MainActor
final class RenameFileCommand: FileCommand {
    private let item: URL
    private let newName: String
    /// ロックされた項目もロックを外して変える(利用者が確認で「続ける」と答えた)。
    private let unlockingLocked: Bool
    private let fileOps: FileOperationService
    private(set) var receipt: RenameReceipt?

    init(item: URL, newName: String, unlockingLocked: Bool = false, fileOps: FileOperationService = .shared) {
        self.item = item
        self.newName = newName
        self.unlockingLocked = unlockingLocked
        self.fileOps = fileOps
    }

    var displayName: String {
        String(format: String(localized: "Rename of “%@”", language: AppLanguage.currentLocale), item.lastPathComponent)
    }

    let isUndoable = true

    func execute() async throws -> FileCommandResult {
        receipt = try await fileOps.rename(item, to: newName, unlockingLocked: unlockingLocked)
        return .success
    }

    func undo() async throws -> FileUndoResult {
        guard let receipt else { return .impossible(reason: TransferUndo.nothingToRestore) }
        // 名前を変えたそのものか(FileIdentity の型コメント)。
        let isOurs = await FileIO.perform { FileIdentity.matches(receipt.renamed, receipt.identity) }
        guard isOurs else {
            return .impossible(reason: await FileIO.perform { TransferUndo.changedReason(for: receipt.renamed) })
        }
        do {
            _ = try await fileOps.rename(receipt.renamed, to: receipt.original.lastPathComponent, unlockingLocked: true)
            return .complete
        } catch {
            // 名前は変わっていない。元の名前が埋まっている・権限なら、片付けてから試し直せる。
            return .impossible(reason: error.localizedDescription, canRetry: true)
        }
    }
}

/// 一括リネーム(段階 5)。**全体で 1 回の取り消し**(Finder と同じ)。
///
/// 名前は BulkRename が決めてある。新しい名前は元の名前のどれとも重ならない(BulkRename の型コメント)ので、
/// 上から順に変えるだけで途中の項目を踏み潰さない ―― 計画にあった一時名への 2 パスは要らなかった。
///
/// 1 件が失敗しても残りは続ける(どれも `RENAME_EXCL` で、失敗した項目は元の名前のまま。計画した後に Finder などで
/// 同じ名前の項目が作られた、など)。済んだ分は取り消せ、失敗は報告に並ぶ。中止ボタンは項目の境目で止まる。
@MainActor
final class BulkRenameFileCommand: FileCommand {
    private let renames: [(item: URL, newName: String)]
    private let unlockingLocked: Bool
    private var progress: ProgressSink?
    private var cancellation: Cancellation
    private let fileOps: FileOperationService
    private(set) var receipts: [RenameReceipt] = []

    init(
        renames: [(item: URL, newName: String)], unlockingLocked: Bool = false, progress: ProgressSink? = nil,
        cancellation: Cancellation = Cancellation(), fileOps: FileOperationService = .shared
    ) {
        self.renames = renames
        self.unlockingLocked = unlockingLocked
        self.progress = progress
        self.cancellation = cancellation
        self.fileOps = fileOps
    }

    var displayName: String {
        let locale = AppLanguage.currentLocale
        return renames.count == 1
            ? String(format: String(localized: "Rename of “%@”", language: locale), renames[0].item.lastPathComponent)
            : String(format: String(localized: "Rename of %lld Items", language: locale), renames.count)
    }

    let isUndoable = true

    func execute() async throws -> FileCommandResult {
        receipts = []
        var failures: [FailedItem] = []
        var report = FileOperationProgress(totalItems: renames.count)
        for (index, rename) in renames.enumerated() {
            report.completedItems = index
            report.currentItemName = rename.item.lastPathComponent
            progress?.report(report)
            if cancellation.isRequested {
                let notProcessed = String(localized: "Not processed.", language: AppLanguage.currentLocale)
                failures += renames[index...].map { FailedItem(url: $0.item, reason: notProcessed) }
                return .partial(succeeded: receipts.count, failures: failures, wasCancelled: true)
            }
            do {
                receipts.append(try await fileOps.rename(
                    rename.item, to: rename.newName, unlockingLocked: unlockingLocked, keepsNameExactly: true
                ))
            } catch {
                failures.append(FailedItem(url: rename.item, reason: error.localizedDescription))
            }
        }
        return failures.isEmpty ? .success : .partial(succeeded: receipts.count, failures: failures, wasCancelled: false)
    }

    func redo(in context: FileCommandContext) async throws -> FileCommandResult {
        progress = context.progress
        cancellation = context.cancellation
        return try await execute()
    }

    /// 後に変えたものから元の名前へ戻す。変えたそのものでなくなった項目(FileIdentity の型コメント)には触らない。
    func undo() async throws -> FileUndoResult {
        guard !receipts.isEmpty else { return .impossible(reason: TransferUndo.nothingToRestore) }
        var restored = 0
        var failures: [FailedItem] = []
        var hasPermanentFailure = false
        for receipt in receipts.reversed() {
            let isOurs = await FileIO.perform { FileIdentity.matches(receipt.renamed, receipt.identity) }
            guard isOurs else {
                failures.append(FailedItem(
                    url: receipt.renamed, reason: await FileIO.perform { TransferUndo.changedReason(for: receipt.renamed) }
                ))
                hasPermanentFailure = true
                continue
            }
            do {
                _ = try await fileOps.rename(
                    receipt.renamed, to: receipt.original.lastPathComponent, unlockingLocked: true, keepsNameExactly: true
                )
                restored += 1
            } catch {
                failures.append(FailedItem(url: receipt.renamed, reason: error.localizedDescription))
            }
        }
        if failures.isEmpty { return .complete }
        return restored == 0
            ? .impossible(reason: failures[0].reason, canRetry: !hasPermanentFailure)
            : .partial(succeeded: restored, failures: failures)
    }
}

/// ゴミ箱へ送る。取り消しはゴミ箱から戻す(元の場所に何かできていたら上書きせず、戻せなかったと見せる)。
@MainActor
final class TrashFilesCommand: FileCommand {
    private let items: [URL]
    /// ロックされた項目もロックを外して送る(利用者が確認で「続ける」と答えた)。
    private let unlockingLocked: Bool
    private let fileOps: FileOperationService
    private(set) var outcome = TrashOutcome()

    init(items: [URL], unlockingLocked: Bool = false, fileOps: FileOperationService = .shared) {
        self.items = items
        self.unlockingLocked = unlockingLocked
        self.fileOps = fileOps
    }

    var displayName: String {
        let locale = AppLanguage.currentLocale
        return items.count == 1
            ? String(format: String(localized: "Move of “%@” to the Trash", language: locale), items[0].lastPathComponent)
            : String(format: String(localized: "Move of %lld Items to the Trash", language: locale), items.count)
    }

    let isUndoable = true
    let completionSound: SystemSoundEffect? = .moveToTrash

    func execute() async throws -> FileCommandResult {
        outcome = try await fileOps.trash(items, unlockingLocked: unlockingLocked)
        let restorable = outcome.receipts.filter { $0.trashURL != nil }.count
        guard !outcome.failures.isEmpty || restorable != items.count else { return .success }
        return .partial(succeeded: restorable, failures: outcome.failures, wasCancelled: false)
    }

    func undo() async throws -> FileUndoResult {
        guard !outcome.receipts.isEmpty else { return .impossible(reason: TransferUndo.nothingToRestore) }
        let restored = await fileOps.restoreFromTrash(outcome.receipts)
        if restored.failures.isEmpty { return .complete }
        guard restored.restored.isEmpty else {
            return .partial(succeeded: restored.restored.count, failures: restored.failures)
        }
        // 1 件も戻らなかった。どれもゴミ箱の中に残り、元のフォルダもあるなら、元の場所を埋めている項目を
        // どければ試し直せる(ゴミ箱が空にされた・元のフォルダが消えたなら直らない)。
        let receipts = outcome.receipts
        let canRetry = await FileIO.perform {
            receipts.allSatisfy { receipt in
                guard let trashURL = receipt.trashURL else { return false }
                return FileOperationService.itemExists(at: trashURL)
                    && FileOperationService.itemExists(at: receipt.originalURL.deletingLastPathComponent())
            }
        }
        return .impossible(reason: restored.failures[0].reason, canRetry: canRetry)
    }
}

/// ゴミ箱の無い場所での完全削除。**取り消せない**(積まれない)。実行前の確認は呼び出し側の仕事。
@MainActor
final class DeleteFilesImmediatelyCommand: FileCommand {
    private let items: [URL]
    /// ロックされた項目もロックを外して消す(利用者が確認で「続ける」と答えた)。
    private let unlockingLocked: Bool
    private let fileOps: FileOperationService
    private(set) var outcome = DeletionOutcome()

    init(items: [URL], unlockingLocked: Bool = false, fileOps: FileOperationService = .shared) {
        self.items = items
        self.unlockingLocked = unlockingLocked
        self.fileOps = fileOps
    }

    var displayName: String {
        let locale = AppLanguage.currentLocale
        return items.count == 1
            ? String(format: String(localized: "Deletion of “%@”", language: locale), items[0].lastPathComponent)
            : String(format: String(localized: "Deletion of %lld Items", language: locale), items.count)
    }

    let isUndoable = false
    let completionSound: SystemSoundEffect? = .permanentDelete

    func execute() async throws -> FileCommandResult {
        outcome = await fileOps.deletePermanently(items, unlockingLocked: unlockingLocked)
        return outcome.failures.isEmpty
            ? .success
            : .partial(succeeded: outcome.deleted.count, failures: outcome.failures, wasCancelled: false)
    }

    func undo() async throws -> FileUndoResult {
        .impossible(reason: String(localized: "Items deleted immediately can’t be restored.", language: AppLanguage.currentLocale))
    }
}

/// 新規フォルダ。取り消しは**空のときだけ**ゴミ箱へ(中に何か入れたあとで ⌘Z しても、入れたものを巻き込まない)。
@MainActor
final class CreateFolderCommand: FileCommand {
    let url: URL
    private let fileOps: FileOperationService
    /// 作った直後のフォルダの実体(FileIdentity の型コメント)。
    private var identity: FileIdentity?

    init(url: URL, fileOps: FileOperationService = .shared) {
        self.url = url
        self.fileOps = fileOps
    }

    var displayName: String {
        String(localized: "New Folder", language: AppLanguage.currentLocale)
    }

    let isUndoable = true

    func execute() async throws -> FileCommandResult {
        try await fileOps.createDirectory(at: url)
        let target = url
        identity = await FileIO.perform { FileIdentity.of(target) }
        return .success
    }

    func undo() async throws -> FileUndoResult {
        let target = url
        let identity = identity
        // 作ったそのフォルダか(同じ名前の別のフォルダを、空だからといってゴミ箱へ送らない)。
        let isOurs = await FileIO.perform { FileIdentity.matches(target, identity) }
        guard isOurs else {
            return .impossible(reason: await FileIO.perform { TransferUndo.changedReason(for: target) })
        }
        // **メインアクターで一覧を読まない**(応答しない共有で ⌘Z がメインスレッドを止める)。
        // 読めなければ空とみなさない(2026-09-14 の 2 回目の監査。以前は読めないフォルダを空として、中身ごとゴミ箱へ送りえた)。
        let listing: Result<Bool, any Error> = await FileIO.perform {
            Result { try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty }
        }
        let isEmpty: Bool
        switch listing {
        case .success(let empty): isEmpty = empty
        case .failure(let error): return .impossible(reason: error.localizedDescription, canRetry: true)
        }
        guard isEmpty else {
            return .impossible(reason: String(
                localized: "The folder isn’t empty, so it was left in place.", language: AppLanguage.currentLocale
            ))
        }
        do {
            _ = try await fileOps.trash([url])
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription, canRetry: TransferUndo.canRetryTrashing(after: error))
        }
    }
}
