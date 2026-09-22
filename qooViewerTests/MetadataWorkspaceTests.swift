import Foundation
import QooMetaKit
import Testing

@testable import qooViewer

/// メタデータの編集ウインドウの中身(`MetadataWorkspace`)を、メモリ内の SwiftData の上で通す(2026-09-21、
/// qooMeta への置き換え)。見るのは qooViewer で足した約束 ―― **並べた本はすべて登録**・直した欄もすぐ DB へ・
/// 取り消しも DB へ届く・ロックした本は規則を変えても変わらない・読み直しと削除(2026-09-22 の作り直し)。
/// qooMeta の計算そのものは qooMeta のテストが見ている。
///
/// 本の名前はすべて架空(docs/02「個人情報の流出防止」)。
@MainActor
struct MetadataWorkspaceTests {
    private func open(_ library: InMemoryLibrary, _ bookIDs: [String]) async -> MetadataWorkspace {
        let entries = bookIDs.map {
            MetadataWorkspace.Entry(bookID: $0, record: library.metadata.record(forBookID: $0))
        }
        let workspace = await MetadataWorkspace.open(entries, rules: library.metadataRules.rules)
        workspace.writeBack = { [metadata = library.metadata] in metadata.upsertAll($0) }
        await workspace.registerAll()
        return workspace
    }

    private let first = "/書庫/[架空工房] 月の庭 1.zip"
    private let second = "/書庫/[架空工房] 月の庭 2.zip"

