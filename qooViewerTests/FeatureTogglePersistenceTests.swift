import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザ・ライブラリ・スマートライブラリの ON/OFF(8 通り)で、読み方向・読書位置・ブックマークの保存と復元が
/// 変わらないこと(2026-09-25、利用者の指示)。読書位置の記録は機能の ON/OFF に関わらず残す約束(CLAUDE.md のライブラリ機能の
/// ON/OFF の段落 ―― 保存データを正しく保つ仕事は止めない)。
///
/// 本を開く本来の入口(`AppState.open`)から開き、その本のビューアで左右を切り替えてブックマークを付け、閉じてから
/// もう一度 `AppState.open` で開き直す。フォルダの本・書庫の本・ネットワーク上とみなした書庫の本(読み込み層を通る経路)で見る。
@MainActor
struct FeatureTogglePersistenceTests {
    nonisolated enum Kind: String, CaseIterable, Sendable {
        case folder, archive, remoteArchive
    }

    nonisolated struct Flags: Sendable, CustomStringConvertible {
        let library: Bool
        let fileBrowser: Bool
        let smart: Bool
        var description: String { "L=\(library) F=\(fileBrowser) S=\(smart)" }

        static let all: [Flags] = [false, true].flatMap { library in
            [false, true].flatMap { fileBrowser in
                [false, true].map { smart in Flags(library: library, fileBrowser: fileBrowser, smart: smart) }
            }
        }
    }

    @Test("3 つの機能の ON/OFF 8 通りで、読み方向・読書位置・ブックマークが開き直しても残る",
          arguments: Flags.all, Kind.allCases)
    func readingStateSurvivesEveryFeatureCombination(flags: Flags, kind: Kind) async throws {
        let library = try InMemoryLibrary(label: "feature-persistence")
        defer { library.close() }
        let suite = PreferencesSuite(label: "feature-persistence")
        let preferences = suite.makePreferences()
        preferences.libraryFeatureEnabled = flags.library
        preferences.fileBrowserFeatureEnabled = flags.fileBrowser
        preferences.smartLibraryFeatureEnabled = flags.smart
        preferences.reopenBehavior = .resume
        let temporary = try TemporaryDirectory("feature-persistence")

        let pages = (1...6).map { FixtureFolder.Page(String(format: "p%02d.png", $0), number: UInt8($0)) }
        let url: URL
        switch kind {
        case .folder:
            url = temporary.file("book")
            try FixtureFolder.make(at: url, pages: pages)
        case .archive, .remoteArchive:
            let pagesFolder = temporary.file("pages")
            try FixtureFolder.make(at: pagesFolder, pages: pages)
            var builder = ZipFixtureBuilder()
            for page in pages {
                builder.add(page.relativePath, try Data(contentsOf: pagesFolder.appendingPathComponent(page.relativePath)), stored: true)
            }
            url = temporary.file("book.cbz")
            try builder.write(to: url)
        }
        if kind == .remoteArchive { NetworkVolumeReading.treatAsRemoteForTesting(temporary.url) }
        defer { if kind == .remoteArchive { NetworkVolumeReading.endTreatingAsRemoteForTesting(temporary.url) } }

        func makeAppState() -> AppState {
            let state = AppState(isPrivateWindow: false, usesPageListCache: false)
            state.preferences = preferences
            state.favoritesStore = library.favorites
            state.bookmarkStore = library.bookmarks
            state.layoutStore = library.layouts
            state.metadataStore = library.metadata
            // AppStores と同じく、コレクションのストアはライブラリ機能の ON/OFF に関わらず渡す(付け替えは止めない約束)。
            state.collectionStore = library.collections
            return state
        }
        func openViewer(_ state: AppState) async throws -> ViewerViewModel {
            state.open(request: BookOpenRequest(url))
            await state.openTask?.value
            let book = try #require(state.currentBook, "\(flags) \(kind): 開けなかった")
            let viewer = ViewerViewModel(
                book: book, modelContext: library.context, preferences: preferences,
                layoutStore: library.layouts, metadataStore: library.metadata,
                skipsPersistence: false, usesDiskCaches: false
            )
            await viewer.settle()
            return viewer
        }

        let first = try await openViewer(makeAppState())
        first.toggleReadingDirection()
        first.jump(toPageIndex: 3)
        first.addBookmark()
        await first.settle()
        let toggled = first.readingDirection
        first.flushPendingSave()
        first.releaseResources()

        let reopened = try await openViewer(makeAppState())
        defer { reopened.releaseResources() }
        #expect(reopened.readingDirection == toggled, "\(flags) \(kind)")
        #expect(reopened.currentIndex == 3, "\(flags) \(kind)")
        #expect(reopened.bookmarks.count == 1, "\(flags) \(kind)")
    }
}
