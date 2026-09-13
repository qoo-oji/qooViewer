import Foundation
import Testing

@testable import qooViewer

/// ファイル操作エンジン(Services/FileOperations/FileOperationService.swift)のうち、起動ボリュームの一時フォルダで
/// 確かめられること。別ボリュームが要るものは FileOperationVolumeTests。
///
/// ゴミ箱は本物に触れない(`FileOperationEnvironment.pseudoTrash`)。
struct FileOperationServiceTests {
    private let temporary: TemporaryDirectory
    private let trash: URL
    private let service: FileOperationService

    init() throws {
        temporary = try TemporaryDirectory("file-ops")
        trash = try temporary.directory("PseudoTrash")
        service = FileOperationService(environment: .pseudoTrash(at: trash))
    }

    private func write(_ text: String, to relativePath: String) throws -> URL {
        let url = temporary.file(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    // MARK: - 新規フォルダ・名前の変更

    @Test("新規フォルダは既にあれば失敗する(黙って何も起きないにしない)")
    func createDirectoryRefusesAnExistingName() async throws {
        let url = temporary.file("New")
        try await service.createDirectory(at: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: FileOperationError.alreadyExists(url)) { try await service.createDirectory(at: url) }
    }

    @Test("/ を含む名前で入れ子のフォルダを作らない")
    func createDirectoryRefusesASlash() async throws {
        let root = try temporary.directory("slash-root")
        await #expect(throws: FileOperationError.self) {
            try await service.createDirectory(at: root.appendingPathComponent("a/b"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("/ を含む名前への変更は、別フォルダへの移動にならず断られる")
    func renameRefusesASlash() async throws {
        let file = try write("x", to: "rename-slash/orig.txt")
        let sub = try temporary.directory("rename-slash/sub")
        await #expect(throws: FileOperationError.self) { _ = try await service.rename(file, to: "sub/new.txt") }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sub.path).isEmpty)
    }

    @Test("大文字小文字だけの名前の変更ができる(自分自身を衝突とみなさない)")
    func caseOnlyRenameSucceeds() async throws {
        let file = try write("x", to: "case/comic.cbz")
        let receipt = try await service.rename(file, to: "Comic.cbz")
        #expect(receipt.renamed.lastPathComponent == "Comic.cbz")
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["Comic.cbz"])
    }

    @Test("別の項目がある名前へは変更しない(上書きしない)")
    func renameRefusesToOverwrite() async throws {
        let a = try write("a", to: "rename-collide/a.txt")
        let b = try write("b", to: "rename-collide/b.txt")
        await #expect(throws: FileOperationError.alreadyExists(b)) { _ = try await service.rename(a, to: "b.txt") }
        #expect(try read(b) == "b")
        #expect(try read(a) == "a")
    }

    // MARK: - 移動・コピー

    @Test("同じボリュームの移動はバイトを運ばない(iノードが変わらない)")
    func sameVolumeMoveKeepsTheInode() async throws {
        let file = try write("payload", to: "move-src/book.cbz")
        let destination = try temporary.directory("move-dst")
        let before = inode(file)
        let outcome = try await service.move([file], to: destination, options: .init(conflictPolicy: .ask))
        let moved = destination.appendingPathComponent("book.cbz")
        #expect(outcome.isCompleteSuccess)
        #expect(outcome.receipts == [TransferReceipt(source: file, destination: moved, replacedItemInTrash: nil)])
        #expect(inode(moved) == before)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("同じ APFS ボリュームのコピーはクローンで、1 バイトも書かない")
    func sameVolumeCopyClones() throws {
        let source = temporary.file("clone-src.bin")
        try Data(count: 4 * 1024 * 1024).write(to: source)
        let destination = temporary.file("clone-dst.bin")
        var reported: Int64 = 0
        let outcome = try FileCopyEngine.copy(from: source, to: destination) { reported += $0 }
        #expect(outcome == .completed(bytes: 0))
        #expect(reported == 0)
        #expect(FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path))
    }

    @Test("コピーは既にある宛先を上書きしない(COPYFILE_EXCL を自分で付けている)")
    func copyEngineRefusesToOverwrite() throws {
        let source = try write("new", to: "excl/src.txt")
        let destination = try write("healthy", to: "excl/dst.txt")
        #expect(throws: FileOperationError.self) {
            _ = try FileCopyEngine.copy(from: source, to: destination, allowsCloning: false) { _ in }
        }
        #expect(try read(destination) == "healthy")
    }

    @Test("縮退経路(lstat + rename)も既にある宛先を上書きしない")
    func degradedRenameRefusesToOverwrite() throws {
        let source = try write("new", to: "degraded/src.txt")
        let destination = try write("healthy", to: "degraded/dst.txt")
        #expect(FileOperationService.renameCheckingDestinationFirst(from: source, to: destination) == EEXIST)
        #expect(try read(destination) == "healthy")
        let free = temporary.file("degraded/free.txt")
        #expect(FileOperationService.renameCheckingDestinationFirst(from: source, to: free) == 0)
        #expect(try read(free) == "new")
    }

    @Test("フォルダをそれ自身の中へは運ばない(1 つも作らない)")
    func refusesToCopyAFolderIntoItself() async throws {
        let folder = try temporary.directory("self/A")
        let inside = try temporary.directory("self/A/sub")
        _ = try write("x", to: "self/A/f.txt")
        await #expect(throws: FileOperationError.destinationInsideSource(source: folder, destination: inside)) {
            _ = try await service.copy([folder], to: inside, options: .init(conflictPolicy: .keepBoth))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: inside.path).isEmpty)
        // 名前が前方一致するだけの隣のフォルダへは運べる。
        let sibling = try temporary.directory("self/A2")
        let outcome = try await service.move([folder], to: sibling, options: .init(conflictPolicy: .ask))
        #expect(outcome.receipts.count == 1)
    }

    @Test("出来上がるパスが上限を超えるなら書き始める前に断る")
    func refusesWhenThePathWouldBeTooLong() async throws {
        var deep = try temporary.directory("deep")
        while FileOperationPreflight.resultingPathBytes(destination: deep, relativePath: "") < 900 {
            deep = deep.appendingPathComponent(String(repeating: "d", count: 60), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let source = try write("x", to: String(repeating: "n", count: 200))
        await #expect(throws: FileOperationError.self) {
            _ = try await service.copy([source], to: deep, options: .init(conflictPolicy: .keepBoth))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: deep.path).isEmpty)
    }

    // MARK: - 衝突

    @Test("尋ねる相手がいないまま衝突したら、何も書かずに失敗する")
    func askWithoutResolverThrows() async throws {
        let source = try write("new", to: "ask/src/a.txt")
        _ = try write("old", to: "ask/dst/a.txt")
        let destination = temporary.file("ask/dst")
        await #expect(throws: FileOperationError.conflictResolutionRequired(destination: destination.appendingPathComponent("a.txt"))) {
            _ = try await service.copy([source], to: destination, options: .init(conflictPolicy: .ask))
        }
        #expect(try read(destination.appendingPathComponent("a.txt")) == "old")
    }

    @Test("両方残すは name 2.ext で置く")
    func keepBothPutsAsNumberedName() async throws {
        let source = try write("new", to: "keep/src/a.txt")
        _ = try write("old", to: "keep/dst/a.txt")
        let destination = temporary.file("keep/dst")
        let outcome = try await service.copy([source], to: destination, options: .init(conflictPolicy: .keepBoth))
        #expect(outcome.receipts.first?.destination.lastPathComponent == "a 2.txt")
        #expect(try read(destination.appendingPathComponent("a.txt")) == "old")
        #expect(try read(destination.appendingPathComponent("a 2.txt")) == "new")
    }

    @Test("置き換えるは、置き換えた元をゴミ箱へ送り、受領書にその場所を残す")
    func replaceSendsTheReplacedItemToTheTrash() async throws {
        let source = try write("new", to: "replace/src/a.txt")
        _ = try write("old", to: "replace/dst/a.txt")
        let destination = temporary.file("replace/dst")
        let outcome = try await service.copy([source], to: destination, options: .init(conflictPolicy: .replace))
        let receipt = try #require(outcome.receipts.first)
        #expect(try read(destination.appendingPathComponent("a.txt")) == "new")
        let replaced = try #require(receipt.replacedItemInTrash)
        #expect(replaced.lastPathComponent == "a.txt", "ゴミ箱には元の名前で入る")
        #expect(try read(replaced) == "old")
        // 退避用の隠しフォルダは残らない。
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["a.txt"])
    }

