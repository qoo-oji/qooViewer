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
    /// 窓を開く。並ぶ本と値はメタデータ生成(`MetadataGenerator`)から(2026-09-22)。`bookIDs` は開いた本として渡す。
    private func open(_ library: InMemoryLibrary, _ bookIDs: [String]) async -> MetadataWorkspace {
        let generator = library.makeMetadataGenerator(books: bookIDs)
        generator.start()
        return await MetadataWorkspace.open(generator: generator, store: library.metadata)
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

    @Test("1 冊ぶんのシートで巻数(並べ替え用)を変えると確定し、無しにすると外れ、巻の表記だけを変えると外れる(2026-09-22)")
    func sheetEditsOfTheSortVolume() {
        let opened = BookMetadataValues(title: "月の庭 番外編", authors: ["架空工房"], series: "月の庭", volume: "番外編", volumeSort: nil)
        var changed = opened
        changed.volumeSort = 1.5
        let confirmed = MetadataParsing.edits(changing: opened, to: changed, in: .none)
        #expect(confirmed.fields.volumeSort == 1.5)
        #expect(confirmed.fields.values.isEmpty)

        var cleared = changed
        cleared.volumeSort = nil
        #expect(MetadataParsing.edits(changing: changed, to: cleared, in: confirmed).fields.volumeSort == nil)

        var renamed = changed
        renamed.volume = "外伝"
        renamed.volumeSort = nil
        let afterVolume = MetadataParsing.edits(changing: changed, to: renamed, in: confirmed)
        #expect(afterVolume == .series(name: "月の庭", volume: "外伝"))

        // 数を変えずにほかの欄だけを変えたら、確定した数はそのまま。
        var retitled = changed
        retitled.info = "架空の付記"
        #expect(MetadataParsing.edits(changing: changed, to: retitled, in: confirmed).fields.volumeSort == 1.5)
    }

    @Test("巻数(表示)が空でもシリーズのある本なら巻数(並べ替え用)を入れられ、DB に残る(2026-09-22、利用者の報告)")
    func volumeSortWithoutVolumeText() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        var workspace = await open(library, [first, second])
        workspace.clearVolumes([second])
        workspace.setVolumeSort(1.5, for: [second])
        await workspace.settle()
        #expect(workspace.row(second)?.metadata.volume == "")
        #expect(workspace.row(second)?.metadata.volumeSort == 1.5)
        #expect(library.metadata.record(forBookID: second)?.values.volumeSort == 1.5)

        workspace.setLocked([second], true)
        await workspace.settle()
        workspace = await open(library, [first, second])
        #expect(workspace.row(second)?.metadata.volumeSort == 1.5)
        #expect(library.metadata.record(forBookID: second)?.values.volumeSort == 1.5)

        // シリーズも巻の表記も無い値は、数を持たない。
        #expect(BookMetadataValues(title: "架空", volumeSort: 2).trimmed.volumeSort == nil)
        #expect(BookMetadataValues(series: "月の庭", volumeSort: 2).trimmed.volumeSort == 2)
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

    @Test("鍵を外しても、ファイル名の読みと同じ欄は直した欄にならない(青く出ない)。違う欄だけが直した欄に残る(2026-09-22、利用者の報告)")
    func unlockingKeepsOnlyRealEdits() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])
        // 直してすぐ(行に届く前に)鍵を掛けても、直した値でロックされる。
        workspace.set(.info, to: ["架空の付記"], for: [first])
        workspace.setLocked([first, second], true)
        await workspace.settle()
        #expect(library.metadata.record(forBookID: first)?.values.info == "架空の付記")
        #expect(library.metadata.record(forBookID: first)?.isLocked == true)
        await workspace.settle()
        workspace.setLocked([first, second], false)
        await workspace.settle()

        #expect(!workspace.isLocked(second))
        #expect(workspace.row(second)?.hasUnlockedEdits == false)
        #expect(workspace.row(second)?.confirmation == QooMetaKit.Confirmation.none)
        #expect(workspace.row(second)?.metadata.series == "月の庭")
        #expect(library.metadata.record(forBookID: second)?.edits == QooMetaKit.Confirmation.none)
        #expect(library.metadata.record(forBookID: second)?.isLocked == false)

        #expect(workspace.row(first)?.edited == [.info])
        #expect(workspace.row(first)?.hasConfirmedSeries == false)
        #expect(workspace.row(first)?.metadata.info == "架空の付記")
        #expect(library.metadata.record(forBookID: first)?.edits.fields[.info] == ["架空の付記"])
    }

    @Test("直しが DB に届く前にほかの書き手の知らせが来ても、直しは戻らない。外で本当に変わった本だけを合わせる(2026-09-22、利用者の報告)")
    func pendingEditSurvivesUnrelatedNotifications() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])
        workspace.setSeries("別の名前", for: [second])
        // bookID の無い知らせ(スマートライブラリの登録など)を受けたときと同じ呼び出し。この時点で DB はまだ直す前。
        workspace.applyExternalChanges([first: library.metadata.record(forBookID: first),
                                        second: library.metadata.record(forBookID: second)])
        await workspace.settle()
        #expect(workspace.row(second)?.metadata.series == "別の名前")
        #expect(library.metadata.record(forBookID: second)?.values.series == "別の名前")
        #expect(workspace.canUndo)

        // 外で本当に変わった(ロックされた)本は合わせる。
        var values = try #require(library.metadata.record(forBookID: first)).values
        values.info = "外で書いた付記"
        library.metadata.upsertAll([BookMetadataStore.BatchEntry(bookID: first, values: values, state: .locked)])
        workspace.applyExternalChanges([first: library.metadata.record(forBookID: first)])
        await workspace.settle()
        #expect(workspace.isLocked(first))
        #expect(workspace.row(first)?.metadata.info == "外で書いた付記")
    }

    @Test("シリーズ名を別の名前に変えると巻を新しい名前で読み直し、表記だけの直し・同じシリーズへのまとめでは巻を残す(2026-09-22、利用者の指示)")
    func renamingTheSeriesReproposesTheVolume() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let other = "/書庫/[架空工房] 星の海 7.zip"
        let gaiden = "/書庫/[架空工房] 月の庭 外伝 3.zip"
        let workspace = await open(library, [first, second, other, gaiden])
        // 新しいシリーズ名がタイトルの前にあれば、その後ろから巻を読み直す。
        workspace.setVolumes("9", for: [gaiden])
        workspace.setSeries("月の庭 外伝", for: [gaiden])
        await workspace.settle()
        #expect(workspace.row(gaiden)?.metadata.series == "月の庭 外伝")
        #expect(workspace.row(gaiden)?.metadata.volume == "3")
        // 巻を 5 に直し、並べ替え用の巻数も確定してから、別のシリーズ名にする。
        workspace.setVolumes("5", for: [second])
        workspace.setVolumeSort(1.5, for: [second])
        workspace.setSeries("月の庭", for: [other])
        await workspace.settle()
        #expect(workspace.row(other)?.metadata.series == "月の庭")
        #expect(workspace.row(other)?.hasConfirmedVolumeSort == false)
        #expect(workspace.row(other)?.hasConfirmedSeries == true)
        // 確定を外した巻は、qooMeta の提案(新しい名前がタイトルに当たらないので推定、または無し)。直した「5」は持ち越さない。
        workspace.setSeries("星の庭", for: [second])
        await workspace.settle()
        #expect(workspace.row(second)?.metadata.series == "星の庭")
        #expect(workspace.row(second)?.metadata.volume != "5")
        #expect(workspace.row(second)?.hasConfirmedVolumeSort == false)
        if case .series(_, let volume, let fields) = workspace.row(second)?.confirmation {
            #expect(volume == nil)
            #expect(fields.volumeSort == nil)
        } else {
            Issue.record("シリーズが確定していない")
        }

        // 表記だけの直しは巻を残す。
        workspace.setVolumes("5", for: [second])
        workspace.setSeries("星の 庭!", for: [second])
        await workspace.settle()
        #expect(workspace.row(second)?.metadata.volume == "5")
        // もとからそのシリーズの本は、まとめても巻を残す。
        workspace.setSeries("星の 庭!", for: [first, second])
        await workspace.settle()
        #expect(workspace.row(second)?.metadata.volume == "5")
        #expect(workspace.row(first)?.metadata.series == "星の 庭!")

        #expect(MetadataWorkspace.sameSeriesName("月の庭", "月の 庭!"))
        #expect(MetadataWorkspace.sameSeriesName("ＡＢＣ", "abc"))
        #expect(!MetadataWorkspace.sameSeriesName("月の庭", "星の庭"))
        #expect(!MetadataWorkspace.sameSeriesName("", "!"))
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

    @Test("ほかの画面(インスペクタ)で直した直後にロックしても、直す前の値でロックしない(2026-10-04 の監査 MD-14)")
    func lockingRightAfterAnOutsideEditKeepsTheEdit() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])
        await workspace.settle()

        // インスペクタと同じ書き方: 値と、直した欄を持つ行の形を書く。値はメタデータ生成の次の回で窓へ届く。
        let record = try #require(library.metadata.record(forBookID: second))
        var values = record.values
        values.title = "外で直した題"
        var state = record.rowState
        state.edits = MetadataParsing.edits(changing: record.values.trimmed, to: values.trimmed, in: state.edits)
        library.metadata.upsertAll([.init(bookID: second, values: values.trimmed, state: state)])
        workspace.applyExternalChanges([second: library.metadata.record(forBookID: second)])

        // 読みが届く前に、この窓で鍵を掛ける。
        workspace.setLocked([second], true)
        await workspace.settle()
        #expect(library.metadata.record(forBookID: second)?.isLocked == true)
        #expect(library.metadata.record(forBookID: second)?.values.title == "外で直した題")
        #expect(workspace.row(second)?.metadata.title == "外で直した題")
    }

    /// 2026-10-04 の実機確認で見つけた、監査 MD-7 の直しの穴。書き換え中のセルを確定させた直後に鍵を押すと、待っている間に
    /// メタデータ生成の回が行の形を DB(まだ鍵の無い形)で読み直し、鍵が黙って掛からなかった。
    /// メモリ上のストアでは生成の回が鍵を待つ間に割り込まないので、**待っている間の上書きを外の変更の知らせで差し込む**(同じく
    /// `states` を DB の鍵の無い形で上書きする道)。直す前(読みが届いた後に `isLocked` で確かめ直していた形)はこれで鍵が掛からない
    /// (2026-10-04 のレビューの R8b-2。以前のこのテストは割り込みが無く、直す前でも通った)。
    @Test("直した直後に鍵を押しても、待っている間に行の形が読み直されても鍵が掛かる")
    func lockingRightAfterAnEditInThisWindowLocks() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])
        await workspace.settle()

        // セルの確定と同じ道(この窓の直し)で書き、読みが届く前に鍵を掛ける。
        workspace.set(.genre, to: ["架空のジャンル"], for: [second])
        let unlockedRecord = try #require(library.metadata.record(forBookID: second))
        #expect(!unlockedRecord.isLocked)
        workspace.setLocked([second], true)
        // 待っている間に、行の形が DB のまだ鍵の無い形で上書きされる(メタデータ生成の回・外の変更の知らせ)。
        workspace.applyExternalChanges([second: unlockedRecord])
        #expect(!workspace.isLocked(second))
        await workspace.settle()
        #expect(library.metadata.record(forBookID: second)?.isLocked == true)
        #expect(library.metadata.record(forBookID: second)?.values.genre == "架空のジャンル")
        #expect(workspace.isLocked(second))

        // 待っている間に外したら、鍵は掛からない。
        workspace.set(.genre, to: ["別の架空のジャンル"], for: [first])
        workspace.setLocked([first], true)
        workspace.setLocked([first], false)
        await workspace.settle()
        #expect(library.metadata.record(forBookID: first)?.isLocked != true)
        #expect(!workspace.isLocked(first))
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

    @Test("付け替えられた本は、作り直さずに新しい bookID の行へ選択・取り消しの歩みごと移り、検索も残る(2026-10-04 の監査 MD-2)")
    func aRelocatedBookKeepsItsSelectionAndUndo() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let generator = library.makeMetadataGenerator(books: [first, second])
        generator.start()
        let workspace = await MetadataWorkspace.open(generator: generator, store: library.metadata)
        workspace.set(.info, to: ["架空の付記"], for: [first])
        await workspace.settle()
        workspace.searchText = "月の庭"
        workspace.selection = [first]
        let moved = "/書庫/移した先/[架空工房] 月の庭 1.zip"
        let change = FileSystemChange(relocations: [
            .init(from: URL(fileURLWithPath: first), to: URL(fileURLWithPath: moved)),
        ])

        // アプリでの順(BookRecordRelocator.apply): ストアとメタデータ生成を付け替えてから、知らせが届く。
        library.metadata.applyBookRelocation(BookRelocationPlan(bookIDs: [first: moved], locators: [:], directoryBookIDs: []))
        generator.relocate(using: change)
        workspace.followRelocation(BookRelocationNotice(change: change))
        await workspace.settle()

        #expect(workspace.row(first) == nil)
        #expect(workspace.row(moved) != nil)
        #expect(workspace.selection == [moved])
        #expect(workspace.searchText == "月の庭")
        #expect(library.metadata.record(forBookID: moved)?.values.info == "架空の付記")
        #expect(workspace.undoName != nil, "取り消しの歩みが消えた")
        workspace.undo()
        await workspace.settle()
        #expect(library.metadata.record(forBookID: moved)?.values.info != "架空の付記")
    }

    @Test("付け替えの知らせから組み直すまでの間の書き込み(直し・取り消し・ロック)は、新しい bookID の行へ行く(2026-10-04 のレビューの R4-2)")
    func writesBeforeTheListCatchesUpGoToTheNewBookID() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let generator = library.makeMetadataGenerator(books: [first, second])
        generator.start()
        let workspace = await MetadataWorkspace.open(generator: generator, store: library.metadata)
        workspace.set(.info, to: ["架空の付記"], for: [first])
        await workspace.settle()
        let moved = "/書庫/移した先/[架空工房] 月の庭 1.zip"
        let change = FileSystemChange(relocations: [
            .init(from: URL(fileURLWithPath: first), to: URL(fileURLWithPath: moved)),
        ])
        library.metadata.applyBookRelocation(BookRelocationPlan(bookIDs: [first: moved], locators: [:], directoryBookIDs: []))
        generator.relocate(using: change)
        workspace.followRelocation(BookRelocationNotice(change: change))

        // まだ組み直していない(一覧には古い bookID の行が残る)間に、セルを確定する。
        #expect(workspace.row(first) != nil)
        #expect(workspace.setLine(.genre, of: first, at: 0, to: "架空の分類"))
        #expect(library.metadata.metadata(forBookID: first) == nil, "付け替えで空いた古いパスに行を作り直した")
        #expect(library.metadata.record(forBookID: moved)?.edits.fields[.genre] == ["架空の分類"])
        // 取り消しも同じ(古い bookID の行のまま歩みを戻す)。
        workspace.undo()
        #expect(library.metadata.metadata(forBookID: first) == nil)
        #expect(library.metadata.record(forBookID: moved)?.edits.fields[.genre] == nil)
        // ロックも。
        workspace.setLocked([first], true)
        await workspace.settle()
        #expect(library.metadata.metadata(forBookID: first) == nil)
        #expect(library.metadata.record(forBookID: moved)?.isLocked == true)
        #expect(workspace.row(first) == nil)
        #expect(workspace.row(moved)?.isLocked == true)
        #expect(library.metadata.record(forBookID: moved)?.values.info == "架空の付記")
    }

    @Test("一部の本だけ確かめ直したときは、確かめなかった本の「見つからない」を残す(MD-3)")
    func partialExistenceChecksKeepTheOthers() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])
        workspace.setMissing([first])
        #expect(workspace.row(first)?.isMissing == true)

        workspace.setMissing([second], among: [second])
        #expect(workspace.row(first)?.isMissing == true)
        #expect(workspace.row(second)?.isMissing == true)
        workspace.setMissing([], among: [first])
        #expect(workspace.row(first)?.isMissing == false)
        #expect(workspace.row(second)?.isMissing == true)
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

    @Test("以前の「対象外のフォルダ」は読むだけで、シークレットフォルダへ 1 度だけ移して空にする(SecretFolderStore)")
    func legacyExcludedFoldersMoveToSecretFolders() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewerTests.excluded.\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        // 以前の版が書いた設定ファイル(対象外のフォルダを持つ)。
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"rulesDiff":"","stamps":[],"excludedFolders":["/架空/除外"]}"#.utf8).write(to: url)
        let rules = MetadataRulesStore(url: url, legacyDefaults: nil)
        #expect(rules.legacyExcludedFolders == ["/架空/除外"])

        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let secret = SecretFolderStore(defaults: suite.defaults)
        #expect(secret.migrateLegacyExcludedFolders(from: rules) == 1)
        #expect(secret.folders == ["/架空/除外"])
        #expect(secret.hasPendingMigrationNotice)
        // 移した後は設定ファイルからも消える(読み直しても戻らない)。
        #expect(rules.legacyExcludedFolders.isEmpty)
        #expect(MetadataRulesStore(url: url, legacyDefaults: nil).legacyExcludedFolders.isEmpty)
        // 2 度目は何もしない(利用者が外したフォルダを戻さない)。
        secret.remove("/架空/除外")
        secret.markMigrationNoticeShown()
        try Data(#"{"rulesDiff":"","stamps":[],"excludedFolders":["/架空/除外"]}"#.utf8).write(to: url)
        #expect(secret.migrateLegacyExcludedFolders(from: MetadataRulesStore(url: url, legacyDefaults: nil)) == 0)
        #expect(secret.folders.isEmpty)
        #expect(!secret.hasPendingMigrationNotice)
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

    @Test("以前の版の欄の行を埋めるとき、原作・情報の 2 つ目からの値も埋める")
    func outdatedRowsGetEverySourceAndInfoValue() throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let book = "/書庫/[架空工房] 月の庭.zip"
        library.metadata.upsert(bookID: book, author: "架空工房", title: "手で直した題", series: "", seriesIndex: "")
        #expect(library.metadata.outdatedFieldBookIDs == [book])

        library.metadata.fillMissingFields(of: [book]) { _ in
            var read = BookMetadataValues(title: "読んだ題", authors: ["架空工房"])
            read.setAllValues("source", to: ["作品A", "作品B"])
            read.setAllValues("info", to: ["付記A", "付記B", "付記C"])
            return read
        }
        let values = try #require(library.metadata.metadata(forBookID: book)).values
        #expect(values.title == "手で直した題")
        #expect(values.allValues("source") == ["作品A", "作品B"])
        #expect(values.allValues("info") == ["付記A", "付記B", "付記C"])
        #expect(library.metadata.outdatedFieldBookIDs.isEmpty)
    }
}

