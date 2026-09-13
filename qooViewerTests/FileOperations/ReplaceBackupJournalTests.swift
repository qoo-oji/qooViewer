import Foundation
import Testing

@testable import qooViewer

/// 「置き換える」の退避の記録と起動時の復旧(Services/FileOperations/ReplaceBackupJournal.swift)。
///
/// 記録は**テストごとの一時フォルダ**に置く(本物の記録にも、ほかのテストの記録にも触れない)。
struct ReplaceBackupJournalTests {
    private let temporary: TemporaryDirectory
    private let journal: ReplaceBackupJournal

    init() throws {
        temporary = try TemporaryDirectory("replace-journal")
        journal = ReplaceBackupJournal(storageURL: temporary.file("journal/replace-backups.json"))
    }

    /// 置き換えの途中で落ちた状態そのもの: 元の項目は `.qooViewer-replace-<UUID>/<名前>` にあり、元の場所には何も無い。
    private func makeInterruptedReplace(named name: String = "a.txt", contents: String = "healthy") throws -> (backup: URL, target: URL) {
        let folder = try temporary.directory("folder-\(UUID().uuidString)")
        let holder = folder.appendingPathComponent("\(FileOperationService.replaceHolderPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: false)
        let backup = holder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: backup)
        return (backup, folder.appendingPathComponent(name))
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test("退避したまま落ちた項目を、次の起動で元の場所へ戻し、隠しフォルダも片付ける")
    func putsBackAnItemLeftBehind() throws {
        let (backup, target) = try makeInterruptedReplace()
        journal.record(backup: backup, target: target)

        #expect(journal.recoverAll() == [.restored(target: target)])
        #expect(try read(target) == "healthy")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["a.txt"])
        #expect(journal.pendingBackupCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: journal.storageURL.path), "空になった記録のファイルが残っている")
    }

    @Test("元の場所に何かあれば上書きせず、退避も記録も残す。邪魔が無くなれば次で戻る")
    func neverOverwritesAndRetriesLater() throws {
        let (backup, target) = try makeInterruptedReplace(contents: "old")
        try Data("new".utf8).write(to: target)
        journal.record(backup: backup, target: target)

        let first = journal.recoverAll()
        guard case .orphaned(let reportedBackup, let reportedTarget, _)? = first.first else {
            Issue.record("上書きを避けたことが報告されていない: \(first)")
            return
        }
        #expect(reportedBackup == backup)
        #expect(reportedTarget == target)
        #expect(try read(target) == "new")
        #expect(try read(backup) == "old")
        #expect(journal.pendingBackupCount() == 1)

        try FileManager.default.removeItem(at: target)
        #expect(journal.recoverAll() == [.restored(target: target)])
        #expect(try read(target) == "old")
    }

    @Test("退避が既に無ければ記録だけを捨て、空の隠しフォルダを片付ける")
    func dropsRecordsWhoseBackupIsGone() throws {
        let (backup, target) = try makeInterruptedReplace()
        try FileManager.default.removeItem(at: backup)
        journal.record(backup: backup, target: target)

        #expect(journal.recoverAll() == [.alreadyClean])
        #expect(journal.recoverAll().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).isEmpty)
    }

    @Test("記録して消すと、記録のファイルは残らない")
    func forgettingLeavesNothingBehind() throws {
        let backup = temporary.file("x/\(FileOperationService.replaceHolderPrefix)1/a.txt")
        journal.record(backup: backup, target: temporary.file("x/a.txt"))
        #expect(FileManager.default.fileExists(atPath: journal.storageURL.path))
        journal.record(backup: backup, target: temporary.file("x/a.txt"))
        #expect(journal.pendingBackupCount() == 1, "同じ退避を 2 回記録しても 1 件")
        journal.forget(backup: backup)
        #expect(!FileManager.default.fileExists(atPath: journal.storageURL.path))
        #expect(journal.recoverAll().isEmpty)
    }

    @Test("記録が壊れていても落ちず、壊れたファイルは消さずに退避する")
    func corruptRecordIsPreserved() throws {
        let folder = journal.storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: journal.storageURL)

        #expect(journal.recoverAll().isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(siblings.contains { $0.hasPrefix("replace-backups.json.corrupt-") })
    }

