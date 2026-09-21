import Foundation
import QooMetaKit
import Testing

@testable import qooViewer

/// メタデータの編集ウインドウの中身(`MetadataWorkspace`)を、メモリ内の SwiftData の上で通す(2026-09-21、
/// qooMeta への置き換え)。見るのは qooViewer で足した約束 ―― **直したらすぐ登録**・取り消しも DB へ届く・
/// 登録済みの本は規則を変えても変わらない・読み直しと登録の解除。qooMeta の計算そのものは qooMeta のテストが見ている。
///
/// 本の名前はすべて架空(docs/02「個人情報の流出防止」)。
@MainActor
struct MetadataWorkspaceTests {
    private func open(_ library: InMemoryLibrary, _ bookIDs: [String]) async -> MetadataWorkspace {
        let entries = bookIDs.map {
            MetadataWorkspace.Entry(bookID: $0, registeredValues: library.metadata.metadata(forBookID: $0)?.values)
        }
        let workspace = await MetadataWorkspace.open(entries, rules: library.metadataRules.rules)
        workspace.writeBack = { [metadata = library.metadata] in metadata.upsertAll($0) }
        return workspace
    }

    private let first = "/書庫/[架空工房] 月の庭 1.zip"
    private let second = "/書庫/[架空工房] 月の庭 2.zip"

    @Test("未登録の本は、ファイル名を qooMeta で読んだ提案(シリーズと巻つき)で並ぶ")
    func unregisteredBooksShowTheProposal() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])

        let row = try #require(workspace.row(second))
        #expect(row.metadata.authors == ["架空工房"])
        #expect(row.metadata.series == "月の庭")
        #expect(row.metadata.volume == "2")
        #expect(!row.isRegistered)
        #expect(library.metadata.registeredBookIDs.isEmpty)
    }

    @Test("直しても登録はされず(下書き)、鍵を掛けると見えている値で登録され、外すと行は消えて値は下書きに残る")
    func lockingIsRegistering() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])
        var drafts: [String: MetadataDraftStore.Draft?] = [:]
        workspace.draftsChanged = { drafts.merge($0) { _, new in new } }

        // 情報の欄は比べる単位(先頭の著者 + ジャンル)に入らないので、直してもシリーズの組は変わらない。
        workspace.set(.info, to: ["架空の付記"], for: [first])
        await workspace.settle()
        #expect(library.metadata.metadata(forBookID: first) == nil)
        #expect(workspace.row(first)?.hasUnregisteredEdits == true)
        #expect(drafts[first] != nil)

        workspace.undo()
        await workspace.settle()
        #expect(workspace.row(first)?.metadata.info == "")
        workspace.redo()
        await workspace.settle()

        workspace.setLocked([first], true)
        await workspace.settle()
        let stored = try #require(library.metadata.metadata(forBookID: first))
        #expect(stored.info == "架空の付記")
        #expect(stored.series == "月の庭")
        #expect(stored.seriesIndex == "1")
        #expect(workspace.isLocked(first))

        // 鍵が掛かっている間は直せない。
        workspace.set(.info, to: ["別の付記"], for: [first])
        await workspace.settle()
        #expect(library.metadata.metadata(forBookID: first)?.info == "架空の付記")

        workspace.setLocked([first], false)
        await workspace.settle()
        #expect(library.metadata.metadata(forBookID: first) == nil)
        #expect(workspace.row(first)?.metadata.info == "架空の付記")
        #expect(drafts[first] != nil)
    }

    @Test("登録済みの本は、すべての欄が確定した内容として読まれ、登録を外すと提案に戻って行も消える")
    func registeredBooksAreFullyConfirmed() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        library.metadata.upsert(bookID: first, values: BookMetadataValues(title: "手で直した題", authors: ["別の著者"]))
        let workspace = await open(library, [first, second])

        let row = try #require(workspace.row(first))
        #expect(row.isRegistered)
        #expect(row.metadata.title == "手で直した題")
        #expect(row.metadata.authors == ["別の著者"])
        // シリーズが空の登録は「シリーズではない」(qooMeta が組にしても入れない)。
        #expect(row.metadata.series.isEmpty)

        #expect(workspace.isLocked(first))
        workspace.unregister([first])
        await workspace.settle()
        #expect(library.metadata.metadata(forBookID: first) == nil)
        #expect(workspace.row(first)?.metadata.authors == ["架空工房"])
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
        #expect(library.metadata.metadata(forBookID: book) == nil)
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

        library.metadata.upsert(bookID: second, values: BookMetadataValues(title: "外で直した題"))
        workspace.applyExternalChanges([second: library.metadata.metadata(forBookID: second)?.values])
        await workspace.settle()
        #expect(workspace.row(second)?.metadata.title == "外で直した題")
        #expect(workspace.row(second)?.isRegistered == true)
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
        let suite = "qooViewerTests.rulesLegacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
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

    @Test("以前の既定のままだったら何も引き継がない")
    func untouchedLegacyFormatsAreNotMigrated() throws {
        let suite = "qooViewerTests.rulesLegacyDefault.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
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
        store.relocateExcludedFolders(using: change)
        let reopened = MetadataRulesStore(url: url, legacyDefaults: nil)
        #expect(reopened.excludedFolders == ["/架空/移した"])
    }
}

extension MetadataWorkspaceTests {
    @Test("鍵を外した元の登録は、「解析・抽出し直す」で下書きを捨てて提案に戻る(ロックした本は触らない)")
    func reparsingThrowsAwayDrafts() async throws {
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
        #expect(workspace.row(first)?.hasUnregisteredEdits == false)
        #expect(workspace.row(second)?.metadata.title == "残す題")
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
