import Foundation
import QooMetaKit
import Testing

@testable import qooViewer

/// メタデータの編集ウインドウの下書きのファイル(`MetadataDraftStore`)。2026-09-22 から、解析した本はすべて DB に登録するので、
/// 下書きは起動時に DB へ移すだけになった。見る約束: 移し方(行の無い本はロックせずに作る・ロックした行は変えない)と、
/// 読めないファイルは写しを残す(黙って消さない)。
@MainActor
struct MetadataDraftStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewerTests.drafts.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("drafts.json")
    }

    private let draft = MetadataDraftStore.Draft(
        confirmation: .notInSeries(fields: ConfirmedFields([.title: ["架空の題"]])), preset: nil)

    @Test("下書きは DB へ移り(行の無い本はロックせずに、ロックした行は変えずに)、ファイルは消える")
    func draftsMoveIntoTheDatabase() throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(["/架空/本.zip": draft, "/架空/ロックした本.zip": draft]).write(to: url)
        library.metadata.upsert(bookID: "/架空/ロックした本.zip", values: BookMetadataValues(title: "ロックした題"))

        let store = MetadataDraftStore(url: url)
        store.migrate(into: library.metadata, rules: library.metadataRules.rules)
        let moved = try #require(library.metadata.record(forBookID: "/架空/本.zip"))
        #expect(!moved.isLocked)
        #expect(moved.values.title == "架空の題")
        #expect(moved.edits == draft.confirmation)
        #expect(library.metadata.record(forBookID: "/架空/ロックした本.zip")?.values.title == "ロックした題")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("読めないファイルは隣へ写しを残す")
    func unreadableFileIsKeptAside() throws {
        let url = temporaryURL()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unreadable = Data(#"{"/架空/本.zip": {"confirmation": {"未来の形": {}}}}"#.utf8)
        try unreadable.write(to: url)

        let store = MetadataDraftStore(url: url)
        #expect(store.drafts.isEmpty)
        #expect(!store.holdsSaving)
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("drafts.unreadable-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent(try #require(kept.first))) == unreadable)
    }
}