    @Test("行の無い本は、ファイル名を qooMeta で読んだ値(シリーズと巻つき)で、ロックせずに DB へ登録される")
    func booksWithoutRowsAreRegisteredUnlocked() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])

        let row = try #require(workspace.row(second))
        #expect(row.metadata.authors == ["架空工房"])
        #expect(row.metadata.series == "月の庭")
        #expect(row.metadata.volume == "2")
        #expect(!row.isLocked)
        #expect(library.metadata.registeredBookIDs == [first, second])
        let stored = try #require(library.metadata.record(forBookID: second))
        #expect(!stored.isLocked)
        #expect(stored.values.series == "月の庭")
        #expect(stored.values.volume == "2")
        #expect(stored.edits == .none)
    }

    @Test("ロックした本の行は、実在する本なら識別子とブックマークを持つ(アプリの外で名前を変えても追えるように。2026-09-22 の監査)")
    func lockedRowsCarryTheBooksIdentity() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let temporary = try TemporaryDirectory("workspace-identity")
        let book = temporary.file("[架空工房] 月の庭 1.zip")
        try Data("a".utf8).write(to: book)
        let workspace = await open(library, [book.path])
        // 読みだけの行は手がかりを持たなくてよい(作り直せる)。
        #expect(library.metadata.metadata(forBookID: book.path)?.fileNodeIdentifier == nil)

        workspace.setLocked([book.path], true)
        await workspace.settle()

        let row = try #require(library.metadata.metadata(forBookID: book.path))
        #expect(row.fileNodeIdentifier == FileNodeIdentifier.current(for: book))
        #expect(row.bookmarkData != nil)
    }

    @Test("シリーズの無い巻だけを持つ登録済みの本は、巻が見え、鍵を外して掛け直しても巻が残る(2026-09-22 の監査)")
    func volumeWithoutSeriesSurvives() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let bookID = "/書庫/架空の物語 前篇.zip"
        library.metadata.upsert(bookID: bookID, author: "架空工房", title: "架空の物語", series: "", seriesIndex: "上")
        let workspace = await open(library, [bookID])

        #expect(workspace.row(bookID)?.metadata.volume == "上")
        workspace.setLocked([bookID], false)
        workspace.setLocked([bookID], true)
        await workspace.settle()
        #expect(library.metadata.metadata(forBookID: bookID)?.seriesIndex == "上")
        #expect(library.metadata.metadata(forBookID: bookID)?.series == "")
    }

    @Test("直した欄はすぐ DB に書かれ(取り消しも届く)、鍵を掛けると変わらなくなり、外しても値は残る")
    func editsAreStoredAndLockingFreezes() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])

        // 情報の欄は比べる単位(先頭の著者 + ジャンル)に入らないので、直してもシリーズの組は変わらない。
        workspace.set(.info, to: ["架空の付記"], for: [first])
        await workspace.settle()
        var stored = try #require(library.metadata.record(forBookID: first))
        #expect(stored.values.info == "架空の付記")
        #expect(!stored.isLocked)
        #expect(stored.edits.fields[.info] == ["架空の付記"])
        #expect(workspace.row(first)?.hasUnlockedEdits == true)

        workspace.undo()
        await workspace.settle()
        #expect(workspace.row(first)?.metadata.info == "")
        #expect(library.metadata.record(forBookID: first)?.values.info == "")
        workspace.redo()
        await workspace.settle()

        workspace.setLocked([first], true)
        await workspace.settle()
        stored = try #require(library.metadata.record(forBookID: first))
        #expect(stored.isLocked)
        #expect(stored.values.info == "架空の付記")
        #expect(stored.values.series == "月の庭")
        #expect(stored.values.volume == "1")
        #expect(workspace.isLocked(first))

        // 鍵が掛かっている間は直せない。
        workspace.set(.info, to: ["別の付記"], for: [first])
        await workspace.settle()
        #expect(library.metadata.record(forBookID: first)?.values.info == "架空の付記")

        workspace.setLocked([first], false)
        await workspace.settle()
        stored = try #require(library.metadata.record(forBookID: first))
        #expect(!stored.isLocked)
        #expect(stored.values.info == "架空の付記")
        #expect(workspace.row(first)?.metadata.info == "架空の付記")
    }

    @Test("シリーズ名の表記だけを直しても、同じ単位のほかの本の表記に戻らない(2026-09-22、利用者の報告)")
    func seriesSpellingEditIsKept() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])
        // 前の本が「月の庭」で確定している(ロック)。後ろの本だけを、比べる形が同じ別の表記に直す。
        workspace.setLocked([first], true)
        workspace.setSeries("月の 庭!", for: [second])
        await workspace.settle()

        #expect(workspace.row(second)?.metadata.series == "月の 庭!")
        #expect(workspace.row(first)?.metadata.series == "月の庭")
        #expect(library.metadata.record(forBookID: second)?.values.series == "月の 庭!")
    }

    @Test("巻数(並べ替え用)は直せて DB に残り、取り消せ、ロックしても変わらず、巻の表記を変えると外れる(2026-09-22)")
    func volumeSortCanBeEdited() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        var workspace = await open(library, [first, second])
        #expect(workspace.row(second)?.metadata.volumeSort == 2)

        workspace.setVolumeSort(1.5, for: [second])
        await workspace.settle()
        #expect(workspace.row(second)?.metadata.volumeSort == 1.5)
        #expect(workspace.row(second)?.metadata.volume == "2")
        #expect(workspace.row(second)?.hasConfirmedVolumeSort == true)
        #expect(workspace.row(second)?.hasUnlockedEdits == true)
        #expect(library.metadata.record(forBookID: second)?.values.volumeSort == 1.5)
        #expect(library.metadata.record(forBookID: second)?.edits.fields.volumeSort == 1.5)

        workspace.undo()
        await workspace.settle()
        #expect(workspace.row(second)?.metadata.volumeSort == 2)
        #expect(library.metadata.record(forBookID: second)?.values.volumeSort == 2)
        // `== .none` は Optional の nil と比べてしまうので、型を書く。
        #expect(library.metadata.record(forBookID: second)?.edits == QooMetaKit.Confirmation.none)
        workspace.redo()
        await workspace.settle()

        // ロックした本は、開き直しても直した数のまま。
        workspace.setLocked([second], true)
        await workspace.settle()
        workspace = await open(library, [first, second])
        #expect(workspace.row(second)?.metadata.volumeSort == 1.5)
        #expect(library.metadata.record(forBookID: second)?.values.volumeSort == 1.5)

        // 巻の表記を変えると、直した数は外れて表記から読み直す。
        workspace.setLocked([second], false)
        workspace.setVolumes("3", for: [second])
        await workspace.settle()
        #expect(workspace.row(second)?.metadata.volumeSort == 3)
        #expect(library.metadata.record(forBookID: second)?.edits.fields.volumeSort == nil)

        // 確定を外すと、表記から読んだ数に戻る。
        workspace.setVolumeSort(0.5, for: [second])
        workspace.setVolumeSort(nil, for: [second])
        await workspace.settle()
        #expect(workspace.row(second)?.metadata.volumeSort == 3)
    }

    @Test("入れた巻数(並べ替え用)は全角でも数として読み、数でなければ受け付けない")
    func volumeSortNumberParsing() {
        #expect(MetadataWorkspace.volumeSortNumber("2.5") == 2.5)
        #expect(MetadataWorkspace.volumeSortNumber("２．５") == 2.5)
        #expect(MetadataWorkspace.volumeSortNumber(" 10 ") == 10)
        #expect(MetadataWorkspace.volumeSortNumber("上") == nil)
        #expect(MetadataWorkspace.volumeSortNumber("nan") == nil)
        #expect(MetadataWorkspace.volumeSortNumber("inf") == nil)
    }

    @Test("ロックした本は、すべての欄が確定した内容として読まれる")
    func lockedBooksAreFullyConfirmed() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        library.metadata.upsert(bookID: first, values: BookMetadataValues(title: "手で直した題", authors: ["別の著者"]))
        let workspace = await open(library, [first, second])

        let row = try #require(workspace.row(first))
        #expect(row.isLocked)
        #expect(row.metadata.title == "手で直した題")
        #expect(row.metadata.authors == ["別の著者"])
        // シリーズが空の登録は「シリーズではない」(qooMeta が組にしても入れない)。
        #expect(row.metadata.series.isEmpty)

        #expect(workspace.isLocked(first))
        #expect(library.metadata.record(forBookID: first)?.values.title == "手で直した題")
    }

    @Test("ファイル名の解析ルールを切り替えても変更した値は残り、変更していない欄はそのルールセットで読んだ値になる")
    func switchingTheRuleSetKeepsEdits() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let book = "/書庫/(架空の催し) [架空工房] 月の庭 (作品A).zip"
        let workspace = await open(library, [book])
        workspace.set(.info, to: ["架空の付記"], for: [book])

        workspace.setRuleSet([book], to: "doujinshi")
        await workspace.settle()
        #expect(workspace.row(book)?.metadata.info == "架空の付記")
        #expect(library.metadata.record(forBookID: book)?.ruleSet == "doujinshi")
        #expect(library.metadata.record(forBookID: book)?.isLocked == false)
        workspace.setLocked([book], true)
        await workspace.settle()
        #expect(workspace.presetName(for: book) == "doujinshi")
        #expect(workspace.hasPresetOverride(book))
        let stored = try #require(library.metadata.metadata(forBookID: book))
        #expect(stored.source == "作品A")
    }

    @Test("ほかの画面が DB を変えたら、その本の行が合う")
    func externalChangesAreApplied() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])

        library.metadata.upsertAll([.init(bookID: second, values: BookMetadataValues(title: "外で直した題"), state: .locked)])
        workspace.applyExternalChanges([second: library.metadata.record(forBookID: second)])
        await workspace.settle()
        #expect(workspace.row(second)?.metadata.title == "外で直した題")
        #expect(workspace.row(second)?.isLocked == true)

        // 外で行が消えたら、一覧から外す。
        library.metadata.delete(forBookID: first)
        workspace.applyExternalChanges([first: BookMetadataRecord?.none])
        await workspace.settle()
        #expect(workspace.row(first) == nil)
    }

    @Test("型に合わなかった本は「型に合わなかった」で絞り込める")
    func unmatchedBooksCanBeFiltered() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let odd = "/書庫/型の無い名前.zip"
        let workspace = await open(library, [first, odd])

        workspace.stateFilter = .unmatched
        #expect(workspace.rows.map(\.id) == [odd])
        #expect(workspace.unmatchedCount == 1)
    }
}