/// 画面を持たない登録の口(メタデータ生成・`BookMetadataStore.importSourceMetadata`、2026-09-22)。
@MainActor
struct MetadataRegistrationTests {
    private let first = "/書庫/[架空工房] 月の庭 1.zip"
    private let second = "/書庫/[架空工房] 月の庭 2.zip"

    @Test("本を開いたら、メタデータ生成が行の無い本だけをファイル名の読みでロックせずに登録する")
    func openedBooksAreRegisteredByTheGenerator() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        library.metadata.upsert(bookID: second, values: BookMetadataValues(title: "登録した題"))

        let generator = library.makeMetadataGenerator()
        generator.noteBookOpened(first)
        generator.noteBookOpened(second)
        await generator.update()
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

    @Test("メタデータ生成は、ロックしていない行だけを書き直し、直した欄は残す(規則を変えたときの読み直しも同じ)")
    func generatorRewritesOnlyUnlockedRows() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let edits = Confirmation.fields(ConfirmedFields([.info: ["残す付記"]]))
        library.metadata.upsertAll([
            .init(bookID: first, values: BookMetadataValues(title: "古い読み", info: "残す付記"),
                  state: BookMetadataRowState(isLocked: false, edits: edits)),
            .init(bookID: second, values: BookMetadataValues(title: "ロックした題"), state: .locked),
        ])

