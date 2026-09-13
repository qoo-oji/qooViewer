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
            guard case .insufficientFreeSpace = error as? FileOperationError else { return false }
            return true
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