    @Test("尋ねた答えを「以降すべてに適用」すれば、もう尋ねない")
    func applyToRemainingAsksOnce() async throws {
        let names = ["a.txt", "b.txt", "c.txt"]
        let sources = try names.map { try write("new", to: "blanket/src/\($0)") }
        for name in names { _ = try write("old", to: "blanket/dst/\(name)") }
        let asked = AskCounter()
        let options = FileOperationOptions(conflictPolicy: .ask, conflictResolver: { _ in
            asked.count += 1
            return ConflictDecision(.skip, applyToRemaining: true)
        })
        let outcome = try await service.copy(sources, to: temporary.file("blanket/dst"), options: options)
        #expect(asked.count == 1)
        #expect(outcome.skipped == sources)
        #expect(outcome.receipts.isEmpty)
    }

    @Test("途中で失敗しても、動いた分の受領書と手つかずの項目を返す")
    func partialFailureKeepsReceipts() async throws {
        let a = try write("a", to: "partial/src/a.txt")
        let b = try write("b", to: "partial/src/b.txt")
        let c = try write("c", to: "partial/src/c.txt")
        _ = try write("old", to: "partial/dst/b.txt")
        let destination = temporary.file("partial/dst")
        // b で衝突し、尋ねる相手がいないので止まる。
        let outcome = try await service.move([a, b, c], to: destination, options: .init(conflictPolicy: .ask))
        #expect(outcome.receipts.map(\.source) == [a])
        #expect(outcome.failures.map(\.url) == [b])
        #expect(outcome.unprocessed == [c])
        #expect(!outcome.isCompleteSuccess)
        #expect(FileManager.default.fileExists(atPath: c.path))
    }

