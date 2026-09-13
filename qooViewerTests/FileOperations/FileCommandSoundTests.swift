import AudioToolbox
import Foundation
import Testing

@testable import qooViewer

/// ファイル操作の効果音(Services/FileOperations/SystemSoundPlayer.swift と FileCommandStack)。
///
/// **音は鳴らさない**: 積み場所には記録するだけの偽物を渡し、音源の検査は `AudioServicesCreateSystemSoundID`
/// で登録するだけ(再生しない)。音源は macOS 同梱のファイルを直接指しているので、OS 側で場所や名前が
/// 変わったら静かに無音になる ―― 気づけるようにここで拾う。
@MainActor
struct FileCommandSoundTests {
    actor RecordingPlayer: SystemSoundPlaying {
        private(set) var played: [SystemSoundEffect] = []
        func play(_ effect: SystemSoundEffect) { played.append(effect) }
    }

    final class Scripted: FileCommand {
        let displayName = "scripted"
        var isUndoable = true
        var completionSound: SystemSoundEffect?
        var result: FileCommandResult = .success
        var error: (any Error)?

        init(sound: SystemSoundEffect?) { completionSound = sound }

        func execute() async throws -> FileCommandResult {
            if let error { throw error }
            return result
        }

        func undo() async throws -> FileUndoResult { .complete }
    }

    @Test(arguments: SystemSoundEffect.allCases)
    func soundFileExistsAndRegisters(_ effect: SystemSoundEffect) {
        #expect(FileManager.default.fileExists(atPath: effect.fileURL.path), "音源が見つかりません: \(effect)")
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(effect.fileURL as CFURL, &id)
        defer { if status == noErr { AudioServicesDisposeSystemSoundID(id) } }
        #expect(status == noErr)
    }

    @Test("効果ごとに別の音源を指す")
    func effectsUseDistinctFiles() {
        let paths = SystemSoundEffect.allCases.map(\.fileURL.path)
        #expect(Set(paths).count == paths.count)
    }

    @Test("テストホストの中では既定のプレーヤーは鳴らさない")
    func defaultPlayerIsSilentUnderTests() {
        #expect(RuntimeEnvironment.isRunningTests)
    }

    @Test("コマンドごとの音の割り当て(移動・コピー=完了音、ゴミ箱、完全削除、名前の変更と新規フォルダは無音)")
    func assignments() {
        let url = URL(fileURLWithPath: "/tmp/qooViewerTests-never/a")
        let folder = URL(fileURLWithPath: "/tmp/qooViewerTests-never", isDirectory: true)
        #expect(MoveFilesCommand(items: [url], destination: folder, options: .init()).completionSound == .operationComplete)
        #expect(CopyFilesCommand(items: [url], destination: folder, options: .init()).completionSound == .operationComplete)
        #expect(TrashFilesCommand(items: [url]).completionSound == .moveToTrash)
        #expect(DeleteFilesImmediatelyCommand(items: [url]).completionSound == .permanentDelete)
        #expect(RenameFileCommand(item: url, newName: "b").completionSound == nil)
        #expect(CreateFolderCommand(url: url).completionSound == nil)
        let composite = CompositeFileCommand(displayName: "c", children: [
            RenameFileCommand(item: url, newName: "b"),
            TrashFilesCommand(items: [url]),
            CopyFilesCommand(items: [url], destination: folder, options: .init()),
        ])
        #expect(composite.completionSound == .moveToTrash)
    }

    @Test("済んだときとやり直しで鳴らし、取り消し・部分的な成功・失敗では鳴らさない")
    func stackPlaysOnlyOnSuccess() async throws {
        let player = RecordingPlayer()
        let stack = FileCommandStack(soundPlayer: player)
        let command = Scripted(sound: .operationComplete)
        try await stack.run(command)
        #expect(await player.played == [.operationComplete])

        _ = await stack.undo()
        #expect(await player.played == [.operationComplete])
        _ = await stack.redo()
        #expect(await player.played == [.operationComplete, .operationComplete])

        let partial = Scripted(sound: .moveToTrash)
        partial.result = .partial(succeeded: 1, failures: [FailedItem(name: "x", reason: "r")], wasCancelled: false)
        try await stack.run(partial)
        let failing = Scripted(sound: .moveToTrash)
        failing.error = CancellationError()
        _ = try? await stack.run(failing)
        let silent = Scripted(sound: nil)
        try await stack.run(silent)
        #expect(await player.played == [.operationComplete, .operationComplete])
    }

    @Test("積まない操作(完全削除)でも済めば鳴らす")
    func nonUndoableStillPlays() async throws {
        let player = RecordingPlayer()
        let stack = FileCommandStack(soundPlayer: player)
        let command = Scripted(sound: .permanentDelete)
        command.isUndoable = false
        try await stack.run(command)
        #expect(await player.played == [.permanentDelete])
        #expect(!stack.canUndo)
    }
}
