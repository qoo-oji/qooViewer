import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

@testable import qooViewer

/// StackNest が manifest に付ける本の同一性(`bookIdentity`)。付けない StackNest(古い版)では nil。
@MainActor
struct StackNestBookIdentityTests {
    @Test("manifest の同一性を本が持つ(付けない StackNest では nil)")
    func bookCarriesTheIdentity() async throws {
        let fixture = try StackNestTestBook(pageCount: 3, bookIdentity: "sn1-fixture")
        defer { fixture.close() }
        let book = try await FixtureBook.load(fixture.referenceURL)
        #expect(book.stackNestBookIdentity == "sn1-fixture")
        let older = try StackNestTestBook(pageCount: 3, label: "stacknest-older")
        defer { older.close() }
        #expect(try await FixtureBook.load(older.referenceURL).stackNestBookIdentity == nil)
    }
}

/// 並びを持つ StackNest の本(参照ファイルをまとめて落としたときなど)。置き場所の無い本でも、並びがあれば
/// 前の本・次の本をたどれる(AppState.hasAdjacentBooks・openSibling)。
@MainActor
struct StackNestHandoffSequenceTests {
    @Test("並びのある StackNest の本は「次の本へ」で並びの次の参照ファイルを開き、並びの無い本は今までどおり断る")
    func nextBookFollowsTheSequence() async throws {
        let first = try StackNestTestBook(pageCount: 3, label: "stacknest-seq-1")
        defer { first.close() }
        let second = try StackNestTestBook(pageCount: 2, label: "stacknest-seq-2", fileName: "Second Book.stacknestbook")
        defer { second.close() }
        let library = try InMemoryLibrary(label: "stacknest-sequence")
        defer { library.close() }
        let suite = PreferencesSuite(label: "stacknest-sequence")
        let preferences = suite.makePreferences()
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = preferences
        state.favoritesStore = library.favorites
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        let recentFiles = RecentFilesStore(defaults: suite.defaults)
        state.recentFiles = recentFiles

        // 並びの無い本: 前後の本は無い。
        state.open(request: BookOpenRequest(first.referenceURL))
        await state.openTask?.value
        #expect(state.bookSequence == nil)
        #expect(!state.hasAdjacentBooks)

        // 組で渡された本(先頭を開き、2 冊を並びにする)。
        let sequence = try #require(BookSequence(
            entries: [.file(path: first.referenceURL.path), .file(path: second.referenceURL.path)], position: 0))
        state.open(request: BookOpenRequest(first.referenceURL, sequence: sequence))
        await state.openTask?.value
        #expect(state.bookSequence == sequence)
        #expect(state.hasAdjacentBooks)
        state.openSibling(after: first.referenceURL)
        let deadline = ContinuousClock.now + .seconds(20)
        while state.currentBook?.sourceURL != second.referenceURL, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            await state.openTask?.value
        }
        #expect(state.currentBook?.sourceURL == second.referenceURL)
        #expect(state.bookSequence?.position == 1)
        #expect(second.manifestRequestCount == 1)
        withExtendedLifetime((preferences, recentFiles)) {}
    }

    private func makeState(label: String) throws -> (AppState, InMemoryLibrary, AnyObject) {
        let library = try InMemoryLibrary(label: label)
        let suite = PreferencesSuite(label: label)
        let preferences = suite.makePreferences()
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = preferences
        state.favoritesStore = library.favorites
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        let recentFiles = RecentFilesStore(defaults: suite.defaults)
        state.recentFiles = recentFiles
        return (state, library, [preferences, recentFiles] as NSArray)
    }

    @Test("並びの途中の StackNest の本が開けなければ(StackNest が断る)、飛ばして次の本を開く")
    func nextBookSkipsAStackNestBookThatFails() async throws {
        let first = try StackNestTestBook(pageCount: 2, label: "stacknest-skip-1")
        defer { first.close() }
        let broken = try StackNestTestBook(pageCount: 2, label: "stacknest-skip-2", fileName: "Broken.stacknestbook")
        defer { broken.close() }
        let third = try StackNestTestBook(pageCount: 2, label: "stacknest-skip-3", fileName: "Third.stacknestbook")
        defer { third.close() }
        broken.server.respond(.manifest, with: .status(404))
        let (state, library, keep) = try makeState(label: "stacknest-skip")
        defer { library.close() }
        let sequence = try #require(BookSequence(
            entries: [first, broken, third].map { .file(path: $0.referenceURL.path) }, position: 0))
        state.open(request: BookOpenRequest(first.referenceURL, sequence: sequence))
        await state.openTask?.value
        #expect(state.currentBook?.sourceURL == first.referenceURL)

        state.openSibling(after: first.referenceURL)
        let deadline = ContinuousClock.now + .seconds(20)
        while state.currentBook?.sourceURL != third.referenceURL, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            await state.openTask?.value
        }
        #expect(state.currentBook?.sourceURL == third.referenceURL)
        #expect(state.bookSequence?.position == 2)
        withExtendedLifetime(keep) {}
    }

    @Test(
        "並びをたどるときに飛ばすのは、その本だけの失敗(StackNest 全体の失敗では止まる)",
        arguments: [
            (StackNestViewerError.Code.bookNotFound, true), (.expired, true), (.unauthorized, true), (.invalidResponse, true),
            (.cannotConnect, false), (.libraryLocked, false), (.hostNotAllowed, false), (.remoteUnavailable, false),
        ] as [(StackNestViewerError.Code, Bool)])
    func skipsOnlyPerBookFailures(code: StackNestViewerError.Code, skips: Bool) {
        let reference = URL(fileURLWithPath: "/tmp/x/Book.stacknestbook")
        let error = StackNestOpenError(error: StackNestViewerError(code))
        #expect(AppState.skipsWhileStepping(error, book: reference, inSequence: true) == skips)
        #expect(!AppState.skipsWhileStepping(error, book: reference, inSequence: false))
        #expect(!AppState.skipsWhileStepping(CancellationError(), book: reference, inSequence: true))
        #expect(!AppState.skipsWhileStepping(error, book: URL(fileURLWithPath: "/tmp/x/Book.cbz"), inSequence: true))
    }
}
