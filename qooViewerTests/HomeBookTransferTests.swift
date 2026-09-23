import AppKit
import Foundation
import Testing

@testable import qooViewer

/// ホームの本のコピーと、右クリックの「コレクションを作成」「コレクションに登録」の中身(Views/Welcome/HomeBookTransfer.swift)。
@MainActor
struct HomeBookTransferTests {
    private let english = Locale(identifier: "en")

    @Test("コピーは本の実体のファイル URL をペーストボードへ書く(Finder へ貼るとコピーになる)")
    func copyWritesFileURLs() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        // 実在する本にする(無いパスはサンドボックスが読み取りの許可を付けられず、ログが出る)。
        let temporary = try TemporaryDirectory("home-book-copy")
        let archive = temporary.url.appendingPathComponent("Book A.zip")
        let folder = temporary.url.appendingPathComponent("Book B", isDirectory: true)
        try Data().write(to: archive)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = [archive, folder]

        HomeBookPasteboard.copy(urls, fileBrowser: nil, pasteboard: pasteboard)

        let read = try #require(
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        )
        #expect(read.map(\.path) == urls.map(\.path))
        // 前の中身は残さない。
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("本が無ければペーストボードに触らない")
    func copyNothingLeavesPasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("kept", forType: .string)

        HomeBookPasteboard.copy([], fileBrowser: nil, pasteboard: pasteboard)

        #expect(pasteboard.string(forType: .string) == "kept")
    }

    @Test("「コレクションを作成」はライブラリが 1 つならサブメニューにしない。複数ならライブラリごとの項目で、押すとそのライブラリへ")
    func createMenuNodes() throws {
        let first = UUID()
        let second = UUID()
        let one = [CollectionMenuLibrary(id: first, name: "Library", collections: [])]
        #expect(CollectionMenuLibrary.createMenuNodes(for: one, create: { _ in }) == nil)

        var created: UUID?
        let two = one + [CollectionMenuLibrary(id: second, name: "Other", collections: [])]
        let nodes = try #require(CollectionMenuLibrary.createMenuNodes(for: two, create: { created = $0 }))
        #expect(nodes.count == 2)
        guard case .item(let title, _, let isEnabled, let action) = nodes[1] else {
            Issue.record("item expected")
            return
        }
        #expect(title == "Other")
        #expect(isEnabled)
        action()
        #expect(created == second)
    }

    @Test("「コレクションに登録」はライブラリが 1 つなら 1 段、複数ならライブラリのサブメニュー。空のライブラリは淡色の「コレクションがありません」")
    func addMenuNodes() throws {
        let collectionID = UUID()
        let library = CollectionMenuLibrary(id: UUID(), name: "Library", collections: [(collectionID, "Shelf")])
        var added: UUID?
        let flat = CollectionMenuLibrary.addMenuNodes(for: [library], locale: english, add: { added = $0 })
        #expect(flat.count == 1)
        guard case .item(let title, _, _, let action) = flat[0] else {
            Issue.record("item expected")
            return
        }
        #expect(title == "Shelf")
        action()
        #expect(added == collectionID)

        let empty = CollectionMenuLibrary(id: UUID(), name: "Empty", collections: [])
        let nested = CollectionMenuLibrary.addMenuNodes(for: [library, empty], locale: english, add: { _ in })
        #expect(nested.count == 2)
        guard case .submenu(let name, _, let children) = nested[1], case .item(_, _, let isEnabled, _) = children.first else {
            Issue.record("submenu expected")
            return
        }
        #expect(name == "Empty")
        #expect(children.count == 1)
        #expect(!isEnabled)
    }

    // MARK: - 機能をまたぐ項目(2026-09-23)

    @Test("ホームの外からの「コレクションに登録」は、ライブラリ機能が OFF なら何もせず、ON なら登録して結果を知らせる")
    func collectionAddingFollowsTheLibraryFlag() async throws {
        let library = try InMemoryLibrary(label: "cross-feature-add")
        defer { library.close() }
        let suite = PreferencesSuite(label: "cross-feature-add")
        let preferences = suite.makePreferences()
        let temporary = try TemporaryDirectory("cross-feature-add")
        let first = temporary.url.appendingPathComponent("First.zip")
        let second = temporary.url.appendingPathComponent("Second.zip")
        try Data().write(to: first)
        try Data().write(to: second)
        let target = try #require(library.collections.libraries.first)
        let pending = try #require(CollectionStore.makePendingItem(for: first))
        let collection = try #require(library.collections.createCollection(name: "Shelf", in: target, items: [pending]))
        let context = CollectionAddingContext(collectionStore: library.collections, coverExtractor: nil, preferences: preferences)
        var messages: [String] = []

        preferences.libraryFeatureEnabled = false
        #expect(context.add([second], to: collection.id) { messages.append($0) } == nil)

        preferences.libraryFeatureEnabled = true
        await context.add([second], to: collection.id) { messages.append($0) }?.value
        #expect(collection.items.count == 2)
        #expect(messages.count == 1)
    }

    @Test("メニューバーの項目は、スマートライブラリで 1 冊だけ選んでいる本も相手にする(束・複数・ほかのモードでは相手が無い)")
    func smartSelectionIsAMenuTarget() {
        var state = HomeMenuState(isShown: true, mode: .smart, smartBookPaths: ["/tmp/qoo-sample/Book.zip"])
        #expect(state.singleSmartBookTarget == "/tmp/qoo-sample/Book.zip")
        #expect(state.hasSingleBookTarget)
        state.smartBookPaths.append("/tmp/qoo-sample/Other.zip")
        #expect(state.singleSmartBookTarget == nil)
        state.smartBookPaths = ["/tmp/qoo-sample/Book.zip"]
        state.mode = .browser
        #expect(state.singleSmartBookTarget == nil)
        state.mode = .smart
        state.isShown = false
        #expect(!state.hasSingleBookTarget)
    }
}
