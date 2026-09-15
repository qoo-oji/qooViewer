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

    /// 取り消しを途中で止めて、まだ戻していない項目(元の場所の URL)。止めていなければ nil。
    private var remainingToUndo: [URL]?

    /// **取り消しを途中で止めた後は、残りの件数で名乗る**(2026-09-15 の実機検証。以前は「4000 項目の移動を取り消す」のままで、
    /// 1347 件しか残っていないのに全部を戻すように読めた)。やり直しは全部を運び直すので、全部を戻し終えたら元の名前へ戻る。
    var displayName: String {
        let locale = AppLanguage.currentLocale
        let named = remainingToUndo ?? items
        return named.count == 1
            ? String(format: String(localized: "Move of “%@”", language: locale), named[0].lastPathComponent)
            : String(format: String(localized: "Move of %lld Items", language: locale), named.count)
    }

    /// ペースト・D&D の完了音(Finder もペーストで鳴らす)。
    let completionSound: SystemSoundEffect? = .operationComplete

    func execute() async throws -> FileCommandResult {
        remainingToUndo = nil
        outcome = try await fileOps.move(items, to: destination, options: options)
        return .from(outcome)
    }

    func redo(in context: FileCommandContext) async throws -> FileCommandResult {
        remainingToUndo = nil
        outcome = try await fileOps.move(items, to: destination, options: context.applied(to: options))
        return .from(outcome)
    }

    func undo() async throws -> FileUndoResult {
        try await undo(in: FileCommandContext())
    }

    func undo(in context: FileCommandContext) async throws -> FileUndoResult {
        let receipts = outcome.receipts
        let identities = Dictionary(
            receipts.compactMap { receipt in receipt.identity.map { (receipt.destination, $0) } }, uniquingKeysWith: { first, _ in first }
        )
        let undone = try await TransferUndo.undo(
            receipts, fileOps: fileOps, cancellation: context.cancellation, progress: context.progress
        ) { items, folder, progress in
            // 自分が運んだものなので、ロックされていても尋ねずに外して戻す(戻した先で掛け直す)。
            // 戻せたかは受領書で見る(エンジンは最後の項目を運び終えた直後に中止が立っても `wasCancelled` を立てる。3 回目の監査)。
            // 運ぶ直前にも実体を見させる(まとめて運ぶので、始める前の確認から時間が経つ。4 回目の監査)。
            try await self.fileOps.move(
                items, to: folder,
                options: FileOperationOptions(
                    conflictPolicy: .keepBoth, progress: progress, cancellation: context.cancellation, unlockingLocked: true,
                    expectedIdentities: identities
                )
            )
        }
        // 途中で止めたなら、片付いた受領書を外して残りだけを持つ(もう一度 ⌘Z で続きを戻す)。
        if case .stopped = undone.result {
            outcome.receipts = receipts.enumerated().filter { !undone.resolvedIndices.contains($0.offset) }.map(\.element)
            remainingToUndo = outcome.receipts.map(\.source)
        } else if case .impossible = undone.result {
            // 何も戻っていない(残りはそのまま)。名乗りも変えない。
        } else {
            remainingToUndo = nil
        }
        return undone.result
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

/// 移動・コピーの取り消しの共通部分。`undo` のまとめ運びを直接確かめられるよう internal(テスト)。
@MainActor
enum TransferUndo {
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

    /// `undo` の結果と、片付いた(戻した・試し直しても戻らない)受領書の添字(`receipts` の中の位置)。
    struct Undone {
        var result: FileUndoResult
        var resolvedIndices: Set<Int> = []
    }

    /// 受領書を元の場所へ戻す。戻った場所の名前が元と違えば、その項目は「部分的に戻した」。
    /// 置き換えた元の項目がゴミ箱にあれば、戻したあとで空いた場所へ戻す。
    /// 中止されたら残りには手を付けず `.stopped`(呼び出し側は `resolvedIndices` を外して、残りをもう一度取り消せるようにする)。
    ///
    /// **元のフォルダごとにまとめて 1 回で運ぶ**(`putBack` に項目の列と戻す先を渡す。2026-09-15 の 3 回目の監査の実機検証)。以前は受領書 1 件ごとに
    /// 移動を呼んでいたので、4000 件の別ボリュームの移動の取り消しが、移動の 24 秒に対して 89 秒掛かり(1 件ごとに事前検査とボリュームの判定をやり直す)、
    /// 帯の進み具合も「全 1 件の何バイト」を 1 件ごとに 0 から出し直して、全体のどこまで戻ったかが見えなかった。
    /// エンジンは最初の失敗で止まる(残りは `unprocessed`)ので、失敗した項目を外して残りを続けて運ぶ。まとめた呼び出しが 1 件も動かずに投げたときは、
    /// どの項目の失敗か分からないので、そのまとまりを半分ずつに割って確かめる。
    static func undo(
        _ receipts: [TransferReceipt],
        fileOps: FileOperationService,
        cancellation: Cancellation = Cancellation(),
        progress: ProgressSink? = nil,
        putBack: ([URL], URL, ProgressSink?) async throws -> TransferOutcome
    ) async throws -> Undone {
        guard !receipts.isEmpty else { return Undone(result: .impossible(reason: nothingToRestore)) }
        let locale = AppLanguage.currentLocale
        var succeeded = 0
        var moved = 0
        var failures: [FailedItem] = []
        /// 試し直しても戻らない失敗があったか(相手が無い・別の項目に変わった)。
        var hasPermanentFailure = false
        var resolved: Set<Int> = []

        // **運んだそのものだけを戻す**(FileIdentity の型コメント)。
        let identities = await FileIO.perform { receipts.map { FileIdentity.matches($0.destination, $0.identity) } }
        var ours: [Int] = []
        // 後に動かしたものから戻す(同じ名前の項目を続けて運んだとき、前のものの場所を先に空けない)。
        for index in receipts.indices.reversed() {
            if identities[index] {
                ours.append(index)
            } else {
                let destination = receipts[index].destination
                let reason = await FileIO.perform { changedReason(for: destination) }
                failures.append(FailedItem(url: destination, reason: reason))
                hasPermanentFailure = true
                resolved.insert(index)
            }
        }
        // 戻す先(元のフォルダ)ごとの組。組の並びは、その組の最後に運んだ項目の順。
        // 組は辞書で引く(2026-09-15 の 4 回目の監査。以前は組の列を線形に探したので、多くのフォルダから集めた数万件の移動の取り消しが
        // メインアクターの上で項目数 × 組の数の比較になった)。
        var groups: [(folder: URL, indices: [Int])] = []
        var groupPositions: [URL: Int] = [:]
        for index in ours {
            let folder = receipts[index].source.deletingLastPathComponent()
            if let position = groupPositions[folder] {
                groups[position].indices.append(index)
            } else {
                groupPositions[folder] = groups.count
                groups.append((folder, [index]))
            }
        }

        /// 1 件戻せた後始末。
        func didRestore(_ index: Int, at restoredAt: URL, problem: String?) async {
            let receipt = receipts[index]
            moved += 1
            resolved.insert(index)
            if restoredAt.lastPathComponent != receipt.source.lastPathComponent {
                failures.append(FailedItem(
                    url: receipt.source,
                    reason: String(
                        format: String(localized: "An item with the same name was already there, so it was put back as “%@”.", language: locale),
                        restoredAt.lastPathComponent
                    )
                ))
            } else if problem == nil {
                succeeded += 1
            }
            if let problem { failures.append(FailedItem(url: receipt.destination, reason: problem)) }
            if let replaced = receipt.replacedItemInTrash {
                let restored = await fileOps.restoreFromTrash([
                    TrashReceipt(originalURL: receipt.destination, trashURL: replaced, identity: receipt.replacedItemIdentity)
                ])
                failures += restored.failures
            }
        }

        // 組が複数あると、エンジンの進み具合は組ごとに数え直すので、件数だけを全体へ足し直して見せる(容量は総量が分からないので出さない)。
        let totalItems = ours.count
        var itemsBefore = 0
        let aggregated: (Int) -> ProgressSink? = { base in
            guard let progress else { return nil }
            guard groups.count > 1 else { return progress }
            return ProgressSink { value in
                var combined = value
                combined.completedItems = base + value.completedItems
                combined.totalItems = totalItems
                combined.completedBytes = 0
                combined.totalBytes = 0
                progress.report(combined)
            }
        }

        var stopped = false
        groupLoop: for group in groups {
            /// これから運ぶまとまりの列(先頭から順に)。
            var batches: [[Int]] = [group.indices]
            /// この組でまだ片付いていない件数(進み具合の足し込みに使う)。
            var pendingCount = group.indices.count
            while !batches.isEmpty {
                let batch = batches.removeFirst()
                if cancellation.isRequested {
                    stopped = true
                    break groupLoop
                }
                let urls = batch.map { receipts[$0].destination }
                let outcome: TransferOutcome
                do {
                    outcome = try await putBack(urls, group.folder, aggregated(itemsBefore + group.indices.count - pendingCount))
                } catch {
                    // 運ぶ前の中止(事前検査の中など)はエンジンが投げる。失敗ではなく中止として止める。
                    if FileCommandStack.isCancellation(error) {
                        stopped = true
                        break groupLoop
                    }
                    // エンジンは 1 件も動かせなかったときだけ投げる(事前検査で断った・先頭で失敗した)。どの項目のせいか分からないので、
                    // **半分ずつに割って確かめる**(2026-09-15 の 4 回目の監査)。以前は先頭 1 件だけを試してから残り全体で呼び直したので、
                    // 空き容量の不足のように「まとまり全体」で決まる断りでは、1 件進むごとに残り全部の木を事前検査で歩き直し、項目数の 2 乗になった。
                    // 割れば、断られたまとまりの大きさの合計は項目数 × 割る段数で済む。
                    if batch.count > 1 {
                        let half = batch.count / 2
                        batches.insert(contentsOf: [Array(batch[..<half]), Array(batch[half...])], at: 0)
                        continue
                    }
                    failures.append(FailedItem(url: urls[0], reason: error.localizedDescription))
                    pendingCount -= 1
                    continue
                }
                let placed = Dictionary(outcome.receipts.map { ($0.source, $0.destination) }, uniquingKeysWith: { first, _ in first })
                let problems = Dictionary(outcome.failures.compactMap { item in item.url.map { ($0, item.reason) } }, uniquingKeysWith: { first, _ in first })
                let unprocessed = Set(outcome.unprocessed)
                var next: [Int] = []
                for index in batch {
                    let url = receipts[index].destination
                    if let restoredAt = placed[url] {
                        await didRestore(index, at: restoredAt, problem: problems[url])
                    } else if let reason = problems[url] {
                        failures.append(FailedItem(url: url, reason: reason))
                    } else if unprocessed.contains(url) {
                        next.append(index)
                    } else {
                        // 運ぶ先に自分がいた(スキップ)・消えていた。
                        failures.append(FailedItem(url: url, reason: nothingToRestore))
                        hasPermanentFailure = true
                        resolved.insert(index)
                    }
                }
                // 中止で残した項目があれば止める(最後の項目を運び終えた直後の中止は、残りが無いので止めない)。
                if outcome.wasCancelled, !next.isEmpty {
                    stopped = true
                    break groupLoop
                }
                // 1 件も片付かなかったのに中止でもない(エンジンの約束では起きない)なら、割って確かめて必ず進める。
                if next.count == batch.count {
                    if batch.count > 1 {
                        let half = batch.count / 2
                        batches.insert(contentsOf: [Array(batch[..<half]), Array(batch[half...])], at: 0)
                    } else {
                        failures.append(FailedItem(url: urls[0], reason: nothingToRestore))
                        pendingCount -= 1
                    }
                    continue
                }
                pendingCount -= batch.count - next.count
                // 途中の失敗で手を付けなかった残りは、まとめたまま次に運ぶ。
                if !next.isEmpty { batches.insert(next, at: 0) }
            }
            itemsBefore += group.indices.count
        }
        if stopped { return Undone(result: .stopped(succeeded: succeeded, failures: failures), resolvedIndices: resolved) }
        if failures.isEmpty { return Undone(result: .complete, resolvedIndices: resolved) }
        // 1 件も動かせなかったなら「取り消せなかった」。名前を変えて戻せた項目があれば「部分的に戻した」。
        // 動かせなかった理由が全部「動かそうとして断られた」(権限など。項目は運んだ先にそのまま)なら試し直せる。
        return Undone(
            result: moved == 0
                ? .impossible(reason: failures[0].reason, canRetry: !hasPermanentFailure)
                : .partial(succeeded: succeeded, failures: failures),
            resolvedIndices: resolved
        )
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