        await library.makeMetadataGenerator().update()
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
    @Test("外で行が消えたら一覧から外し、行の無い本の知らせでは外さない")
    func onlyBooksWithRowsLeaveTheList() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        library.metadata.upsert(bookID: first, values: BookMetadataValues(title: "登録した題"))
        let workspace = await open(library, [first, second])
        // 窓の知らない本の知らせは何もしない。
        workspace.applyExternalChanges(["/架空/知らない本.zip": BookMetadataRecord?.none])
        #expect(workspace.row(second) != nil)

        library.metadata.delete(forBookID: first)
        workspace.applyExternalChanges([first: BookMetadataRecord?.none])
        await workspace.settle()
        #expect(workspace.row(first) == nil)
    }

    @Test("メタデータ生成は全冊を 1 つの索引で読み、直した本の変化をほかの本の提案にも届ける。行の形はその場で DB に書く")
    func workspaceWritesRowStateImmediately() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])
        workspace.set(.info, to: ["付記"], for: [first])
        // 直した欄はその場で DB に書かれる(値はメタデータ生成が読み直して書く)。
        #expect(library.metadata.record(forBookID: first)?.edits.fields[.info] == ["付記"])
        await workspace.settle()
        #expect(library.metadata.record(forBookID: first)?.values.info == "付記")
        #expect(workspace.row(first)?.metadata.info == "付記")
    }
}

