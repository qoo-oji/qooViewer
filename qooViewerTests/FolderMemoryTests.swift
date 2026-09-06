import Foundation
import Testing

@testable import qooViewer

/// セキュリティスコープ付きブックマークで場所を覚えておく 2 つの仕組み。
///
/// - `LastUsedFolderMemory`(Services/): 保存パネルが最後に開いたフォルダ、および「固定の保存先」。
/// - `LastActiveBookStore`(ViewModels/): 「起動時に前回開いていた本を自動的に開く」ための 1 冊。
///
/// どちらも**単なるパスの文字列では足りない**のが要点 ―― サンドボックスでは、次の起動でその
/// パスへアクセスする権限が無い。保存されるのがブックマークであること、そして解決が実在確認まで
/// 行うことを固定する。保存先はその場限りの suite(`PreferencesSuite`)に向ける。
@MainActor
struct FolderMemoryTests {
    private struct Fixture {
        let temporary: TemporaryDirectory
        let suite: PreferencesSuite
        let alpha: URL
        let beta: URL

        init(_ label: String) throws {
            temporary = try TemporaryDirectory(label)
            suite = PreferencesSuite(label: label)
            alpha = try temporary.directory("alpha")
            beta = try temporary.directory("beta")
        }
    }

    // MARK: - LastUsedFolderMemory

    private func memory(_ fixture: Fixture, key: String = "test.folder") -> LastUsedFolderMemory {
        LastUsedFolderMemory(defaultsKey: key, defaults: fixture.suite.defaults)
    }

    @Test("何も覚えていなければ nil(初回はパネルが OS の既定の場所から始まる)")
    func afreshMemoryIsEmpty() throws {
        let fixture = try Fixture("folder-memory-empty")
        let subject = memory(fixture)
        #expect(subject.lastFolder() == nil)
        #expect(subject.lastFolderPath() == nil)
    }

    @Test("覚えたフォルダを解決して返す")
    func aRememberedFolderComesBack() throws {
        let fixture = try Fixture("folder-memory-round")
        let subject = memory(fixture)
        subject.remember(fixture.alpha)
        #expect(subject.lastFolder()?.path == fixture.alpha.path)
    }

    @Test("保存されるのはパスの文字列ではなくブックマーク(サンドボックスで次の起動でも開けるように)")
    func whatIsStoredIsABookmark() throws {
        let fixture = try Fixture("folder-memory-bookmark")
        let subject = memory(fixture, key: "test.bookmarkShape")
        subject.remember(fixture.alpha)

        let stored = fixture.suite.storedDomain
        let data = try #require(stored["test.bookmarkShape"] as? Data)
        // ブックマークとして解決でき、同じ場所を指す。
        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        #expect(resolved.path == fixture.alpha.path)
    }

    @Test("表示用のパスは別のキーに、ブックマークを解決せずに読めるよう控える")
    func theDisplayPathIsStoredSeparately() throws {
        let fixture = try Fixture("folder-memory-path")
        let subject = memory(fixture, key: "test.withPath")
        subject.remember(fixture.alpha)

        // 未接続のボリュームで秒単位ブロックしうる解決を、環境設定の画面のためだけに走らせない。
        #expect(subject.lastFolderPath() == fixture.alpha.path)
        #expect(fixture.suite.storedDomain["test.withPath.path"] as? String == fixture.alpha.path)
        #expect(subject.defaultsKeys == ["test.withPath", "test.withPath.path"])
    }

    @Test("覚え直すと上書きされる")
    func rememberingAgainReplacesIt() throws {
        let fixture = try Fixture("folder-memory-replace")
        let subject = memory(fixture)
        subject.remember(fixture.alpha)
        subject.remember(fixture.beta)
        #expect(subject.lastFolder()?.path == fixture.beta.path)
        #expect(subject.lastFolderPath() == fixture.beta.path)
    }

    @Test("忘れると 2 つのキーが両方消える(「初期設定に戻す」がここまで届くように)")
    func forgettingClearsBothKeys() throws {
        let fixture = try Fixture("folder-memory-forget")
        let subject = memory(fixture, key: "test.forgetting")
        subject.remember(fixture.alpha)
        subject.forget()

        #expect(subject.lastFolder() == nil)
        #expect(subject.lastFolderPath() == nil)
        #expect(fixture.suite.storedDomain["test.forgetting"] == nil)
        #expect(fixture.suite.storedDomain["test.forgetting.path"] == nil)
    }