extension MetadataWorkspaceTests {
    @Test("ファイル名フォーマットと合致しなかった本は、並べ替えに関わらず上にまとまる")
    func unmatchedBooksComeFirst() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let named = "/書庫/[架空工房] 月の庭 1.zip"
        let odd = "/書庫/ん型の無い名前.zip"
        let workspace = await open(library, [named, odd])
        #expect(workspace.rows.map(\.id) == [odd, named])
    }

    @Test("一覧から外した本は、行も取り消しの歩みからも消える")
    func removedBooksLeaveTheList() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let first = "/書庫/[架空工房] 月の庭 1.zip"
        let second = "/書庫/[架空工房] 月の庭 2.zip"
        let workspace = await open(library, [first, second])
        workspace.set(.info, to: ["架空の付記"], for: [first])
        await workspace.settle()

        workspace.removeBooks([first])
        await workspace.settle()
        #expect(workspace.rows.map(\.id) == [second])
        #expect(workspace.undoName == nil)
    }

    @Test("メタデータを削除すると、ロックした本でも直していない本でも一覧から消え、DB の行も消える")
    func deletingMetadataRemovesTheBooks() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let first = "/書庫/[架空工房] 月の庭 1.zip"
        let second = "/書庫/[架空工房] 月の庭 2.zip"
        let third = "/書庫/[架空工房] 月の庭 3.zip"
        library.metadata.upsert(bookID: first, values: BookMetadataValues(title: "登録した題", authors: ["架空工房"]))
        let workspace = await open(library, [first, second, third])
        workspace.set(.info, to: ["架空の付記"], for: [second])
        await workspace.settle()

        workspace.deleteBooks([first, second, third])
        await workspace.settle()
        #expect(workspace.rows.isEmpty)
        #expect(library.metadata.registeredBookIDs.isEmpty)

        // 覚えてはおかない: 開き直せば、また登録される(利用者の指示 2026-09-22)。
        let reopened = await open(library, [third])
        #expect(reopened.row(third) != nil)
        #expect(library.metadata.record(forBookID: third)?.isLocked == false)
    }
}