// MARK: - 編集メニューから指した本(2026-09-23)

extension MetadataWorkspaceTests {
    @Test("編集メニューから指した本は、選ばれて「見える位置へ」の頼みが出る。絞り込みで隠れていれば絞り込みを外す")
    func revealSelectsTheBookAndClearsFilters() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])

        #expect(workspace.reveal(second))
        #expect(workspace.selection == [second])
        #expect(workspace.revealRequest?.id == second)
        let firstSerial = try #require(workspace.revealRequest?.serial)

        // ロック済みだけの絞り込みで隠れている本も、絞り込みを外して選ぶ(同じ本へ 2 度目の頼みも通る)。
        workspace.stateFilter = .locked
        #expect(!workspace.rows.contains { $0.id == second })
        #expect(workspace.reveal(second))
        #expect(workspace.stateFilter == .all)
        #expect(workspace.rows.contains { $0.id == second })
        #expect(workspace.selection == [second])
        #expect(workspace.revealRequest?.serial != firstSerial)
    }

    @Test("一覧に無い本(DB に登録の無い本)を指しても、選択は変わらない")
    func revealIgnoresBooksThatAreNotListed() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first])
        workspace.selection = [first]

        #expect(!workspace.reveal("/書庫/知らない本.zip"))
        #expect(workspace.selection == [first])
        #expect(workspace.revealRequest == nil)
    }
}

