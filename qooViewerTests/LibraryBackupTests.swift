import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// 保存データの JSON を**バックアップとして**往復させる(2026-09-23、利用者の運用: この JSON と
/// コレクション表紙の組を取っておけば、フォルダのアクセス権以外は読み込むだけで環境が戻る)。
///
/// `LibraryImportTests` が見ているのは本ごとのデータ(お気に入り・ブックマーク・レイアウト・
/// メタデータ・コレクション)なので、こちらは 2026-09-23 に足した 4 カテゴリ ―― 読書位置・
/// スマートライブラリ・ファイルブラウザ・環境設定 ―― だけを見る。
///
/// どのストアも `InMemoryLibrary` 専用の `UserDefaults` の領域に載っている(あちらの
/// 「本ごとのデータ以外」のコメント)。**実物のアプリの設定には触れない。**
@MainActor
struct LibraryBackupTests {

    // MARK: - 読書位置

    @Test("読書位置は書き出して取り込むと戻る")
    func readingStatesRoundTrip() async throws {
        let source = try InMemoryLibrary(label: "backup-src")
        defer { source.close() }
        let state = BookReadingState(bookID: "/tmp/book.cbz", lastPageIndex: 12, lastPageKey: "012.png")
        state.displayModeRaw = DisplayMode.single.rawValue
        state.readingDirectionRaw = ReadingDirection.leftToRight.rawValue
        state.scalingModeRaw = ScalingMode.fitWidth.rawValue
        state.isAtLastPage = true
        state.recordedPageCount = 40
        source.context.insert(state)
        try source.context.save()

        let (file, _) = await source.buildExportFile(.everything)
        #expect(file.readingStates?.count == 1)

        let target = try InMemoryLibrary(label: "backup-dst")
        defer { target.close() }
        let summary = await target.apply(file, policies: .all(.merge))
        #expect(summary.readingStatesImportedBooks == 1)

        let imported = try #require(
            ((try? target.context.fetch(FetchDescriptor<BookReadingState>())) ?? []).first
        )
        #expect(imported.bookID == "/tmp/book.cbz")
        #expect(imported.lastPageIndex == 12)
        #expect(imported.lastPageKey == "012.png")
        #expect(imported.displayModeRaw == DisplayMode.single.rawValue)
        #expect(imported.readingDirectionRaw == ReadingDirection.leftToRight.rawValue)
        #expect(imported.scalingModeRaw == ScalingMode.fitWidth.rawValue)
        #expect(imported.isAtLastPage)
        #expect(imported.recordedPageCount == 40)
    }

    @Test("「足す」は既にある読書位置を変えない。「置き換える」は書き替える")
    func readingStatePolicies() async throws {
        let source = try InMemoryLibrary(label: "backup-src")
        defer { source.close() }
        source.context.insert(BookReadingState(bookID: "/tmp/book.cbz", lastPageIndex: 30))
        try source.context.save()
        let (file, _) = await source.buildExportFile(.everything)

        for (policy, expected) in [(LibraryImportExportService.ImportPolicy.merge, 5),
                                   (.overwrite, 30)] {
            let target = try InMemoryLibrary(label: "backup-dst")
            defer { target.close() }
            target.context.insert(BookReadingState(bookID: "/tmp/book.cbz", lastPageIndex: 5))
            try target.context.save()

            await target.apply(file, policies: .all(policy))
            let rows = (try? target.context.fetch(FetchDescriptor<BookReadingState>())) ?? []
            #expect(rows.count == 1)
            #expect(rows.first?.lastPageIndex == expected)
        }
    }

    // MARK: - スマートライブラリ

    @Test("スマートコレクション・対象フォルダ・ピン留めが戻る(フォルダは実在するものだけ)")
    func smartLibraryRoundTrip() async throws {
        let temporary = try TemporaryDirectory("backup-smart")
        let existing = temporary.url.appendingPathComponent("books", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        let source = try InMemoryLibrary(label: "backup-src")
        defer { source.close() }
        let shelf = SmartShelf(name: "未読", conditions: SmartShelfConditions())
        source.smartLibrary.add(shelf)
        source.smartLibrary.addFolder(existing)
        source.smartLibrary.addFolder(temporary.url.appendingPathComponent("gone", isDirectory: true))
        source.smartLibrary.togglePin(.value("SF"), in: .genre)

        let (file, _) = await source.buildExportFile(.everything)
        #expect(file.smartLibrary?.shelves.count == 1)
        // 書き出す時点では、消えたフォルダの登録もそのまま書く(手元の登録をそのまま写す)。
        #expect(file.smartLibrary?.folderPaths.count == 2)

        let target = try InMemoryLibrary(label: "backup-dst")
        defer { target.close() }
        let summary = await target.apply(file, policies: .all(.merge))
        #expect(summary.smartLibraryImportedShelves == 1)
        // 実在するフォルダだけ登録する(コレクションの自動登録フォルダと同じ規則)。
        #expect(summary.smartLibraryImportedFolders == 1)
        #expect(target.smartLibrary.shelves.first?.name == "未読")
        #expect(target.smartLibrary.folders.count == 1)
        #expect(target.smartLibrary.isPinned(.value("SF"), in: .genre))
    }

    // MARK: - ファイルブラウザ

    @Test("よく使う項目と自動リネームの規則が戻り、確認の印は持ち込まれない")
    func fileBrowserRoundTrip() async throws {
        let temporary = try TemporaryDirectory("backup-browser")
        let folder = temporary.url.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let source = try InMemoryLibrary(label: "backup-src")
        defer { source.close() }
        source.favoriteLocations.add(folder)
        let rule = try #require(source.autoRename.addRule())
        source.autoRename.add(
            target: AutoRenameTarget(path: folder.path, volumeUUID: "UUID-OF-THE-OTHER-MAC"),
            toRule: rule.id
        )
        // 「いまその中に何があるかを確認した」印。**別の端末へ持ち込んではいけない**(§8 の 2)。
        source.autoRename.confirm(targetIDs: Set(source.autoRename.rules[0].targets.map(\.id)))
        #expect(source.autoRename.rules[0].targets[0].confirmedSignature != nil)

        let (file, _) = await source.buildExportFile(.everything)
        // 書き出した時点で既に落ちていること(ファイルを覗かれても印が漏れない)。
        let exportedTarget = try #require(file.fileBrowser?.autoRenameRules.first?.rule.targets.first)
        #expect(exportedTarget.confirmedSignature == nil)
        #expect(exportedTarget.volumeUUID == nil)

        let target = try InMemoryLibrary(label: "backup-dst")
        defer { target.close() }
        let summary = await target.apply(file, policies: .all(.merge))
        #expect(summary.fileBrowserImportedLocations == 1)
        #expect(summary.fileBrowserImportedAutoRenameRules == 1)
        // どちらも登録するときにパスを揃える(よく使う項目は standardizedFileURL、自動リネームは canonicalPath)。TemporaryDirectory は
        // 実体の `/private/var/…` を返し、揃えると `/var/…` になるので、期待値も同じ規則で揃える(サンドボックスの無い CI でだけ
        // 食い違った。手元はコンテナの tmp/ で `/private` が付かない。2026-09-23)。
        #expect(target.favoriteLocations.items.first?.path == folder.standardizedFileURL.path)
        let importedTarget = try #require(target.autoRename.rules.first?.targets.first)
        #expect(importedTarget.path == AutoRename.canonicalPath(of: folder))
        #expect(importedTarget.confirmedSignature == nil)
    }

    // MARK: - 環境設定

    @Test("環境設定は、動かしたものが1つ残らず書き出され、取り込むと同じ値に戻る")
    func settingsRoundTrip() async throws {
        let source = try InMemoryLibrary(label: "backup-src")
        defer { source.close() }
        // 出荷時と違う値へ、すべての設定を動かす(下ごしらえは AppPreferencesProbe)。
        mutateEverySetting(source.preferences)
        mutateEveryAppearanceSetting(source.preferences.appearance)
        mutateEveryAppearanceSetting(source.preferences.privateAppearance)
        source.keyBindings.keyBindings["space"] = ViewerAction.moveNext

        let (file, _) = await source.buildExportFile(.everything)
        let exported = try #require(file.settings)

        // **書き出しの網羅**: 動かした設定のキーが 1 つ残らず入っていること。
        // (`SettingsBackup` は接頭辞で拾うので、設定を足しても自動で入る ―― ここが落ちるのは
        //  接頭辞の違うキーを足したときだけ。)
        let changed = source.backupDefaults.dictionaryRepresentation().keys
            .filter { SettingsBackup.isBackupKey($0) }
        for key in changed {
            #expect(exported.values[key] != nil, "\(key) が書き出されていない")
        }

        let target = try InMemoryLibrary(label: "backup-dst")
        defer { target.close() }
        let summary = await target.apply(file, policies: .all(.overwrite))
        #expect(summary.importedSettingsCount == exported.values.count)

        // **取り込みの網羅**: 保存先の値が 1 つ残らず一致すること。
        for key in changed {
            let before = ExportedDefaultsValue(defaultsValue: source.backupDefaults.object(forKey: key) ?? 0)
            let after = ExportedDefaultsValue(defaultsValue: target.backupDefaults.object(forKey: key) ?? 0)
            #expect(before == after, "\(key) が戻っていない")
        }
        // 画面が握っている値も読み直されていること(保存先を書き替えるだけでは変わらない)。
        #expect(target.preferences.slideshowInterval == source.preferences.slideshowInterval)
        #expect(target.preferences.appearance.thumbnailGridCellSize
                == source.preferences.appearance.thumbnailGridCellSize)
        #expect(target.preferences.privateAppearance.thumbnailGridCellSize
                == source.preferences.privateAppearance.thumbnailGridCellSize)
        #expect(target.keyBindings.keyBindings["space"] == ViewerAction.moveNext)
    }

    @Test("範囲の外・種類の違う設定を取り込んでも落ちず、読むときに範囲へ収める(2026-09-23 の 3 回目の監査の中 3)")
    func importedSettingsAreKeptInRange() async throws {
        let library = try InMemoryLibrary(label: "backup-crafted")
        defer { library.close() }
        library.backupDefaults.set(true, forKey: "qooViewer.pref.autoHideCursor")
        let crafted = ExportedSettings(values: [
            "qooViewer.pref.thumbnailHoverPreviewDelay": .double(1e30),
            "qooViewer.pref.prefetchPageCount": .double(-1e300),
            "qooViewer.pref.slideshowInterval": .int(1_000_000),
            "qooViewer.pref.autoHideCursor": .string("yes"),
        ])
        #expect(SettingsBackup.apply(crafted, to: library.backupDefaults) == 3, "種類の違う値は書かない")
        #expect(library.backupDefaults.object(forKey: "qooViewer.pref.autoHideCursor") as? Bool == true)

        let reloaded = AppPreferences(defaults: library.backupDefaults)
        #expect(reloaded.thumbnailHoverPreviewDelay == AppPreferences.thumbnailHoverPreviewDelayRange.upperBound)
        #expect(reloaded.thumbnailHoverPreviewDelayNanoseconds == 1_000_000_000)
        #expect(reloaded.prefetchPageCount == 0)
        #expect(reloaded.slideshowInterval == 30)
    }

    @Test("取り込みは保管件数を下げない(下げると履歴と読書位置が消える。2026-09-23 の 3 回目の監査の中 4)")
    func importDoesNotLowerRetentionLimits() throws {
        let library = try InMemoryLibrary(label: "backup-retention")
        defer { library.close() }
        let preferences = library.preferences
        preferences.recentFilesLimit = 150
        preferences.maxTrackedBooksCount = 1500
        _ = SettingsBackup.apply(ExportedSettings(values: [
            AppPreferences.recentFilesLimitDefaultsKey: .double(20),
            "qooViewer.pref.maxTrackedBooksCount": .double(50),
        ]), to: library.backupDefaults)
        preferences.reloadFromDefaults()
        #expect(preferences.recentFilesLimit == 150)
        #expect(preferences.maxTrackedBooksCount == 1500)
        #expect(library.backupDefaults.double(forKey: AppPreferences.recentFilesLimitDefaultsKey) == 150, "保存先が小さい値のまま")

        // 上げるのは取り込む。
        _ = SettingsBackup.apply(ExportedSettings(values: [AppPreferences.recentFilesLimitDefaultsKey: .double(180)]),
                                 to: library.backupDefaults)
        preferences.reloadFromDefaults()
        #expect(preferences.recentFilesLimit == 180)
    }

    @Test("アクセス権・履歴・そのときの状態は書き出さない")
    func excludedKeysAreNotExported() {
        #expect(!SettingsBackup.isBackupKey(FolderAccessStore.defaultsKey))
        #expect(!SettingsBackup.isBackupKey(FolderSettingBookmarks.defaultsKey))
        #expect(!SettingsBackup.isBackupKey("recentBookEntries"))
        #expect(!SettingsBackup.isBackupKey("qooViewer.lastActiveBookBookmark"))
        #expect(!SettingsBackup.isBackupKey("qooViewer.mainWindowFrame"))
        #expect(!SettingsBackup.isBackupKey(StoreSchemaGuard.defaultsKey))
        // パスを含むものは読める形で別のカテゴリとして書くので、設定としては拾わない。
        #expect(!SettingsBackup.isBackupKey(SmartLibraryStore.defaultsKey))
        #expect(!SettingsBackup.isBackupKey(FavoriteLocationStore.defaultsKey))
        #expect(!SettingsBackup.isBackupKey(AutoRenameStore.defaultsKey))
        // 設定は拾う。
        // 前回のフォルダ・固定の保存先(ブックマークとそのパスの控え)。
        for key in LastUsedFolderMemory.libraryIO.defaultsKeys + LastUsedFolderMemory.fixedExportFolder(.epub).defaultsKeys {
            #expect(!SettingsBackup.isBackupKey(key), "\(key) を書き出す")
        }
        #expect(SettingsBackup.isBackupKey("qooViewer.pref.slideshowInterval"))
        #expect(SettingsBackup.isBackupKey("qooViewer.keyBindings.v1"))
    }

    // MARK: - 古いファイル

    @Test("版 5 までのファイル(新しいカテゴリが無い)を読んでも、何も変わらない")
    func olderFileLeavesNewCategoriesAlone() async throws {
        let library = try InMemoryLibrary(label: "backup-old")
        defer { library.close() }
        library.smartLibrary.add(SmartShelf(name: "手元の棚", conditions: SmartShelfConditions()))
        let before = library.preferences.slideshowInterval

        var file = QooLibraryExportFile()
        file.formatVersion = 5
        await library.apply(file, policies: .all(.overwrite))

        #expect(library.smartLibrary.shelves.count == 1)
        #expect(library.preferences.slideshowInterval == before)
    }
}