/// 規則の設定(`MetadataRulesStore`)。
@MainActor
struct MetadataRulesStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewerTests.rules.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @Test("以前の既定から変えていたファイル名フォーマットは、利用者のルールセットとして 1 度だけ引き継ぐ")
    func legacyFormatsAreMigratedOnce() throws {
        let suite = TestDefaultsPool.checkout()
        let defaults = suite.defaults
        defer { suite.release() }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        struct Legacy: Encodable { var id = UUID(); var pattern: String }
        defaults.set(try JSONEncoder().encode([Legacy(pattern: "@title - @author")]),
                     forKey: "qooViewer.metadata.filenameFormats")

        let store = MetadataRulesStore(url: url, legacyDefaults: defaults)
        let entry = try #require(store.rules.presetCatalog.entries.first { $0.id == MetadataRulesStore.legacyPresetName })
        #expect(entry.preset.formats.map(\.text) == ["@title - @author"])
        #expect(store.rules.presetCatalog.defaultPreset == MetadataRulesStore.legacyPresetName)
        #expect(defaults.data(forKey: "qooViewer.metadata.filenameFormats") == nil)

        // 保存したものを読み直しても残っている。
        let reopened = MetadataRulesStore(url: url, legacyDefaults: defaults)
        #expect(reopened.rules.contentHash == store.rules.contentHash)
    }

    @Test("qooMeta が読めない書式は外して残りを引き継ぎ、以前の値は消さずに残す(2026-09-22 の監査)")
    func legacyFormatsQooMetaCannotReadAreKept() throws {
        let suite = TestDefaultsPool.checkout()
        let defaults = suite.defaults
        defer { suite.release() }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        struct Legacy: Encodable { var id = UUID(); var pattern: String }
        // 2 つ目は @title も @series も無い、3 つ目は欄が区切り無しで隣り合う ―― どちらも以前の書式では通った。
        let patterns = ["@title - @author", "[@author] @ignore", "@author@title"]
        let stored = try JSONEncoder().encode(patterns.map { Legacy(pattern: $0) })
        defaults.set(stored, forKey: "qooViewer.metadata.filenameFormats")

        let store = MetadataRulesStore(url: url, legacyDefaults: defaults)
        let entry = try #require(store.rules.presetCatalog.entries.first { $0.id == MetadataRulesStore.legacyPresetName })
        #expect(entry.preset.formats.map(\.text) == ["@title - @author"])
        #expect(entry.preset.note.contains("[@author] @ignore"))
        #expect(entry.preset.note.contains("@author@title"))
        // 外した書式があるので、以前の値は残す。旗は立つので、次の起動でもう一度引き継がない。
        #expect(defaults.data(forKey: "qooViewer.metadata.filenameFormats") == stored)
        #expect(defaults.bool(forKey: "qooViewer.metadata.migratedToQooMeta"))
        let reopened = MetadataRulesStore(url: url, legacyDefaults: defaults)
        #expect(reopened.rules.contentHash == store.rules.contentHash)
    }

    @Test("1 つも読めない書式だけなら、何も足さずに以前の値を残す")
    func legacyFormatsNoneReadableAreKept() throws {
        let suite = TestDefaultsPool.checkout()
        let defaults = suite.defaults
        defer { suite.release() }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        struct Legacy: Encodable { var id = UUID(); var pattern: String }
        let stored = try JSONEncoder().encode([Legacy(pattern: "[@author] @ignore")])
        defaults.set(stored, forKey: "qooViewer.metadata.filenameFormats")

        let store = MetadataRulesStore(url: url, legacyDefaults: defaults)
        #expect(store.rulesDiff.isEmpty)
        #expect(defaults.data(forKey: "qooViewer.metadata.filenameFormats") == stored)
    }

    @Test("以前の既定のままだったら何も引き継がない")
    func untouchedLegacyFormatsAreNotMigrated() throws {
        let suite = TestDefaultsPool.checkout()
        let defaults = suite.defaults
        defer { suite.release() }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = MetadataRulesStore(url: url, legacyDefaults: defaults)
        #expect(store.rulesDiff.isEmpty)
    }

    @Test("フォルダの本は拡張子に見える部分を削らず、書庫は拡張子を削って読む")
    func baseNameKeepsFolderNames() {
        #expect(MetadataRulesStore.baseName(forBookID: "/書庫/月の庭 vol.3") == "月の庭 vol.3")
        #expect(MetadataRulesStore.baseName(forBookID: "/書庫/月の庭 3.cbz") == "月の庭 3")
    }
}