// MARK: - 1 つの欄に値をいくつも・足したシリーズ(qooMeta 0.3.0。2026-10-01)

extension MetadataWorkspaceTests {
    @Test("欄の段を足す・動かす・消すと DB に届き、鍵を掛けても外しても段は残る")
    func linesOfAFieldReachTheStoreAndSurviveLocking() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])

        workspace.setLine(.info, of: first, at: 0, to: "架空の付記A")
        workspace.setLine(.info, of: first, at: 1, to: "架空の付記B", inserting: true)
        await workspace.settle()
        #expect(workspace.row(first)?.metadata.values(.info) == ["架空の付記A", "架空の付記B"])
        #expect(workspace.row(first)?.tallFields[.info] == 2)
        var stored = try #require(library.metadata.record(forBookID: first))
        #expect(stored.values.info == "架空の付記A")
        #expect(stored.values.values(.info) == ["架空の付記A", "架空の付記B"])

        // 2 段目を選んで上へ。
        workspace.selection = [first]
        workspace.lineSelection = .init(id: first, column: .field(.info), index: 1)
        #expect(workspace.canMoveLine(try #require(workspace.lineSelection), up: true))
        #expect(!workspace.canMoveLine(try #require(workspace.lineSelection), up: false))
        // セルを書き換えている最中は動かさない(書き換えている段は番号で覚えているので、動かすと確定が別の値に入る)。
        workspace.isEditingCell = true
        #expect(!workspace.canMoveLine(try #require(workspace.lineSelection), up: true))
        workspace.moveLine(up: true)
        #expect(workspace.lineSelection?.index == 1)
        workspace.isEditingCell = false
        workspace.moveLine(up: true)
        await workspace.settle()
        #expect(workspace.lineSelection?.index == 0)
        #expect(library.metadata.record(forBookID: first)?.values.values(.info) == ["架空の付記B", "架空の付記A"])

        // 鍵を掛けても外しても、2 段目の値は落ちない(ロックした行は値そのものを確定する)。
        workspace.setLocked([first], true)
        await workspace.settle()
        stored = try #require(library.metadata.record(forBookID: first))
        #expect(stored.isLocked)
        #expect(stored.values.values(.info) == ["架空の付記B", "架空の付記A"])
        #expect(workspace.row(first)?.metadata.values(.info) == ["架空の付記B", "架空の付記A"])
        #expect(!workspace.canMoveLine(.init(id: first, column: .field(.info), index: 1), up: true))
        workspace.setLocked([first], false)
        await workspace.settle()
        #expect(library.metadata.record(forBookID: first)?.values.values(.info) == ["架空の付記B", "架空の付記A"])

        // 空にした段は消え、下の段が繰り上がる。
        workspace.setLine(.info, of: first, at: 0, to: "")
        await workspace.settle()
        #expect(library.metadata.record(forBookID: first)?.values.values(.info) == ["架空の付記A"])
        #expect(workspace.row(first)?.tallFields[.info] == nil)
        // ほかの本は変わらない。
        #expect(workspace.row(second)?.metadata.values(.info) == [])
    }

    @Test("1 つに固定した欄(タイトル・ジャンル・イベント・シリーズ)は、並びで渡しても先頭だけになり、段にならない")
    func singleFieldsKeepOnlyTheFirstValue() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first])
        workspace.set(.genre, to: ["架空ジャンル", "別の架空ジャンル"], for: [first])
        await workspace.settle()
        #expect(workspace.row(first)?.metadata.values(.genre) == ["架空ジャンル"])
        #expect(workspace.row(first)?.tallFields.isEmpty == true)
        #expect(library.metadata.record(forBookID: first)?.edits.fields[.genre] == ["架空ジャンル"])
    }

    @Test("qooMeta の形のまま複数の値・足したシリーズを持つ直した欄は、qooViewer の欄の形に揃えて読む")
    func storedEditsAreRestrictedToQooViewerFields() {
        let fields = ConfirmedFields([.title: ["題名", "別題"], .info: ["付記1", "付記2"]],
                                     alternateSeries: [.init(name: "架空の外伝", volume: "2")])
        let restricted = Confirmation.fields(fields).restrictedToQooViewerFields
        #expect(restricted.fields[.title] == ["題名"])
        #expect(restricted.fields[.info] == ["付記1", "付記2"])
        #expect(restricted.fields.alternateSeries.isEmpty)
        #expect(BookMetadataValues(QMBookMetadata(title: "題名", moreValues: [.title: ["別題"], .info: ["付記2"]],
                                                   alternateSeries: [.init(name: "架空の外伝")]))
            .moreValues == ["info": ["付記2"]])
    }
}