    @Test("自分のフォルダへの移動は何もしない")
    func movingIntoTheSameFolderIsANoOp() async throws {
        let file = try write("x", to: "same/a.txt")
        let outcome = try await service.move([file], to: file.deletingLastPathComponent(), options: .init(conflictPolicy: .ask))
        #expect(outcome.receipts.isEmpty)
        #expect(outcome.skipped == [file])
        #expect(FileManager.default.fileExists(atPath: file.path))
        // 「両方残す」でも改名しない。コピーなら複製になる。
        let keepBoth = try await service.move([file], to: file.deletingLastPathComponent(), options: .init(conflictPolicy: .keepBoth))
        #expect(keepBoth.receipts.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["a.txt"])
        let duplicate = try await service.copy([file], to: file.deletingLastPathComponent(), options: .init(conflictPolicy: .keepBoth))
        #expect(duplicate.receipts.first?.destination.lastPathComponent == "a 2.txt")
    }

    // MARK: - 実コピーの進捗・中止(クローンを禁じて、別ボリュームと同じ経路を通す)

    @Test("実コピーは進捗を報告し、最後は全バイトに届く")
    func realCopyReportsProgress() async throws {
        let copying = FileOperationService(environment: .pseudoTrash(at: trash), allowsCloning: false)
        let source = temporary.file("progress/big.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 8 * 1024 * 1024).write(to: source)
        let destination = try temporary.directory("progress/dst")
        let reports = ProgressLog()
        let options = FileOperationOptions(conflictPolicy: .keepBoth, progress: ProgressSink { reports.append($0) })
        let outcome = try await copying.copy([source], to: destination, options: options)
        #expect(outcome.isCompleteSuccess)
        let last = try #require(reports.values.last)
        #expect(last.completedItems == 1)
        let total: Int64 = 8 * 1024 * 1024
        #expect(last.totalBytes == total)
        #expect(reports.values.contains { $0.completedBytes > 0 && $0.completedBytes < total }, "最中の報告が 1 度は届く")
        #expect(last.completedBytes == total)
    }

    @Test("置き換えの最中に中止すると、書きかけを消して元を戻す(両方残る側に倒れる)")
    func cancellingAReplaceRestoresTheOriginal() async throws {
        let copying = FileOperationService(environment: .pseudoTrash(at: trash), allowsCloning: false)
        let source = temporary.file("cancel/src/big.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 32 * 1024 * 1024).write(to: source)
        let original = try write("healthy", to: "cancel/dst/big.bin")
        let cancellation = Cancellation()
        // 最初のバイトが届いたら中止する(ProgressTracker は項目の最初のバイトを間引かない)。
        let options = FileOperationOptions(
            conflictPolicy: .replace,
            progress: ProgressSink { if $0.completedBytes > 0 { cancellation.request() } },
            cancellation: cancellation
        )
        let outcome = try await copying.copy([source], to: original.deletingLastPathComponent(), options: options)
        #expect(outcome.wasCancelled)
        #expect(outcome.receipts.isEmpty)
        #expect(try read(original) == "healthy")
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path) == ["big.bin"])
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: - ゴミ箱・完全削除

    @Test("ゴミ箱へ送って戻す")
    func trashAndRestore() async throws {
        let file = try write("x", to: "trash/a.txt")
        let outcome = try await service.trash([file])
        let receipt = try #require(outcome.receipts.first)
        #expect(receipt.trashURL != nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let restored = await service.restoreFromTrash(outcome.receipts)
        #expect(restored.restored == [file])
        #expect(try read(file) == "x")
    }

    @Test("戻す場所に別の項目ができていたら上書きしない")
    func restoreDoesNotOverwrite() async throws {
        let file = try write("trashed", to: "restore-collide/a.txt")
        let outcome = try await service.trash([file])
        _ = try write("newer", to: "restore-collide/a.txt")
        let restored = await service.restoreFromTrash(outcome.receipts)
        #expect(restored.restored.isEmpty)
        #expect(restored.failures.count == 1)
        #expect(try read(file) == "newer")
    }

    @Test("ゴミ箱の無い場所では送らずに断る")
    func trashRefusesWhereThereIsNoTrash() async throws {
        let noTrash = FileOperationService(environment: .pseudoTrash(at: trash, hasTrash: { _ in false }))
        let file = try write("x", to: "no-trash/a.txt")
        await #expect(throws: FileOperationError.trashUnavailable(file)) { _ = try await noTrash.trash([file]) }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("完全削除は 1 件の失敗で止まらない")
    func deletePermanentlyContinuesPastFailures() async throws {
        let a = try write("a", to: "delete/a.txt")
        let missing = temporary.file("delete/missing.txt")
        let folder = try temporary.directory("delete/folder")
        _ = try write("x", to: "delete/folder/inner.txt")
        let outcome = await service.deletePermanently([a, missing, folder])
        #expect(outcome.deleted == [a, folder])
        #expect(outcome.failures.map(\.url) == [missing])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: - ロックされた項目

    @Test("ロックの判定と掛け外しはシンボリックリンクを辿らない")
    func lockingDoesNotFollowSymbolicLinks() throws {
        let file = try write("x", to: "lock-link/a.txt")
        let link = temporary.file("lock-link/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(FileOperationService.setLocked(file, true))
        #expect(FileOperationService.isLocked(file))
        #expect(!FileOperationService.isLocked(link))
        #expect(FileOperationService.lockedItems(atOrUnder: link).isEmpty)
        #expect(FileOperationService.setLocked(file, false))
        #expect(!FileOperationService.isLocked(file))
    }

    @Test("ロックされた項目は、許されなければゴミ箱へ送らず「ロックされています」の失敗にする")
    func trashLeavesLockedItemsUnlessAllowed() async throws {
        let locked = try write("locked", to: "trash-locked/locked.txt")
        let plain = try write("plain", to: "trash-locked/plain.txt")
        FileOperationService.setLocked(locked, true)

        let outcome = try await service.trash([locked, plain])
        #expect(outcome.receipts.map(\.originalURL) == [plain])
        #expect(outcome.failures.map(\.url) == [locked])
        #expect(outcome.failures.first?.reason == FileOperationError.itemLocked(locked).localizedDescription)
        #expect(FileOperationService.isLocked(locked))

        await #expect(throws: FileOperationError.itemLocked(locked)) { _ = try await service.trash([locked]) }
    }

    @Test("ロックを外して送ると、ゴミ箱の中でもロックされていて、戻すとロックも戻る")
    func trashUnlockingKeepsTheLockInTheTrash() async throws {
        let locked = try write("locked", to: "trash-unlock/locked.txt")
        FileOperationService.setLocked(locked, true)

        let outcome = try await service.trash([locked], unlockingLocked: true)
        let trashed = try #require(outcome.receipts.first?.trashURL)
        #expect(!FileManager.default.fileExists(atPath: locked.path))
        #expect(FileOperationService.isLocked(trashed))

        let restored = await service.restoreFromTrash(outcome.receipts)
        #expect(restored.restored == [locked])
        #expect(FileOperationService.isLocked(locked))
        #expect(try read(locked) == "locked")
    }

    @Test("中にロックされた項目があるフォルダは、許されなければ 1 つも消さない。許されれば全部消す")
    func deletePermanentlyWithLockedDescendants() async throws {
        let folder = try temporary.directory("delete-locked/folder")
        let first = try write("1", to: "delete-locked/folder/1.txt")
        let inner = try write("2", to: "delete-locked/folder/sub/2.txt")
        FileOperationService.setLocked(inner, true)

        let refused = await service.deletePermanently([folder])
        #expect(refused.deleted.isEmpty)
        #expect(refused.failures.first?.reason == FileOperationError.itemLocked(folder).localizedDescription)
        #expect(FileManager.default.fileExists(atPath: first.path), "触る前に断っていない(途中まで消えた)")
        #expect(FileOperationService.isLocked(inner))

        let allowed = await service.deletePermanently([folder], unlockingLocked: true)
        #expect(allowed.deleted == [folder])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("起動ボリュームにはゴミ箱がある")
    func bootVolumeHasATrash() async {
        let url = temporary.url
        let hasTrash = await FileIO.perform { TrashAvailability.hasTrash(for: url) }
        #expect(hasTrash)
    }
}

/// 元が運ぶ間に変わったかの規則(MoveVerification)。時間に依存しない形で直に確かめる。
struct MoveVerificationTests {
    @Test("大きさが変わったら変わった、日時だけなら中身で決める")
    func modificationRules() throws {
        let temporary = try TemporaryDirectory("move-verification")
        let source = temporary.file("src.bin")
        let destination = temporary.file("dst.bin")
        let content = Data((0..<200_000).map { UInt8($0 % 251) })
        try content.write(to: source)
        try content.write(to: destination)
        let before = MoveVerification.stamp(of: source)

        // 何も変わらない。
        #expect(!MoveVerification.sourceWasModified(before: before, source: source, destination: destination))

        // 日時だけ変わった(SMB が書き込み直後に差し替えるのと同じ形)。中身は同じなので変わっていない。
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: source.path)
        #expect(!MoveVerification.sourceWasModified(before: before, source: source, destination: destination))

        // 同じ大きさで中身が入れ替わった。
        var changed = content
        changed[100_000] ^= 0xFF
        try changed.write(to: source)
        #expect(MoveVerification.sourceWasModified(before: before, source: source, destination: destination))

        // 書き足された。
        try (content + Data([1, 2, 3])).write(to: source)
        #expect(MoveVerification.sourceWasModified(before: before, source: source, destination: destination))
    }
}

/// `@Sendable` なクロージャから数えるための箱(テストの中だけで使う)。
nonisolated final class AskCounter: @unchecked Sendable {
    var count = 0
}

nonisolated final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FileOperationProgress] = []

    func append(_ value: FileOperationProgress) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [FileOperationProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
