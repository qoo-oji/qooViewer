import Foundation
import Testing

@testable import qooViewer

/// 登録済みの本が「いまどうなっているか」の判定(Services/BookLocationResolver.swift)。
///
/// ここが間違うと、**生きている本をコレクションから消す**ところまで行ける
/// (CollectionStore.missingBookSweep → MissingBooksCleanupSheet)。そのため
/// 「消してよい」(.missing)を返す条件と、迷ったら消せない側に倒れることの両方を押さえる。
struct BookLocationTests {
    /// 実体のあるURLからブックマークを作る(コレクションへの登録と同じ `.withSecurityScope`)。
    private func probe(for url: URL, recordedPath: String? = nil) throws -> BookLocationResolver.Probe {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let identifier = FileNodeIdentifier.current(for: url)
        return BookLocationResolver.Probe(
            itemID: UUID(), bookmark: bookmark, recordedPath: recordedPath ?? url.path,
            volumeUUID: identifier?.volumeUUID
        )
    }

    private var mounted: Set<String> { BookLocationResolver.mountedVolumeUUIDs() }

    @Test("実体があれば found(そのURLを返す)")
    func anExistingFileIsFound() throws {
        let workspace = try TemporaryDirectory("location-found")
        let url = workspace.file("a.cbz")
        try Data("a".utf8).write(to: url)

        let location = BookLocationResolver.resolve(try probe(for: url), mountedVolumeUUIDs: mounted)
        #expect(location.exists)
        #expect(location.url?.path == url.path)
    }

    @Test("リネームされただけの本は found(ブックマークが追いかける)")
    func aRenamedFileIsStillFound() throws {
        let workspace = try TemporaryDirectory("location-renamed")
        let original = workspace.file("before.cbz")
        try Data("a".utf8).write(to: original)
        let probe = try probe(for: original)

        let renamed = workspace.file("after.cbz")
        try FileManager.default.moveItem(at: original, to: renamed)

        let location = BookLocationResolver.resolve(probe, mountedVolumeUUIDs: mounted)
        #expect(location == .found(renamed))
    }

    @Test("ボリュームは健在で実体が消えていれば missing(掃除の対象)")
    func aDeletedFileOnAHealthyVolumeIsMissing() throws {
        let workspace = try TemporaryDirectory("location-missing")
        let url = workspace.file("a.cbz")
        try Data("a".utf8).write(to: url)
        let probe = try probe(for: url)
        try FileManager.default.removeItem(at: url)

        #expect(BookLocationResolver.resolve(probe, mountedVolumeUUIDs: mounted) == .missing)
    }

    @Test("ボリュームが付いていなければ volumeUnavailable(実体の有無は問わない)")
    func anAbsentVolumeIsNeverMissing() throws {
        let workspace = try TemporaryDirectory("location-volume")
        let url = workspace.file("a.cbz")
        try Data("a".utf8).write(to: url)
        let probe = try probe(for: url)
        try FileManager.default.removeItem(at: url)

        // 記録してあるボリュームUUIDが、いまマウントされている一覧に無い状態
        // (外付けを外しているのと同じ)。外付けの本を消さないための、いちばん大事な一線。
        #expect(BookLocationResolver.resolve(probe, mountedVolumeUUIDs: []) == .volumeUnavailable)
    }

    @Test("ブックマークが壊れていれば unreachable(実体は生きているかもしれない)")
    func aCorruptBookmarkIsUnreachable() {
        // 実測(2026-09-10): 壊れたブックマークデータは NSFileReadCorruptFileError で失敗し、
        // 実体が消えたブックマークは NSFileNoSuchFileError で失敗する。前者では場所が
        // 分からないので、実体の有無を判断してはいけない。
        let probe = BookLocationResolver.Probe(
            itemID: UUID(), bookmark: Data(repeating: 0xAB, count: 256),
            recordedPath: "/Users/nobody/ghost.cbz", volumeUUID: nil
        )
        #expect(BookLocationResolver.resolve(probe, mountedVolumeUUIDs: mounted) == .unreachable)
    }

    @Test("ブックマークが使えなくても、記録してあるパスに実体があれば unreachable")
    func anExistingRecordedPathPreventsMissing() throws {
        let workspace = try TemporaryDirectory("location-path")
        let url = workspace.file("a.cbz")
        try Data("a".utf8).write(to: url)

        let probe = BookLocationResolver.Probe(
            itemID: UUID(), bookmark: Data(repeating: 0xAB, count: 256),
            recordedPath: url.path, volumeUUID: nil
        )
        #expect(BookLocationResolver.resolve(probe, mountedVolumeUUIDs: mounted) == .unreachable)
    }

    @Test("UUIDを持たない古い行は、/Volumes の下かどうかでボリュームの有無を見る")
    func legacyRowsFallBackToThePath() throws {
        let workspace = try TemporaryDirectory("location-legacy")
        let url = workspace.file("a.cbz")
        try Data("a".utf8).write(to: url)
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        try FileManager.default.removeItem(at: url)

        // 起動ボリューム上の本(= /Volumes の下ではない)。ボリュームは必ず付いている。
        let onBootVolume = BookLocationResolver.Probe(
            itemID: UUID(), bookmark: bookmark, recordedPath: url.path, volumeUUID: nil
        )
        #expect(BookLocationResolver.resolve(onBootVolume, mountedVolumeUUIDs: []) == .missing)

        // 付いていない外付けを指すパス。UUIDが無くても消さない側に倒れる。
        let onAbsentVolume = BookLocationResolver.Probe(
            itemID: UUID(), bookmark: bookmark,
            recordedPath: "/Volumes/NoSuchVolume-\(UUID().uuidString)/book.cbz", volumeUUID: nil
        )
        #expect(
            BookLocationResolver.resolve(onAbsentVolume, mountedVolumeUUIDs: []) == .volumeUnavailable
        )
    }

    @Test("マウント中のボリュームのUUIDが数えられる(サンドボックス下でも)")
    func mountedVolumeUUIDsAreAvailable() throws {
        let workspace = try TemporaryDirectory("location-mounted")
        let url = workspace.file("a.cbz")
        try Data("a".utf8).write(to: url)
        let identifier = try #require(FileNodeIdentifier.current(for: url))
        let volumeUUID = try #require(identifier.volumeUUID)
        // いま書いたファイルがあるボリュームは、当然マウント一覧に居る。ここが空振りすると
        // 「ボリュームが付いていない」と誤判定し、掃除が永久に何も見つけなくなる。
        #expect(BookLocationResolver.mountedVolumeUUIDs().contains(volumeUUID))
    }
}
