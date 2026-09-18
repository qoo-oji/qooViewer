import Foundation
import Testing

@testable import qooViewer

/// ビューアで開いている本は、ファイルブラウザから名前の変更・移動・ゴミ箱をさせない(FileBrowserOperations.refusesBecauseOpenInViewer。
/// 2026-09-19 の監査の H4)。
@MainActor
struct FileBrowserOpenBookGuardTests {
    @Test("当たるのは、開いている本そのもの・その祖先・その中身。隣の項目は当たらない")
    func conflictCoversTheBookItsAncestorsAndItsContents() {
        let open = ["/v/shelf/book"]
        func conflict(_ path: String) -> Bool {
            FileBrowserOperations.openBookConflict(among: [URL(fileURLWithPath: path)], openBookPaths: open) != nil
        }
        #expect(conflict("/v/shelf/book"))
        #expect(conflict("/v/shelf"), "フォルダごと動かすと中の開いている本も動く")
        #expect(conflict("/v/shelf/book/001.jpg"), "フォルダの本の中の画像")
        #expect(!conflict("/v/shelf/book2"))
        #expect(!conflict("/v/other"))
        #expect(FileBrowserOperations.openBookConflict(among: [URL(fileURLWithPath: "/v/shelf")], openBookPaths: []) == nil)
    }

    @Test("開いている本の名前の変更・ゴミ箱・移動は断って伝える。コピーは通す。閉じれば通る")
    func operationsOnAnOpenBookAreRefused() async throws {
        let fixture = try FileSystemChangeTests.Fixture("open-book-guard")
        let state = fixture.makeState()
        let presenter = try #require(state.operations.presenter as? FileBrowserOperationsTests.ScriptedPresenter)
        state.navigate(to: fixture.root)
        await state.settle()
        let book = try #require(state.entries.first { $0.url.lastPathComponent == "a.txt" })
        // 開いている本の一覧は箱に入れて差し替える(閉包が捕まえた変数を後から書き換えると、CI のコンパイラは
        // 「sendable な閉包が捕まえた後の変更」として断る)。
        let open = OpenPaths([book.url.path])
        state.operations.openBookPaths = { open.paths }

        await state.operations.rename(book, to: "b.txt").value
        await state.operations.moveToTrash([book]).value
        await state.operations.transfer([book.url], to: fixture.inner, isMove: true).value
        #expect(FileManager.default.fileExists(atPath: book.url.path), "開いている本が動いた")
        #expect(presenter.problems.count == 3)

        await state.operations.transfer([book.url], to: fixture.inner, isMove: false).value
        #expect(FileManager.default.fileExists(atPath: fixture.inner.appendingPathComponent("a.txt").path), "コピーまで断った")
        #expect(presenter.problems.count == 3)

        // 開いている本を含むフォルダごとも断る。
        let folder = try #require(state.entries.first { $0.url.lastPathComponent == "inner" })
        open.paths = [fixture.leaf.appendingPathComponent("x.txt").path]
        await state.operations.rename(folder, to: "renamed").value
        #expect(FileManager.default.fileExists(atPath: fixture.inner.path))
        #expect(presenter.problems.count == 4)

        open.paths = []
        await state.operations.rename(book, to: "b.txt").value
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("b.txt").path))
        #expect(presenter.problems.count == 4)
    }

    @MainActor
    private final class OpenPaths {
        var paths: [String]
        init(_ paths: [String]) { self.paths = paths }
    }
}