extension MetadataRulesStoreTests {
    @Test("差分として読めない保存済みの差分は、1 か所ずつの変更で上書きされず、写しも残る(2026-09-22 の監査)")
    func unparsableDiffIsNotOverwrittenByAnEdit() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewerTests.unparsable.\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 外側の settings.json は読めるが、中の差分は壊れている(手で直しかけた、など)。
        let broken = #"{"base": "builtin", "kind": "未来の種類"}"#
        let settings = try JSONSerialization.data(withJSONObject: ["rulesDiff": broken])
        try settings.write(to: url)

        let store = MetadataRulesStore(url: url, legacyDefaults: nil)
        #expect(store.unreadableRulesDiff == broken)
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("settings.unreadable-") }
        #expect(kept.count == 1)

        // 以前はここで「変更なし + 何もしない変更」の空の差分が保存され、壊れた差分が消えた。
        #expect(!store.update { _ in }.isEmpty)
        #expect(store.rulesDiff == broken)
        #expect(MetadataRulesStore(url: url, legacyDefaults: nil).rulesDiff == broken)

        // すべてを既定に戻すのは通る(写しは残してある)。
        #expect(store.resetRules(.fileNames).isEmpty)
        #expect(store.rulesDiff.isEmpty)
        #expect(store.unreadableRulesDiff == nil)
    }

    @Test("対象外のフォルダの中とサブフォルダの本は対象外、保存して読み直しても残る")
    func excludedFolders() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewerTests.excluded.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MetadataRulesStore(url: url, legacyDefaults: nil)
        store.addExcludedFolder(URL(fileURLWithPath: "/架空/除外", isDirectory: true))
        #expect(store.isExcluded(bookID: "/架空/除外/本.zip"))
        #expect(store.isExcluded(bookID: "/架空/除外/下の階/本.zip"))
        #expect(!store.isExcluded(bookID: "/架空/除外しない/本.zip"))

        var change = FileSystemChange()
        change.relocations = [.init(from: URL(fileURLWithPath: "/架空/除外"), to: URL(fileURLWithPath: "/架空/移した"))]
        store.relocate(using: change)
        let reopened = MetadataRulesStore(url: url, legacyDefaults: nil)
        #expect(reopened.excludedFolders == ["/架空/移した"])
    }
}