    @Test("用途ごとに別のキーで、お互いに干渉しない")
    func eachPurposeKeepsItsOwnFolder() throws {
        let fixture = try Fixture("folder-memory-keys")
        let epub = memory(fixture, key: "test.epub")
        let pdf = memory(fixture, key: "test.pdf")
        epub.remember(fixture.alpha)
        pdf.remember(fixture.beta)

        #expect(epub.lastFolder()?.path == fixture.alpha.path)
        #expect(pdf.lastFolder()?.path == fixture.beta.path)
        epub.forget()
        #expect(epub.lastFolder() == nil)
        #expect(pdf.lastFolder()?.path == fixture.beta.path)
    }

    @Test("出荷時の用途が使うキーは、保存済みの設定の識別子なので変えられない")
    func theShippedKeysAreFrozen() {
        #expect(LastUsedFolderMemory.libraryIO.defaultsKeys
                == ["qooViewer.pref.lastLibraryIOFolderBookmark",
                    "qooViewer.pref.lastLibraryIOFolderBookmark.path"])
        #expect(LastUsedFolderMemory.epubExport.defaultsKeys.first
                == "qooViewer.pref.lastEpubExportFolderBookmark")
        #expect(LastUsedFolderMemory.pdfExport.defaultsKeys.first
                == "qooViewer.pref.lastPdfExportFolderBookmark")
        #expect(LastUsedFolderMemory.cbzExport.defaultsKeys.first
                == "qooViewer.pref.lastCbzExportFolderBookmark")
    }

    @Test("「固定の保存先」はパネルの記憶とは別のキー(パネル操作で黙って変わらない)")
    func theFixedDestinationDoesNotShareTheePanelsKey() {
        for format in BookExportFormat.allCases {
            let fixed = LastUsedFolderMemory.fixedExportFolder(format).defaultsKeys
            #expect(fixed.first == "qooViewer.pref.fixedExportFolderBookmark.\(format.rawValue)")
            #expect(!LastUsedFolderMemory.epubExport.defaultsKeys.contains(fixed[0]))
            #expect(!LastUsedFolderMemory.pdfExport.defaultsKeys.contains(fixed[0]))
            #expect(!LastUsedFolderMemory.cbzExport.defaultsKeys.contains(fixed[0]))
        }
    }

    // MARK: - LastActiveBookStore

    @Test("何も記録していなければ nil(前回ウェルカム画面なら次回もウェルカム画面)")
    func noRecordedBookResolvesToNil() throws {
        let fixture = try Fixture("last-book-empty")
        #expect(LastActiveBookStore.resolve(defaults: fixture.suite.defaults) == nil)
    }

    @Test("記録した本を解決して返す")
    func aRecordedBookComesBack() throws {
        let fixture = try Fixture("last-book-round")
        LastActiveBookStore.record(url: fixture.alpha, defaults: fixture.suite.defaults)
        #expect(LastActiveBookStore.resolve(defaults: fixture.suite.defaults)?.path == fixture.alpha.path)
    }

    @Test("記録し直すと上書きされる(最後にアクティブだった 1 冊だけを持つ)")
    func recordingAgainReplacesTheBook() throws {
        let fixture = try Fixture("last-book-replace")
        LastActiveBookStore.record(url: fixture.alpha, defaults: fixture.suite.defaults)
        LastActiveBookStore.record(url: fixture.beta, defaults: fixture.suite.defaults)
        #expect(LastActiveBookStore.resolve(defaults: fixture.suite.defaults)?.path == fixture.beta.path)
    }

    @Test("消すと解決しなくなる(ウェルカム画面へ戻ったときに呼ぶ)")
    func clearingStopsTheResolution() throws {
        let fixture = try Fixture("last-book-clear")
        LastActiveBookStore.record(url: fixture.alpha, defaults: fixture.suite.defaults)
        LastActiveBookStore.clear(defaults: fixture.suite.defaults)
        #expect(LastActiveBookStore.resolve(defaults: fixture.suite.defaults) == nil)
    }

    @Test("記録した本が消えていたら nil(存在しない本を復元しようとしない)")
    func aDeletedBookResolvesToNil() throws {
        let fixture = try Fixture("last-book-deleted")
        LastActiveBookStore.record(url: fixture.alpha, defaults: fixture.suite.defaults)
        try FileManager.default.removeItem(at: fixture.alpha)
        #expect(LastActiveBookStore.resolve(defaults: fixture.suite.defaults) == nil)
    }

    @Test("保存されるのはブックマーク(パスの文字列では次の起動で開けない)")
    func theRecordedBookIsStoredAsABookmark() throws {
        let fixture = try Fixture("last-book-bookmark")
        LastActiveBookStore.record(url: fixture.alpha, defaults: fixture.suite.defaults)
        let stored = fixture.suite.storedDomain
        let data = try #require(stored["qooViewer.lastActiveBookBookmark"] as? Data)
        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        #expect(resolved.path == fixture.alpha.path)
    }
}