/// 値をいくつも持つ欄の、値の形(`BookMetadataValues`)の約束(2026-10-01、qooMeta 0.3.0。qooViewer では著者・原作・情報だけ)。
struct BookMetadataSeveralValuesTests {
    @Test("先頭を空にすると 2 つ目が繰り上がり、原作・情報のほかの鍵は落ちる")
    func trimmingPromotesTheSecondValue() {
        var values = BookMetadataValues(title: "題名")
        values.setAllValues("info", to: ["付記1", "付記2", "付記3"])
        values.info = "  "
        values.moreValues["title"] = ["別題"]
        values.setAllValues("source", to: ["架空の原作A", "架空の原作B"])
        let trimmed = values.trimmed
        #expect(trimmed.info == "付記2")
        #expect(trimmed.values(.info) == ["付記2", "付記3"])
        #expect(trimmed.values(.title) == ["題名"])
        #expect(trimmed.values(.source) == ["架空の原作A", "架空の原作B"])
        #expect(trimmed.moreValues == ["info": ["付記3"], "source": ["架空の原作B"]])
    }

    @Test("前の版の JSON(新しい鍵が無い)も読め、1 つずつの値は前と同じ形で書く")
    func codableKeepsTheOldShape() throws {
        let old = Data(#"{"title":"題名","authors":["著者"],"genre":"","event":"","source":"","info":"","series":"","volume":""}"#.utf8)
        #expect(try JSONDecoder().decode(BookMetadataValues.self, from: old) == BookMetadataValues(title: "題名", authors: ["著者"]))
        let plain = String(decoding: try JSONEncoder().encode(BookMetadataValues(title: "題名")), as: UTF8.self)
        #expect(!plain.contains("moreValues"))
        var several = BookMetadataValues(title: "題名")
        several.setAllValues("info", to: ["一", "二"])
        #expect(try JSONDecoder().decode(BookMetadataValues.self, from: JSONEncoder().encode(several)) == several)
    }

    @Test("先頭だけを直しても、2 つ目からの値は直した欄に残る。ロックした行の確定した内容も並びごと")
    func editingTheFirstValueKeepsTheRest() {
        var old = BookMetadataValues(title: "題名", series: "シリーズ", volume: "1")
        old.setAllValues("info", to: ["付記1", "付記2"])
        var new = old
        new.info = "直した付記"
        let edits = MetadataParsing.edits(changing: old, to: new, in: .none)
        #expect(edits.fields[.info] == ["直した付記", "付記2"])
        #expect(edits.fields[.title] == nil)
        #expect(old.confirmation.fields[.info] == ["付記1", "付記2"])
        #expect(old.confirmation.fields[.title] == ["題名"])
    }
}

extension MetadataWorkspaceTests {
    @Test("絞り込みで隠れた本は選択から外れ、帯の数とツールバーの相手が揃う(2026-10-04、状態と画面の監査 MD-4)")
    func filteringPrunesTheSelection() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first, second])
        workspace.setLocked([first], true)
        await workspace.settle()
        workspace.selection = [first, second]
        #expect(workspace.selectedBooks.count == 2)

        // 「ロック済み」だけを出すと second が隠れる。以前は選択に残り、帯は「2 冊選択」のまま、ロックは見えている 1 冊にだけ効いた。
        workspace.stateFilter = .locked
        #expect(workspace.selection == [first])
        #expect(workspace.selectedBooks.map(\.id) == [first])

        // 絞り込みを外しても、隠れていた本は選ばれていない(見えないまま選ばれていた本が出てこない)。
        workspace.stateFilter = .all
        #expect(workspace.selection == [first])
    }
}