extension MetadataWorkspaceTests {
    @Test("鍵を外した元の登録は、「メタデータを再生成」で直した欄を捨てて DB もファイル名の読みに戻る(ロックした本は触らない)")
    func reparsingThrowsAwayEdits() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let first = "/書庫/[架空工房] 月の庭 1.zip"
        let second = "/書庫/[架空工房] 月の庭 2.zip"
        library.metadata.upsert(bookID: first, values: BookMetadataValues(title: "古い題", authors: ["架空工房"]))
        library.metadata.upsert(bookID: second, values: BookMetadataValues(title: "残す題", authors: ["架空工房"]))
        let workspace = await open(library, [first, second])
        workspace.setLocked([first], false)
        await workspace.settle()
        #expect(workspace.unlockedEditedIDs == [first])

        workspace.reparseFromFileNames([first, second])
        await workspace.settle()
        #expect(workspace.row(first)?.metadata.title == "月の庭 1")
        #expect(workspace.row(first)?.hasUnlockedEdits == false)
        #expect(workspace.row(second)?.metadata.title == "残す題")
        #expect(library.metadata.record(forBookID: first)?.values.title == "月の庭 1")
        #expect(library.metadata.record(forBookID: first)?.edits == Confirmation.none)
        #expect(library.metadata.record(forBookID: second)?.values.title == "残す題")
    }
}

extension MetadataWorkspaceTests {
    @Test("以前の版の欄で登録した行は、空の欄だけをファイル名から埋め、登録した値は変えない")
    func outdatedRowsGetTheirEmptyFieldsFilled() throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let book = "/書庫/(架空ジャンル) [架空工房] 月の庭 (作品A) [架空の付記].zip"
        library.metadata.upsert(bookID: book, author: "架空工房", title: "手で直した題", series: "", seriesIndex: "")
        #expect(library.metadata.outdatedFieldBookIDs == [book])

        let rules = library.metadataRules.rules
        library.metadata.fillMissingFields(of: [book]) {
            BookMetadataValues(MetadataRulesStore.reading(forBookID: $0, rules: rules).metadata)
        }
        let row = try #require(library.metadata.metadata(forBookID: book))
        #expect(row.title == "手で直した題")
        #expect(row.genre == "架空ジャンル")
        #expect(!row.info.isEmpty)
        #expect(library.metadata.outdatedFieldBookIDs.isEmpty)
    }
}