    // MARK: - エンジンとの接続

    @Test("置き換えのコピーの最中は退避が記録されていて、終われば消える")
    func theBackupIsRecordedWhileTheCopyIsInFlight() async throws {
        let trash = try temporary.directory("PseudoTrash")
        // クローンを禁じて実コピーにする(クローンでは進捗の報告が来ず、最中を覗けない)。
        let service = FileOperationService(environment: .pseudoTrash(at: trash, replaceJournal: journal), allowsCloning: false)
        let source = temporary.file("inflight/src/big.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 32 * 1024 * 1024).write(to: source)
        let destination = try temporary.directory("inflight/dst")
        try Data("old".utf8).write(to: destination.appendingPathComponent("big.bin"))

        let journal = journal
        let counts = PendingCounts()
        let options = FileOperationOptions(
            conflictPolicy: .replace,
            progress: ProgressSink { if $0.completedBytes > 0 { counts.append(journal.pendingBackupCount()) } }
        )
        let outcome = try await service.copy([source], to: destination, options: options)

        #expect(outcome.isCompleteSuccess)
        #expect(counts.values.contains { $0 > 0 }, "書いている最中に記録が無い(退避より後に記録している)")
        #expect(journal.pendingBackupCount() == 0, "成功した置き換えが記録を残している")
    }

    @Test("置き換えを中止して元へ戻したら、記録も消える")
    func cancellingAReplaceForgetsTheRecord() async throws {
        let trash = try temporary.directory("PseudoTrash")
        let service = FileOperationService(environment: .pseudoTrash(at: trash, replaceJournal: journal), allowsCloning: false)
        let source = temporary.file("cancel/src/big.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 32 * 1024 * 1024).write(to: source)
        let destination = try temporary.directory("cancel/dst")
        try Data("old".utf8).write(to: destination.appendingPathComponent("big.bin"))
        let cancellation = Cancellation()
        let options = FileOperationOptions(
            conflictPolicy: .replace,
            progress: ProgressSink { if $0.completedBytes > 0 { cancellation.request() } },
            cancellation: cancellation
        )
        let outcome = try await service.copy([source], to: destination, options: options)
        #expect(outcome.wasCancelled)
        #expect(try read(destination.appendingPathComponent("big.bin")) == "old")
        #expect(journal.pendingBackupCount() == 0)
    }

    @Test("ロックされた項目は置き換えず「ロックされています」と伝え、記録も残さない")
    func replacingALockedItemIsRefused() async throws {
        let trash = try temporary.directory("PseudoTrash")
        let service = FileOperationService(environment: .pseudoTrash(at: trash, replaceJournal: journal))
        let source = temporary.file("locked/src/a.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source)
        let destination = try temporary.directory("locked/dst")
        let target = destination.appendingPathComponent("a.txt")
        try Data("old".utf8).write(to: target)
        #expect(FileOperationService.setLocked(target, true))
        defer { FileOperationService.setLocked(target, false) }

        await #expect(throws: FileOperationError.itemLocked(target)) {
            _ = try await service.copy([source], to: destination, options: .init(conflictPolicy: .replace))
        }
        #expect(try read(target) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["a.txt"])
        #expect(journal.pendingBackupCount() == 0)
    }

    // MARK: - 知らせる内容

    @Test("戻せたものは知らせ、戻せなかったものは警告にする。片付いていただけなら何も出さない")
    func noticesForOutcomes() {
        let target = URL(fileURLWithPath: "/NoSuchVolume/folder/a.txt")
        let backup = URL(fileURLWithPath: "/NoSuchVolume/folder/.qooViewer-replace-1/b.txt")
        #expect(ReplaceBackupRecovery.notices(for: [.alreadyClean]).isEmpty)
        let notices = ReplaceBackupRecovery.notices(for: [
            .restored(target: target), .orphaned(backup: backup, target: target, reason: "reason"), .alreadyClean,
        ])
        #expect(notices.map(\.isWarning) == [false, true])
        #expect(notices[0].message.contains(target.path))
        #expect(notices[1].message.contains(backup.path))
    }
}

nonisolated final class PendingCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
