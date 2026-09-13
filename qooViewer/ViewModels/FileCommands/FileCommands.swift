import Foundation

// ファイルブラウザの個々の操作(改善要望7 段階 2、2026-09-13。qooLibrary の FileCommands.swift を写したもの)。
// どの操作も、取り消しは**実行時に受け取った受領書だけ**を頼りに組み立てる(実行後に画面や名前から推測しない)。
//
// 一括リネーム(段階 5)と圧縮・展開(段階 6)のコマンドはそれぞれの段階で足す。

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

    init(items: [URL], destination: URL, options: FileOperationOptions, fileOps: FileOperationService = .shared) {
        self.items = items
        self.destination = destination
        self.options = options
        self.fileOps = fileOps
    }

    var displayName: String {
        let locale = AppLanguage.currentLocale
        return items.count == 1
            ? String(format: String(localized: "Move of “%@”", language: locale), items[0].lastPathComponent)
            : String(format: String(localized: "Move of %lld Items", language: locale), items.count)
    }

    let isUndoable = true
    /// ペースト・D&D の完了音(Finder もペーストで鳴らす)。
    let completionSound: SystemSoundEffect? = .operationComplete

    func execute() async throws -> FileCommandResult {
        outcome = try await fileOps.move(items, to: destination, options: options)
        return .from(outcome)
    }

    func undo() async throws -> FileUndoResult {
        try await TransferUndo.undo(outcome.receipts, fileOps: fileOps) { receipt in
            try await self.fileOps.move(
                [receipt.destination], to: receipt.source.deletingLastPathComponent(),
                options: FileOperationOptions(conflictPolicy: .keepBoth)
            ).receipts.first?.destination
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

    func undo() async throws -> FileUndoResult {
        guard !outcome.receipts.isEmpty else { return .impossible(reason: TransferUndo.nothingToRestore) }
        // コピーの取り消しは受領書をまとめて 1 回でゴミ箱へ(ゴミ箱の無い場所では取り消せない ――
        // 黙って完全削除しない)。ロックされた元をコピーするとロックも写るので、**自分が作ったものに限って**
        // 尋ねずにロックを外して送る(ゴミ箱の中でロックは掛け直される)。
        let trashed: TrashOutcome
        do {
            trashed = try await fileOps.trash(outcome.receipts.map(\.destination), unlockingLocked: true)
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
        var failures = trashed.failures
        // 「置き換える」で退避した元の項目があれば、空いた場所へ戻す。
        let replaced = outcome.receipts.compactMap { receipt in
            receipt.replacedItemInTrash.map { TrashReceipt(originalURL: receipt.destination, trashURL: $0) }
        }
        failures += await fileOps.restoreFromTrash(replaced).failures
        return failures.isEmpty
            ? .complete
            : .partial(succeeded: trashed.receipts.count, failures: failures)
    }
}

/// 移動・コピーの取り消しの共通部分。
@MainActor
private enum TransferUndo {
    static var nothingToRestore: String {
        String(localized: "There’s nothing to undo.", language: AppLanguage.currentLocale)
    }

    /// 受領書ごとに `putBack` で戻す。戻った場所の名前が元と違えば、その項目は「部分的に戻した」。
    /// 置き換えた元の項目がゴミ箱にあれば、戻したあとで空いた場所へ戻す。
    static func undo(
        _ receipts: [TransferReceipt],
        fileOps: FileOperationService,
        putBack: (TransferReceipt) async throws -> URL?
    ) async throws -> FileUndoResult {
        guard !receipts.isEmpty else { return .impossible(reason: nothingToRestore) }
        let locale = AppLanguage.currentLocale
        var succeeded = 0
        var moved = 0
        var failures: [FailedItem] = []
        // 後に動かしたものから戻す(同じ名前の項目を続けて運んだとき、前のものの場所を先に空けない)。
        for receipt in receipts.reversed() {
            do {
                guard let restoredAt = try await putBack(receipt) else {
                    failures.append(FailedItem(url: receipt.destination, reason: nothingToRestore))
                    continue
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
                    let restored = await fileOps.restoreFromTrash([TrashReceipt(originalURL: receipt.destination, trashURL: replaced)])
                    failures += restored.failures
                }
            } catch {
                failures.append(FailedItem(url: receipt.destination, reason: error.localizedDescription))
            }
        }
        if failures.isEmpty { return .complete }
        // 1 件も動かせなかったなら「取り消せなかった」。名前を変えて戻せた項目があれば「部分的に戻した」。
        return moved == 0
            ? .impossible(reason: failures[0].reason)
            : .partial(succeeded: succeeded, failures: failures)
    }
}

/// 名前の変更。取り消しは逆向きの名前の変更。
@MainActor
final class RenameFileCommand: FileCommand {
    private let item: URL
    private let newName: String
    private let fileOps: FileOperationService
    private(set) var receipt: RenameReceipt?

    init(item: URL, newName: String, fileOps: FileOperationService = .shared) {
        self.item = item
        self.newName = newName
        self.fileOps = fileOps
    }

    var displayName: String {
        String(format: String(localized: "Rename of “%@”", language: AppLanguage.currentLocale), item.lastPathComponent)
    }

    let isUndoable = true

    func execute() async throws -> FileCommandResult {
        receipt = try await fileOps.rename(item, to: newName)
        return .success
    }

    func undo() async throws -> FileUndoResult {
        guard let receipt else { return .impossible(reason: TransferUndo.nothingToRestore) }
        do {
            _ = try await fileOps.rename(receipt.renamed, to: receipt.original.lastPathComponent)
            return .complete
        } catch {
            return .impossible(reason: error.localizedDescription)
        }
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
        return restored.restored.isEmpty
            ? .impossible(reason: restored.failures[0].reason)
            : .partial(succeeded: restored.restored.count, failures: restored.failures)
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
        return .success
    }

    func undo() async throws -> FileUndoResult {
        let target = url
        // **メインアクターで一覧を読まない**(応答しない共有で ⌘Z がメインスレッドを止める)。
        let isEmpty = await FileIO.perform {
            ((try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []).isEmpty
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
            return .impossible(reason: error.localizedDescription)
        }
    }
}