/// 画面を持たない登録の口(`BookMetadataStore` の registerParsed / importSourceMetadata / reparseUnlockedRows、2026-09-22)。
@MainActor
struct MetadataRegistrationTests {
    private let first = "/書庫/[架空工房] 月の庭 1.zip"
    private let second = "/書庫/[架空工房] 月の庭 2.zip"

    @Test("本を開いたときは、行の無い本だけをファイル名の読みでロックせずに登録する")
    func registerParsedCreatesOnlyMissingRows() throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let rules = library.metadataRules.rules
        library.metadata.upsert(bookID: second, values: BookMetadataValues(title: "登録した題"))

        library.metadata.registerParsed(bookID: first, rules: rules)
        library.metadata.registerParsed(bookID: second, rules: rules)
        let created = try #require(library.metadata.record(forBookID: first))
        #expect(!created.isLocked)
        #expect(created.values.authors == ["架空工房"])
        #expect(library.metadata.record(forBookID: second)?.values.title == "登録した題")
        #expect(library.metadata.record(forBookID: second)?.isLocked == true)
    }

    @Test("ファイルの書誌情報は、ロックしていない行へ 1 度だけ入り、直した欄は変えない。ロックした行は変えない")
    func sourceMetadataRespectsEditsAndLocks() throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let rules = library.metadataRules.rules
        let edits = Confirmation.fields(ConfirmedFields([.title: ["手で直した題"]]))
        library.metadata.upsertAll([.init(bookID: first, values: BookMetadataValues(title: "手で直した題"),
                                          state: BookMetadataRowState(isLocked: false, edits: edits))])
        library.metadata.upsert(bookID: second, values: BookMetadataValues(title: "ロックした題"))
        var source = SourceBookMetadata()
        source.title = "ファイルの題"
        source.author = "ファイルの著者"
        source.series = "ファイルのシリーズ"
        source.seriesIndex = "7"

        #expect(library.metadata.importSourceMetadata(bookID: first, source: source, rules: rules))
        let imported = try #require(library.metadata.record(forBookID: first))
        #expect(imported.values.title == "手で直した題")
        #expect(imported.values.authors == ["ファイルの著者"])
        #expect(imported.values.series == "ファイルのシリーズ")
        #expect(imported.values.volume == "7")
        #expect(!imported.isLocked)
        // 2 度目は取り込まない。
        source.author = "別の著者"
        #expect(!library.metadata.importSourceMetadata(bookID: first, source: source, rules: rules))
        #expect(library.metadata.record(forBookID: first)?.values.authors == ["ファイルの著者"])

        #expect(!library.metadata.importSourceMetadata(bookID: second, source: source, rules: rules))
        #expect(library.metadata.record(forBookID: second)?.values.title == "ロックした題")
    }

    @Test("規則を変えたときの読み直しは、ロックしていない行だけを書き直し、直した欄は残す")
    func reparseRewritesOnlyUnlockedRows() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let rules = library.metadataRules.rules
        let edits = Confirmation.fields(ConfirmedFields([.info: ["残す付記"]]))
        library.metadata.upsertAll([
            .init(bookID: first, values: BookMetadataValues(title: "古い読み", info: "残す付記"),
                  state: BookMetadataRowState(isLocked: false, edits: edits)),
            .init(bookID: second, values: BookMetadataValues(title: "ロックした題"), state: .locked),
        ])

        await library.metadata.reparseUnlockedRows(rules: rules)
        let reparsed = try #require(library.metadata.record(forBookID: first))
        #expect(reparsed.values.title == "月の庭 1")
        #expect(reparsed.values.info == "残す付記")
        #expect(library.metadata.record(forBookID: second)?.values.title == "ロックした題")
    }

    @Test("ほかに覚えている理由の無い、ファイル名の読みだけの行は消え、ロック・直した欄・覚えている本・対象フォルダの本の行は残る")
    func parsedOnlyRowsArePruned() throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let parsedOnly = BookMetadataRowState(isLocked: false)
        let edited = BookMetadataRowState(isLocked: false, edits: .fields(ConfirmedFields([.info: ["付記"]])))
        library.metadata.upsertAll([
            .init(bookID: "/架空/消える.zip", values: BookMetadataValues(title: "消える"), state: parsedOnly),
            .init(bookID: "/架空/覚えている.zip", values: BookMetadataValues(title: "覚えている"), state: parsedOnly),
            .init(bookID: "/架空/棚/対象の中.zip", values: BookMetadataValues(title: "対象の中"), state: parsedOnly),
            .init(bookID: "/架空/直した.zip", values: BookMetadataValues(title: "直した"), state: edited),
            .init(bookID: "/架空/ロックした.zip", values: BookMetadataValues(title: "ロックした"), state: .locked),
        ])

        let pruned = library.metadata.pruneParsedOnlyRows(keeping: ["/架空/覚えている.zip"], keepingFolders: ["/架空/棚"])
        #expect(pruned == 1)
        #expect(library.metadata.registeredBookIDs == [
            "/架空/覚えている.zip", "/架空/棚/対象の中.zip", "/架空/直した.zip", "/架空/ロックした.zip",
        ])
        #expect(library.metadata.pruneParsedOnlyRows(keeping: ["/架空/覚えている.zip"], keepingFolders: ["/架空/棚"]) == 0)

        // 対象フォルダの中でも、最後に探した一覧に無い本の読みだけの行は消える(2026-09-22 の監査)。
        library.metadata.upsertAll([
            .init(bookID: "/架空/棚/消えた本.zip", values: BookMetadataValues(title: "消えた本"), state: parsedOnly),
        ])
        #expect(library.metadata.pruneParsedOnlyRows(keeping: [], keepingFolders: ["/架空/棚"],
                                                     folderBooks: ["/架空/棚/対象の中.zip"]) == 2)
        #expect(library.metadata.registeredBookIDs == ["/架空/棚/対象の中.zip", "/架空/直した.zip", "/架空/ロックした.zip"])
    }

    @Test("区切って登録すると、区切りごとに書いて知らせ、すべての行ができる")
    func batchedRegistrationWritesEveryBatch() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let entries = (1...5).map { index in
            BookMetadataStore.BatchEntry(bookID: "/架空/本\(index).zip", values: BookMetadataValues(title: "題\(index)"),
                                         onlyIfUnlocked: true)
        }
        var batches: [[String]] = []
        let written = await library.metadata.upsertAllInBatches(entries, batchSize: 2) { batch in
            batches.append(batch.map(\.bookID))
        }
        #expect(written == 5)
        #expect(batches.map(\.count) == [2, 2, 1])
        #expect(library.metadata.registeredBookIDs.count == 5)
        #expect(library.metadata.record(forBookID: "/架空/本3.zip")?.isLocked == false)
    }
}

extension MetadataWorkspaceTests {
    @Test("外で行が消えた知らせで一覧から外すのは、行があったと分かっている本だけ")
    func onlyBooksWithRowsLeaveTheList() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        library.metadata.upsert(bookID: first, values: BookMetadataValues(title: "登録した題"))
        // 登録(registerAll)をしない窓: second は DB に行が無いまま並ぶ(全欄が空で行を作れない本と同じ立場)。
        let entries = [first, second].map {
            MetadataWorkspace.Entry(bookID: $0, record: library.metadata.record(forBookID: $0))
        }
        let workspace = await MetadataWorkspace.open(entries, rules: library.metadataRules.rules)

        workspace.applyExternalChanges([second: BookMetadataRecord?.none])
        await workspace.settle()
        #expect(workspace.row(second) != nil)

        library.metadata.delete(forBookID: first)
        workspace.applyExternalChanges([first: BookMetadataRecord?.none])
        await workspace.settle()
        #expect(workspace.row(first) == nil)
    }
}
