import Foundation
import Testing

@testable import qooViewer

/// フォルダ同士の「結合」(`ConflictPolicy.merge`、2026-10-24)と、衝突の問い合わせに渡す手がかり(`FileConflict` の
/// `isMove` / `hasMoreItems`、`ConflictFacts`)。ゴミ箱は疑似ゴミ箱。
struct FileOperationMergeTests {
    private let temporary: TemporaryDirectory
    private let trash: URL
    private let service: FileOperationService

    init() throws {
        temporary = try TemporaryDirectory("file-merge")
        trash = try temporary.directory("PseudoTrash")
        service = FileOperationService(environment: .pseudoTrash(at: trash))
    }

    private func write(_ text: String, to relativePath: String, age: TimeInterval? = nil) throws -> URL {
        let url = temporary.file(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let age { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path) }
        return url
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func names(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// 運ぶ側: only.txt(宛先に無い)・newer.txt(運ぶ側が新しい)・older.txt(運ぶ側が古い)・Sub/inner.txt(中のフォルダも結合)。
    /// 宛先: newer.txt・older.txt・kept.txt・Sub/theirs.txt。
    private func makeFolders() throws -> (source: URL, destination: URL) {
        _ = try write("only", to: "m/src/F/only.txt")
        _ = try write("src newer", to: "m/src/F/newer.txt", age: 10)
        _ = try write("src older", to: "m/src/F/older.txt", age: 86_400)
        _ = try write("inner", to: "m/src/F/Sub/inner.txt")
        _ = try write("dst older", to: "m/dst/F/newer.txt", age: 86_400)
        _ = try write("dst newer", to: "m/dst/F/older.txt", age: 10)
        _ = try write("kept", to: "m/dst/F/kept.txt")
        _ = try write("theirs", to: "m/dst/F/Sub/theirs.txt")
        return (temporary.file("m/src/F"), temporary.file("m/dst"))
    }

    @Test("結合は宛先に無い項目を置き、両方にあるフォルダは中をまとめ、両方にあるファイルは新しい方を残す")
    func mergeKeepsNewerItems() async throws {
        let (source, destination) = try makeFolders()
        let options = FileOperationOptions(conflictPolicy: .ask, conflictResolver: { _ in ConflictDecision(.merge) })

        let outcome = try await service.copy([source], to: destination, options: options)

        let merged = destination.appendingPathComponent("F")
        #expect(outcome.isCompleteSuccess)
        #expect(try names(in: merged) == ["Sub", "kept.txt", "newer.txt", "older.txt", "only.txt"])
        #expect(try names(in: merged.appendingPathComponent("Sub")) == ["inner.txt", "theirs.txt"])
        #expect(try read(merged.appendingPathComponent("newer.txt")) == "src newer", "運ぶ側が新しければ置き換える")
        #expect(try read(merged.appendingPathComponent("older.txt")) == "dst newer", "宛先が新しければ残す")
        #expect(try read(merged.appendingPathComponent("kept.txt")) == "kept")
        // 受領書は置いたもの・置き換えたものだけ(取り消しはこれだけをゴミ箱へ送る)。
        #expect(Set(outcome.receipts.map(\.destination.lastPathComponent)) == ["inner.txt", "newer.txt", "only.txt"])
        let replaced = try #require(outcome.receipts.first { $0.destination.lastPathComponent == "newer.txt" })
        #expect(replaced.didReplace)
        let inTrash = try #require(replaced.replacedItemInTrash)
        #expect(try read(inTrash) == "dst older", "置き換えた元はゴミ箱へ")
        #expect(try read(source.appendingPathComponent("only.txt")) == "only", "コピーなので元はそのまま")
    }

    @Test("運ぶフォルダを中に含むフォルダとは結合しない(運んでいる元へ書き足さない)")
    func mergeRefusesAFolderThatContainsTheSource() async throws {
        // m2/a/a(運ぶ側)を m2 へ ―― 宛先の m2/a は運ぶ側を中に含む。
        _ = try write("deep", to: "m2/a/a/a/deep.txt")
        let source = temporary.file("m2/a/a")
        let destination = temporary.file("m2")
        let options = FileOperationOptions(conflictPolicy: .ask, conflictResolver: { _ in ConflictDecision(.merge) })

        let outcome = try? await service.copy([source], to: destination, options: options)

        #expect(outcome?.isCompleteSuccess != true)
        #expect(try names(in: temporary.file("m2/a")) == ["a"], "宛先(運ぶ側の親)に中身を書き足さない")
        #expect(try names(in: source) == ["a"], "運ぶ側(元)にも書き足さない")
        #expect(try names(in: source.appendingPathComponent("a")) == ["deep.txt"])
    }

    @Test("結合で運ばなかった項目(宛先の方が新しい)のバイト数は進み具合の総量から外し、最後は総量に届く")
    func mergeReportsSkippedBytes() async throws {
        let (source, destination) = try makeFolders()
        let service = FileOperationService(environment: .pseudoTrash(at: trash), allowsCloning: false)
        let last = LastProgress()
        let options = FileOperationOptions(
            conflictPolicy: .ask, conflictResolver: { _ in ConflictDecision(.merge) },
            progress: ProgressSink { last.set($0) }
        )

        let outcome = try await service.copy([source], to: destination, options: options)

        #expect(outcome.isCompleteSuccess)
        let progress = try #require(last.value)
        #expect(progress.totalBytes > 0)
        // 宛先の older.txt の方が新しいので運ばない。その分を総量から外すので、最後は全体に届く(以前は届かずに終わった)。
        #expect(progress.completedBytes == progress.totalBytes)
    }

    @MainActor
    @Test("結合したコピーの取り消しは、置いたものだけをゴミ箱へ送り、置き換えた元を戻す")
    func undoingMergeRestoresTheFolder() async throws {
        let (source, destination) = try makeFolders()
        let merged = destination.appendingPathComponent("F")
        let options = FileOperationOptions(conflictPolicy: .ask, conflictResolver: { _ in ConflictDecision(.merge) })
        let command = CopyFilesCommand(items: [source], destination: destination, options: options, fileOps: service)

        _ = try await command.execute()
        let undone = try await command.undo()

        #expect(undone == .complete)
        #expect(try names(in: merged) == ["Sub", "kept.txt", "newer.txt", "older.txt"])
        #expect(try names(in: merged.appendingPathComponent("Sub")) == ["theirs.txt"])
        #expect(try read(merged.appendingPathComponent("newer.txt")) == "dst older", "置き換える前の項目が戻る")
    }

    @Test("結合はフォルダ同士のコピーだけ。ファイルの衝突に「すべてに適用」の結合が当たったら尋ね直す")
    func mergeOnlyAppliesToFolderPairs() async throws {
        let folder = try write("x", to: "pair/src/F/a.txt").deletingLastPathComponent()
        _ = try write("y", to: "pair/dst/F/b.txt")
        let file = try write("new", to: "pair/src/g.txt")
        _ = try write("old", to: "pair/dst/g.txt")
        let asked = AskCounter()
        let options = FileOperationOptions(conflictPolicy: .ask, conflictResolver: { _ in
            asked.count += 1
            return asked.count == 1 ? ConflictDecision(.merge, applyToRemaining: true) : ConflictDecision(.skip)
        })

        let outcome = try await service.copy([folder, file], to: temporary.file("pair/dst"), options: options)

        #expect(asked.count == 2, "ファイルの衝突ではもう一度尋ねる")
        #expect(outcome.skipped.map(\.lastPathComponent) == ["g.txt"])
        #expect(try names(in: temporary.file("pair/dst/F")) == ["a.txt", "b.txt"])
    }

    @Test("衝突の問い合わせは、移動かどうかと、後に項目が残っているかを持つ")
    func conflictCarriesMoveAndRemainingItems() async throws {
        let a = try write("a", to: "info/src/a.txt")
        let b = try write("b", to: "info/src/b.txt")
        _ = try write("old", to: "info/dst/a.txt")
        _ = try write("old", to: "info/dst/b.txt")
        let seen = ConflictLog()
        let options = FileOperationOptions(conflictPolicy: .ask, conflictResolver: { conflict in
            seen.append(conflict)
            return ConflictDecision(.skip)
        })

        _ = try await service.move([a, b], to: temporary.file("info/dst"), options: options)

        #expect(seen.conflicts.map(\.isMove) == [true, true])
        #expect(seen.conflicts.map(\.hasMoreItems) == [true, false], "最後の 1 件には「すべてに適用」を出さない")
        #expect(seen.conflicts.map(\.isSingleItem) == [false, false], "複数を運ぶ操作では新しい・古いを書き分けない(Finder)")
    }

    @Test("衝突の手がかり: 新しい・古いは宛先の項目から見る。フォルダ同士なら結合で残る項目を数える")
    func conflictFacts() throws {
        let (source, destination) = try makeFolders()
        let folders = ConflictFacts(FileConflict(source: source, destination: destination.appendingPathComponent("F")))
        #expect(folders.isFolderPair)
        #expect(folders.keptByMerge.count == 3, "only.txt・newer.txt・Sub/inner.txt")
        #expect(folders.keptByMerge.firstName == "inner.txt" || folders.keptByMerge.firstName == "newer.txt")

        let newer = ConflictFacts(FileConflict(
            source: source.appendingPathComponent("older.txt"), destination: destination.appendingPathComponent("F/older.txt")
        ))
        #expect(!newer.isFolderPair)
        #expect(newer.age == .destinationNewer)
        let older = ConflictFacts(FileConflict(
            source: source.appendingPathComponent("newer.txt"), destination: destination.appendingPathComponent("F/newer.txt")
        ))
        #expect(older.age == .destinationOlder)
        // 移動では結合を出さないので数えない。
        let moving = ConflictFacts(FileConflict(source: source, destination: destination.appendingPathComponent("F"), isMove: true))
        #expect(moving.keptByMerge.count == 0)
    }

    @Test("名前が宛先の上限を超える項目は、SMB の宛先でだけ、運ぶ項目そのものの名前で選ぶ")
    func itemsWithNamesTooLong() {
        let mounts = MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "/dev/x", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/Share", mountedFrom: "//server/share", fileSystemType: "smbfs", isLocal: false, isHiddenFromBrowsing: false),
        ])
        // パスはマウント先と名前を繋いで作る(実在しそうな絶対パスを書かない ―― check-private-terms.sh)。
        let source = URL(filePath: "/Volumes/Source", directoryHint: .isDirectory)
        let long = source.appendingPathComponent(String(repeating: "ガ", count: 86) + ".cbz")
        let short = source.appendingPathComponent("short.cbz")
        let share = URL(filePath: "/Volumes/Share", directoryHint: .isDirectory).appendingPathComponent("in", isDirectory: true)
        #expect(FileOperationPreflight.itemsWithNamesTooLong([long, short], destination: share, mounts: mounts) == [long])
        #expect(FileOperationPreflight.itemsWithNamesTooLong([long, short], destination: URL(filePath: "/Users"), mounts: mounts).isEmpty)
    }
}

nonisolated final class ConflictLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FileConflict] = []

    func append(_ conflict: FileConflict) {
        lock.withLock { storage.append(conflict) }
    }

    var conflicts: [FileConflict] { lock.withLock { storage } }
}

/// 進み具合の最後の報告(報告は FileIO のスレッドから来る)。
private nonisolated final class LastProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FileOperationProgress?

    var value: FileOperationProgress? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ progress: FileOperationProgress) {
        lock.lock()
        stored = progress
        lock.unlock()
    }
}
