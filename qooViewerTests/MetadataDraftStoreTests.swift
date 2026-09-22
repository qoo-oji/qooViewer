import Foundation
import QooMetaKit
import Testing

@testable import qooViewer

/// メタデータの編集ウインドウの下書きのファイル(`MetadataDraftStore`)。2026-09-22 の監査で直した 2 つの約束を見る:
/// 読めないファイルは写しを残してから使う(黙って上書きしない)・一覧に無い本の分も捨てない(後者は捨てる口を無くした)。
@MainActor
struct MetadataDraftStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewerTests.drafts.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("drafts.json")
    }

    private let draft = MetadataDraftStore.Draft(
        confirmation: .notInSeries(fields: ConfirmedFields([.title: ["架空の題"]])), preset: nil)

    @Test("保存して読み直すと、同じ下書きが戻る")
    func roundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MetadataDraftStore(url: url)
        store.set(draft, for: "/架空/本.zip")
        store.save()
        #expect(MetadataDraftStore(url: url).drafts == ["/架空/本.zip": draft])
    }

    @Test("読めないファイルは隣へ写しを残し、次の保存で中身を失わない")
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

        store.set(draft, for: "/架空/別の本.zip")
        store.save()
        #expect(MetadataDraftStore(url: url).drafts == ["/架空/別の本.zip": draft])
    }
}
