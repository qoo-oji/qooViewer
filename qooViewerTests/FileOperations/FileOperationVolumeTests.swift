import Foundation
import Testing

@testable import qooViewer

/// ファイル操作エンジンのうち、**別のボリュームが要る**もの。ボリュームはスキームの Pre-action が付ける
/// (qooViewerTests/Support/DisposableVolume.swift)。
///
/// `.serialized`: 同じボリュームを共有し、空き容量の検査は tiny ボリュームを丸ごと使うため。
/// I/O 律速なので並べる価値もない。
@Suite(.serialized)
struct FileOperationVolumeTests {
    private let service: FileOperationService
    private let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory("file-ops-volume")
        service = FileOperationService(environment: .pseudoTrash(at: try temporary.directory("PseudoTrash")))
    }

    @Test("別ボリュームへの移動は、運んでから元を消す(進捗も届く)")
    func crossVolumeMoveCopiesThenRemovesTheSource() async throws {
        guard let volume = DisposableVolume.make(.apfs, "cross-move") else { return }
        let source = temporary.file("book.bin")
        let content = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 253) })
        try content.write(to: source)
        let reports = ProgressLog()
        let outcome = try await service.move(
            [source], to: volume.url, options: .init(conflictPolicy: .ask, progress: ProgressSink { reports.append($0) })
        )
        let moved = volume.file("book.bin")
        #expect(outcome.isCompleteSuccess)
        #expect(outcome.receipts.first?.destination == moved)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: moved) == content)
        #expect(reports.values.last?.totalBytes == Int64(content.count), "別ボリュームなので総量を数えている")
    }

    @Test("別ボリュームへのフォルダの移動")
    func crossVolumeFolderMove() async throws {
        guard let volume = DisposableVolume.make(.apfs, "cross-folder") else { return }
        let folder = try temporary.directory("Series")
        try Data("1".utf8).write(to: folder.appendingPathComponent("01.cbz"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("extra"), withIntermediateDirectories: true)
        try Data("2".utf8).write(to: folder.appendingPathComponent("extra/02.cbz"))
        let outcome = try await service.move([folder], to: volume.url, options: .init(conflictPolicy: .ask))
        #expect(outcome.isCompleteSuccess)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: volume.file("Series/extra/02.cbz").path))
    }

    @Test("別ボリュームへの移動では中のロックも邪魔をする。許せば外して運び、運んだ先の同じ場所で掛け直す")
    func crossVolumeMoveOfFolderWithLockedItems() async throws {
        guard let volume = DisposableVolume.make(.apfs, "cross-locked") else { return }
        let folder = try temporary.directory("LockedSeries")
        let inner = folder.appendingPathComponent("extra/02.cbz")
        try FileManager.default.createDirectory(at: inner.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("2".utf8).write(to: inner)
        FileOperationService.setLocked(inner, true)
        #expect(FileOperationService.movingIsBlockedByLock(folder, to: volume.url, mounts: .current()))

        await #expect(throws: FileOperationError.itemLocked(folder)) {
            _ = try await service.move([folder], to: volume.url, options: .init(conflictPolicy: .ask))
        }
        #expect(FileOperationService.isLocked(inner))
        #expect(!FileManager.default.fileExists(atPath: volume.file("LockedSeries").path))

        let outcome = try await service.move([folder], to: volume.url, options: .init(conflictPolicy: .ask, unlockingLocked: true))
        #expect(outcome.isCompleteSuccess)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let moved = volume.file("LockedSeries/extra/02.cbz")
        #expect(FileOperationService.isLocked(moved))
        FileOperationService.setLocked(moved, false)
    }

    @Test("別ボリュームへの移動で元の削除が途中で止まっても、宛先の写しは消さずに残し「元を消せなかった」と伝える")
    func crossVolumeMoveKeepsTheCopyWhenTheSourceCannotBeRemoved() async throws {
        guard let volume = DisposableVolume.make(.apfs, "cross-append-only") else { return }
        // 2026-09-14 の監査の実測そのもの: 以前は元も宛先も `log.txt` だけになり、6 ファイルが消えた。
        let folder = try temporary.directory("AppendOnly")
        let names = ["01.cbz", "02.cbz", "03.cbz", "04.cbz", "05.cbz", "zz.cbz"]
        for name in names { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        let log = folder.appendingPathComponent("log.txt")
        try Data("log".utf8).write(to: log)
        #expect(chflags(log.path, UInt32(UF_APPEND)) == 0)
        let moved = volume.file("AppendOnly")
        defer {
            chflags(log.path, 0)
            chflags(moved.appendingPathComponent("log.txt").path, 0)
        }

        let outcome = try await service.move([folder], to: volume.url, options: .init(conflictPolicy: .ask))
        #expect(outcome.receipts.map(\.destination) == [moved], "写しは宛先に揃っているので受領書を返す")
        #expect(outcome.failures.map(\.url) == [folder])
        #expect(!outcome.isCompleteSuccess)
        for name in names + ["log.txt"] {
            #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent(name).path), "宛先の \(name)")
        }
        #expect(FileManager.default.fileExists(atPath: log.path), "消せなかった元は残る")
    }

    @Test("中身のある 0555 のサブフォルダを含むフォルダも、同じボリュームにも別のボリュームにもコピーできる")
    func copiesTreesWithReadOnlySubfolders() async throws {
        guard let volume = DisposableVolume.make(.apfs, "read-only-subfolder") else { return }
        let folder = try temporary.directory("FromDisc")
        let readOnly = folder.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: readOnly.appendingPathComponent("a.cbz"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("b.cbz"))
        #expect(chmod(readOnly.path, 0o555) == 0)
        let sameVolume = try temporary.directory("Copies")
        let copies = [sameVolume.appendingPathComponent("FromDisc"), volume.file("FromDisc")]
        defer {
            for root in [folder] + copies { chmod(root.appendingPathComponent("ro").path, 0o755) }
        }

        for destination in [sameVolume, volume.url] {
            // 以前は `COPYFILE_CLONE | COPYFILE_RECURSIVE` が EACCES で失敗し、作りかけの木を宛先に残した。
            let outcome = try await service.copy([folder], to: destination, options: .init(conflictPolicy: .ask))
            #expect(outcome.isCompleteSuccess)
        }
        for copy in copies {
            #expect(try Data(contentsOf: copy.appendingPathComponent("ro/a.cbz")) == Data("a".utf8))
            #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("b.cbz").path))
            var info = stat()
            #expect(lstat(copy.appendingPathComponent("ro").path, &info) == 0 && info.st_mode & 0o777 == 0o555, "権限ごと写る")
        }
    }

    @Test("フォルダのコピー・別ボリュームへの移動が途中で失敗したら、宛先に書きかけの木を残さない")
    func failedFolderTransferLeavesNoPartialTree() async throws {
        guard let volume = DisposableVolume.make(.apfs, "partial-tree") else { return }
        let folder = try temporary.directory("Unreadable")
        try Data("1".utf8).write(to: folder.appendingPathComponent("01.cbz"))
        let unreadable = folder.appendingPathComponent("02.cbz")
        try Data("2".utf8).write(to: unreadable)
        #expect(chmod(unreadable.path, 0o000) == 0)
        defer { chmod(unreadable.path, 0o644) }

        await #expect(throws: FileOperationError.self) {
            _ = try await service.copy([folder], to: volume.url, options: .init(conflictPolicy: .ask))
        }
        #expect(!FileOperationService.itemExists(at: volume.file("Unreadable")))
        await #expect(throws: FileOperationError.self) {
            _ = try await service.move([folder], to: volume.url, options: .init(conflictPolicy: .ask))
        }
        #expect(!FileOperationService.itemExists(at: volume.file("Unreadable")))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("01.cbz").path), "元は触らない")
    }

    @Test("exFAT では RENAME_EXCL が ENOTSUP を返すので、縮退経路で同じボリューム内を移動できる")
    func exFATMoveUsesTheDegradedRename() async throws {
        guard let volume = DisposableVolume.make(.exfat, "exfat-move") else { return }
        let file = volume.file("a.txt")
        try Data("x".utf8).write(to: file)
        let destination = try volume.directory("sub")
        // 前提の固定: この形式では本当に ENOTSUP が返る(返らなくなったら、このテストは縮退経路を通っていない)。
        let probe = volume.file("probe.txt")
        try Data("p".utf8).write(to: probe)
        let code = renamex_np(probe.path, volume.file("probe2.txt").path, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        #expect(code == ENOTSUP)

        let outcome = try await service.move([file], to: destination, options: .init(conflictPolicy: .ask))
        #expect(outcome.isCompleteSuccess)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
        // 縮退経路でも上書きはしない。
        try Data("old".utf8).write(to: volume.file("b.txt"))
        try Data("healthy".utf8).write(to: destination.appendingPathComponent("b.txt"))
        let collide = try await service.move([volume.file("b.txt")], to: destination, options: .init(conflictPolicy: .keepBoth))
        #expect(collide.receipts.first?.destination.lastPathComponent == "b 2.txt")
        #expect(String(decoding: try Data(contentsOf: destination.appendingPathComponent("b.txt")), as: UTF8.self) == "healthy")
    }

    @Test("クローンできない形式では、同じボリューム内のコピーも総量を数えて実際に書く")
    func exFATCopyWritesBytes() async throws {
        guard let volume = DisposableVolume.make(.exfat, "exfat-copy") else { return }
        let source = volume.file("src.bin")
        try Data(count: 2 * 1024 * 1024).write(to: source)
        let reports = ProgressLog()
        let outcome = try await service.copy(
            [source], to: try volume.directory("dst"), options: .init(conflictPolicy: .ask, progress: ProgressSink { reports.append($0) })
        )
        #expect(outcome.isCompleteSuccess)
        let total: Int64 = 2 * 1024 * 1024
        #expect(reports.values.last?.completedBytes == total)
        #expect(reports.values.last?.totalBytes == total)
    }

    @Test("FAT32 の 1 ファイルの上限を宛先ごとに読める")
    func fat32ReportsItsFileSizeLimit() throws {
        guard let volume = DisposableVolume.make(.fat32, "fat32-limit") else { return }
        let limit = try #require(FileOperationPreflight.maximumFileSize(at: volume.url))
        #expect(limit < 4 * 1024 * 1024 * 1024)
    }

    @Test("空きが足りないと分かっていれば 1 バイトも書かずに断る")
    func refusesBeforeWritingWhenTheDestinationIsTooSmall() async throws {
        guard let volume = DisposableVolume.make(.tiny, "free-space") else { return }
        let source = temporary.file("large.bin")
        try Data(count: 40 * 1024 * 1024).write(to: source)
        await #expect {
            _ = try await service.copy([source], to: volume.url, options: .init(conflictPolicy: .keepBoth))
        } throws: { error in
            // 見せる必要量は比べた値(余裕込み)なので、空きより必ず大きい(「1.5 GB 必要、空き 1.5 GB」と読めない)。
            guard case let .insufficientFreeSpace(required, available, _) = error as? FileOperationError else { return false }
            return required > available
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: volume.url.path).isEmpty)
    }

    @Test("展開の途中でディスクがいっぱいになっても落ちず(SIGABRT にならず)、空きが無いと伝えて一時フォルダを残さない")
    func extractionFailsCleanlyWhenTheDiskFills() async throws {
        guard let volume = DisposableVolume.make(.tiny, "extract-full") else { return }
        var builder = ZipFixtureBuilder()
        // 無圧縮で入れる(書庫は起動ボリュームの一時フォルダに置く)。圧縮しても縮まない中身。
        var content = Data(count: 30 * 1024 * 1024)
        content.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        builder.add("big.bin", content, stored: true)
        let archive = temporary.file("big.zip")
        try builder.write(to: archive)
        var limits = ArchiveExtractionLimits.standard
        limits.checksFreeSpace = false

        await #expect {
            _ = try await service.extract(
                [archive], into: volume.url, placement: .contents, limits: limits, progress: nil, cancellation: Cancellation()
            )
        } throws: { error in
            guard case let .posixFailure(_, code) = error as? FileOperationError else { return false }
            return code == ENOSPC
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: volume.url.path).isEmpty)
    }

    @Test("作ったばかりのローカルのボリュームにもゴミ箱がある(.Trashes がまだ無くても)")
    func freshLocalVolumeHasATrash() async throws {
        guard let volume = DisposableVolume.make(.fat32, "fresh-trash") else { return }
        let url = volume.url
        let hasTrash = await FileIO.perform { TrashAvailability.hasTrash(for: url) }
        #expect(hasTrash)
    }
}
