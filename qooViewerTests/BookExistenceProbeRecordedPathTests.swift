import Foundation
import Testing

@testable import qooViewer

/// メタデータの編集ウインドウが使う「記録したパスに今、本があるか」(`BookExistenceProbe.evaluateAtRecordedPath`)。
///
/// ここが「ある」と言いすぎると、名前を変えた本の古いパスや、本ではないフォルダ(棚)が、メタデータを削除しても
/// 窓を開くたびに登録し直される(2026-09-22、利用者の報告)。
struct BookExistenceProbeRecordedPathTests {
    private func probe(_ path: String, bookmarkOf url: URL? = nil) throws -> BookExistenceProbe {
        let bookmarks = try url.map {
            [try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)]
        } ?? []
        return BookExistenceProbe(bookID: path, bookmarkCandidates: bookmarks, isPathCovered: true)
    }

    @Test("記録どおりの場所にある本のファイルは exists")
    func anExistingFileExists() throws {
        let workspace = try TemporaryDirectory("probe-exists")
        let url = workspace.file("a.cbz")
        try Data("a".utf8).write(to: url)

        #expect(try probe(url.path).evaluateAtRecordedPath() == .exists)
        #expect(try probe(url.path, bookmarkOf: url).evaluateAtRecordedPath() == .exists)
    }

    @Test("改名した本の古いパスは missing(ブックマークが新しい名前を追っても)")
    func theOldPathOfARenamedFileIsMissing() throws {
        let workspace = try TemporaryDirectory("probe-renamed")
        let original = workspace.file("before.cbz")
        try Data("a".utf8).write(to: original)
        let probe = try probe(original.path, bookmarkOf: original)
        try FileManager.default.moveItem(at: original, to: workspace.file("after.cbz"))

        // 素の evaluate は移動を追って exists と答える(本ごとの保存データを削除ウインドウはそれでよい)。
        #expect(probe.evaluate() == .exists)
        #expect(probe.evaluateAtRecordedPath() == .missing)
        // 付け替え先(保存データを新しい名前へ移すのに使う)。
        #expect(probe.locateAtRecordedPath().movedTo?.hasSuffix("/after.cbz") == true)
    }

    @Test("記録どおりの場所にある本には付け替え先が無い")
    func anUnmovedFileHasNoRelocation() throws {
        let workspace = try TemporaryDirectory("probe-unmoved")
        let url = workspace.file("a.cbz")
        try Data("a".utf8).write(to: url)

        #expect(try probe(url.path, bookmarkOf: url).locateAtRecordedPath().movedTo == nil)
    }

    @Test("画像フォルダは exists、本が並んでいるだけのフォルダ(棚)は missing")
    func onlyImageFoldersAreBooks() throws {
        let workspace = try TemporaryDirectory("probe-folders")
        let imageFolder = try workspace.directory("images")
        try Data("a".utf8).write(to: imageFolder.appendingPathComponent("001.jpg"))
        let shelf = try workspace.directory("shelf")
        try Data("a".utf8).write(to: shelf.appendingPathComponent("01.cbz"))
        try Data("a".utf8).write(to: shelf.appendingPathComponent("02.cbz"))

        #expect(try probe(imageFolder.path).evaluateAtRecordedPath() == .exists)
        #expect(try probe(shelf.path).evaluateAtRecordedPath() == .missing)
        #expect(try probe(shelf.path, bookmarkOf: shelf).evaluateAtRecordedPath() == .missing)
    }

    @Test("許可済みの場所で見つからなければ missing、許可の外なら unknown")
    func aMissingPathDependsOnCoverage() throws {
        let workspace = try TemporaryDirectory("probe-missing")
        let path = workspace.file("gone.cbz").path

        #expect(BookExistenceProbe(bookID: path, bookmarkCandidates: [], isPathCovered: true)
            .evaluateAtRecordedPath() == .missing)
        #expect(BookExistenceProbe(bookID: path, bookmarkCandidates: [], isPathCovered: false)
            .evaluateAtRecordedPath() == .unknown)
    }

    @Test("繋がっていないボリュームの上の本は、許可済みの場所でも missing と言わない(NAS の電源が落ちているとき)")
    func aBookOnAnUnmountedVolumeIsUnknown() {
        // マウントされていない /Volumes の下(マウントの一覧だけで判定するので、パスには触らない)。
        let path = "/Volumes/qooViewerTestsNotMounted-\(UUID().uuidString)/book.cbz"
        let probe = BookExistenceProbe(bookID: path, bookmarkCandidates: [], isPathCovered: true)
        #expect(probe.evaluate() == .unknown)
        #expect(probe.evaluateAtRecordedPath() == .unknown)
    }

    @Test("裏の解決は繋がっていないボリュームへ繋ぎに行かず画面も出さない、開く操作は繋ぎに行く")
    func backgroundResolutionNeverMounts() {
        let background = BookmarkResolution.options(for: .background)
        #expect(background.contains(.withSecurityScope))
        #expect(background.contains(.withoutMounting))
        #expect(background.contains(.withoutUI))
        let userOpen = BookmarkResolution.options(for: .userOpen)
        #expect(userOpen.contains(.withSecurityScope))
        #expect(!userOpen.contains(.withoutMounting))
    }
}