// MARK: - 2026-10-04、状態と画面の監査の段 8(後半)

extension MetadataWorkspaceTests {
    @Test("段の書き換えの確定は、始めたときの文字の段を探して書く。裏で段が増えても別の段を書き換えず、消えていれば断る(MD-9)")
    func committingALineFollowsItsOriginalText() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first])
        workspace.set(.info, to: ["付記一", "付記二"], for: [first])
        await workspace.settle()

        // 2 段目(付記二)を書き換えている間に、ほかの所で先頭へ段が足された。
        workspace.set(.info, to: ["足した付記", "付記一", "付記二"], for: [first])
        await workspace.settle()
        #expect(workspace.setLine(.info, of: first, at: 1, to: "直した付記", replacing: "付記二"))
        await workspace.settle()
        #expect(workspace.currentValues(.info, of: first) == ["足した付記", "付記一", "直した付記"])

        // 書き換えていた段が裏で消えた → 何も書かない。
        #expect(!workspace.setLine(.info, of: first, at: 0, to: "別の付記", replacing: "消えた付記"))
        #expect(workspace.currentValues(.info, of: first) == ["足した付記", "付記一", "直した付記"])

        // 位置の選び方: 同じ文字の段がいくつかあれば、元の番号にいちばん近いもの。空の文字は足す。
        #expect(MetadataWorkspace.lineToReplace(in: ["甲", "乙", "甲"], at: 2, original: "甲") == 2)
        #expect(MetadataWorkspace.lineToReplace(in: ["乙", "甲", "丙", "甲"], at: 2, original: "甲") == 1)
        #expect(MetadataWorkspace.lineToReplace(in: [], at: 0, original: "") == 0)
        #expect(MetadataWorkspace.lineToReplace(in: ["甲"], at: 0, original: nil) == 0)
    }

    @Test("消したルールセットを指したままの本は、既定のルールセットの名前で数える(MD-13)")
    func aDeletedRuleSetCountsAsTheDefault() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let workspace = await open(library, [first])
        workspace.setRuleSet([first], to: "架空の消したルールセット")
        await workspace.settle()

        #expect(workspace.hasPresetOverride(first))
        #expect(workspace.presetName(for: first) == workspace.formats.defaultName)
    }

    @Test("規則の窓の名前の読めぐあいへ渡す写しは、ルールセットごとに名前を分け、同じ中身では印を進めない(MD-5)")
    func pickedNamesAreSplitByRuleSet() {
        let picked = MetadataRulesPicked()
        picked.set([(name: "名前一", ruleSet: "甲"), (name: "名前二", ruleSet: "乙"), (name: "名前三", ruleSet: "甲")])
        #expect(picked.names(readWith: "甲") == ["名前一", "名前三"])
        #expect(picked.names(readWith: "乙") == ["名前二"])
        #expect(picked.names(readWith: "丙").isEmpty)

        let token = picked.token
        picked.set([(name: "名前一", ruleSet: "甲"), (name: "名前二", ruleSet: "乙"), (name: "名前三", ruleSet: "甲")])
        #expect(picked.token == token, "中身が同じなら読み直させない")
        picked.set([(name: "名前一", ruleSet: "乙"), (name: "名前二", ruleSet: "乙"), (name: "名前三", ruleSet: "甲")])
        #expect(picked.token == token + 1)
        #expect(picked.names(readWith: "乙") == ["名前一", "名前二"])
    }

    @Test("ホームの検索は、原作・情報の 2 つ目からの値でも見つかる(MD-15(b))")
    func homeSearchCoversEveryValue() throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        var values = BookMetadataValues(title: "架空の題")
        values.setAllValues("source", to: ["架空の原作一", "架空の原作二"])
        values.setAllValues("info", to: ["付記一", "付記二"])
        _ = library.metadata.upsert(bookID: first, values: values)

        let text = library.bookTitles.searchableText(forBookID: first)
        #expect(text.contains(LibrarySearchQuery.normalized("架空の原作二")))
        #expect(text.contains(LibrarySearchQuery.normalized("付記二")))
    }
}
