import Darwin
import Foundation
import Testing

@testable import qooViewer

/// 自動リネームの実行役(Services/AutoRename/)。一時フォルダ(コンテナの中)に合成名の項目を置き、本物の FSEvents と名前の変更で確かめる。
/// 設計は docs/plans/auto-rename-study.md。
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct AutoRenameServiceTests {
    /// 1 テストぶんの道具一式。
    final class Harness {
        let temporary: TemporaryDirectory
        let suite = PreferencesSuite(label: "auto-rename")
        let preferences: AppPreferences
        let favorites: FavoriteLocationStore
        let store: AutoRenameStore
        let log: AutoRenameActivityLog
        let service: AutoRenameService
        var inUse: [String] = []
        var access = true

        init(_ label: String) throws {
            temporary = try TemporaryDirectory("auto-rename-\(label)")
            preferences = suite.makePreferences()
            preferences.fileBrowserReadOnly = false
            favorites = FavoriteLocationStore(defaults: suite.defaults)
            store = AutoRenameStore(defaults: suite.defaults)
            log = AutoRenameActivityLog(defaults: suite.defaults)
            var box: Harness?
            service = AutoRenameService(
                store: store, log: log, favorites: favorites, preferences: preferences,
                hasAccess: { _ in box?.access ?? true },
                inUsePaths: { box?.inUse ?? [] },
                locale: { Locale(identifier: "en") }
            )
            service.coalescingDelay = 0.05
            service.recheckDelay = 0.2
            service.missingConfirmationDelay = 0.2
            service.inUseRecheckDelay = 0.3
            box = self
        }

        deinit {
            MainActor.assumeIsolated { service.stop() }
        }

        func folder(_ relative: String) throws -> URL {
            try temporary.directory(relative)
        }

        @discardableResult
        func file(_ relative: String, modifiedAgo: TimeInterval = 60) throws -> URL {
            let url = temporary.url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: url)
            let date = Date().addingTimeInterval(-modifiedAgo)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: temporary.url.appendingPathComponent(relative).path)
        }

        /// 規則を 1 つ足して対象を付ける。
        @discardableResult
        func addRule(
            find: String, replace: String, target: URL, includesSubfolders: Bool = true, includesFolders: Bool = false,
            confirmed: Bool = true
        ) -> AutoRenameRule {
            var rule = store.addRule()!
            rule.find = find
            rule.replaceWith = replace
            rule.includesFolders = includesFolders
            store.update(rule: rule)
            let (volume, bookmark) = AutoRenameService.volumeAndBookmark(for: target.path)
            var newTarget = AutoRenameTarget(path: target.path, volumeUUID: volume, bookmark: bookmark, includesSubfolders: includesSubfolders)
            let saved = store.rule(withID: rule.id)!
            if confirmed { newTarget.confirmedSignature = newTarget.signature(for: saved) }
            store.add(target: newTarget, toRule: rule.id)
            return store.rule(withID: rule.id)!
        }
    }

    /// 条件がそろうまで待つ(FSEvents と見直しは時間で届く)。
    private func eventually(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: - 計画

    @Test("計画: 出発点は祖先の対象だけ。対象の祖先へは降り、サブフォルダを含めない対象の下へは降りない")
    func planRootsAndDescent() {
        let text = AutoRename.RuleText(find: "a", replaceWith: "b")
        let plan = AutoRenamePlan(
            rules: [.init(id: UUID(), name: "1", text: text), .init(id: UUID(), name: "2", text: text)],
            targets: [
                .init(id: UUID(), ruleIndex: 0, path: "/Volumes/X/A", includesSubfolders: false),
                .init(id: UUID(), ruleIndex: 1, path: "/Volumes/X/A/B/C", includesSubfolders: true),
            ]
        )
        #expect(plan.roots == ["/Volumes/X/A"])
        #expect(plan.shouldDescend(into: "/Volumes/X/A/B"))
        #expect(!plan.shouldDescend(into: "/Volumes/X/A/Other"))
        #expect(plan.ruleIndices(forFolder: "/Volumes/X/A") == [0])
        #expect(plan.ruleIndices(forFolder: "/Volumes/X/A/B") == [])
        #expect(plan.ruleIndices(forFolder: "/Volumes/X/A/B/C/D") == [1])
    }

    // MARK: - 名前の変更

    @Test("確認済みの対象では、今ある項目の名前をサブフォルダまで変え、実行ログに残す")
    func renamesExistingItemsOfConfirmedTargets() async throws {
        let harness = try Harness("existing")
        let shelf = try harness.folder("shelf")
        try harness.file("shelf/one [tag].zip")
        try harness.file("shelf/sub/two [tag].zip")
        harness.favorites.add(shelf)
        harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()

        #expect(await eventually { harness.exists("shelf/one.zip") && harness.exists("shelf/sub/two.zip") })
        #expect(!harness.exists("shelf/one [tag].zip"))
        // 実行ログはフォルダ 1 つぶんの結果ごとにまとめて書くので、名前が変わった直後にはまだ無いことがある。
        #expect(await eventually {
            harness.log.entries.contains { $0.originalName == "one [tag].zip" && $0.outcome == .renamed(newName: "one.zip") }
        })
    }

    @Test("未確認の対象は、変わる項目があれば確認を待ち、確認するまで変えない。変わる項目が無ければ黙って確認済みにする")
    func unconfirmedTargetsWaitForConfirmation() async throws {
        let harness = try Harness("confirm")
        let shelf = try harness.folder("shelf")
        let empty = try harness.folder("empty")
        try harness.file("shelf/one [tag].zip")
        harness.favorites.add(shelf)
        harness.favorites.add(empty)
        let rule = harness.addRule(find: " [tag]", replace: "", target: shelf, confirmed: false)
        let quiet = harness.addRule(find: " [tag]", replace: "", target: empty, confirmed: false)
        harness.service.start()
        let targetID = try #require(rule.targets.first?.id)

        #expect(await eventually { harness.service.targetsAwaitingConfirmation == [targetID] })
        #expect(await eventually { harness.store.rule(withID: quiet.id)?.targets.first.map { $0.isConfirmed(for: quiet) } == true })
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.exists("shelf/one [tag].zip"), "確認する前に変えた")

        let preview = await harness.service.preview(targetIDs: [targetID])
        #expect(preview.map(\.newName) == ["one.zip"])
        harness.service.confirm(targetIDs: [targetID])
        #expect(await eventually { harness.exists("shelf/one.zip") })
    }

    @Test("新しく置かれた項目と、同じボリュームの中からフォルダごと移ってきた項目の中身を変える")
    func renamesNewItemsAndContentsOfMovedInFolders() async throws {
        let harness = try Harness("events")
        let shelf = try harness.folder("shelf")
        harness.favorites.add(shelf)
        harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()
        await harness.service.waitUntilIdle()

        try harness.file("shelf/new [tag].zip")
        #expect(await eventually { harness.exists("shelf/new.zip") })

        // 外で中身を作ってから、フォルダごと移す(中身のイベントは来ない ―― 検討メモ §9.1)。
        try harness.file("outside/series/inner [tag].zip")
        try FileManager.default.moveItem(
            at: harness.temporary.url.appendingPathComponent("outside/series"), to: shelf.appendingPathComponent("series")
        )
        #expect(await eventually { harness.exists("shelf/series/inner.zip") })
    }

    @Test("フォルダの名前は「フォルダの名前も変える」規則だけが変え、中身を変えてから変える。サブフォルダを含めなければ直下だけ")
    func folderRulesAndSubfolderScope() async throws {
        let harness = try Harness("folders")
        let shelf = try harness.folder("shelf")
        let flat = try harness.folder("flat")
        try harness.file("shelf/dir [tag]/page [tag].jpg")
        try harness.file("flat/top [tag].zip")
        try harness.file("flat/deep/inner [tag].zip")
        harness.favorites.add(shelf)
        harness.favorites.add(flat)
        harness.addRule(find: " [tag]", replace: "", target: shelf, includesFolders: true)
        harness.addRule(find: " [tag]", replace: "", target: flat, includesSubfolders: false)
        harness.service.start()

        #expect(await eventually { harness.exists("shelf/dir/page.jpg") })
        #expect(await eventually { harness.exists("flat/top.zip") })
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.exists("flat/deep/inner [tag].zip"))
    }

    @Test("フォルダの名前も変える規則でも、規則の無いフォルダの名前は変えない(既定は OFF)")
    func foldersAreLeftAloneByDefault() async throws {
        let harness = try Harness("folders-off")
        let shelf = try harness.folder("shelf")
        try harness.file("shelf/dir [tag]/page.jpg")
        harness.favorites.add(shelf)
        harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()
        await harness.service.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.exists("shelf/dir [tag]/page.jpg"))
    }

    @Test("拡張子を置き換える規則と、テキストを追加する規則を順にかける")
    func extensionAndAddTextRules() async throws {
        let harness = try Harness("extension")
        let shelf = try harness.folder("shelf")
        try harness.file("shelf/book.zip")
        harness.favorites.add(shelf)
        var ext = harness.store.addRule()!
        ext.find = "zip"
        ext.replaceWith = "cbz"
        ext.replaceScope = .fileExtension
        harness.store.update(rule: ext)
        var add = harness.store.addRule()!
        add.operation = .addText
        add.addedText = "[x] "
        add.addPlacement = .beforeName
        harness.store.update(rule: add)
        for id in [ext.id, add.id] {
            harness.store.add(target: AutoRenameTarget(path: shelf.path), toRule: id)
        }
        harness.store.confirm(targetIDs: Set(harness.store.rules.flatMap(\.targets).map(\.id)))
        harness.service.start()
        #expect(await eventually { harness.exists("shelf/[x] book.cbz") })
        try await Task.sleep(for: .milliseconds(400))
        #expect(!harness.exists("shelf/[x] [x] book.cbz"), "付け直し続けた")
    }

    @Test("重なる名前は name 2 で避ける")
    func collisionsAreAvoided() async throws {
        let harness = try Harness("collision")
        let shelf = try harness.folder("shelf")
        try harness.file("shelf/one.zip")
        try harness.file("shelf/one [tag].zip")
        harness.favorites.add(shelf)
        harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()
        #expect(await eventually { harness.exists("shelf/one 2.zip") })
        #expect(harness.exists("shelf/one.zip"))
    }

    @Test("変え続ける規則は変えず、実行ログに 1 回だけ残す")
    func growingRuleIsLoggedOnce() async throws {
        let harness = try Harness("growing")
        let shelf = try harness.folder("shelf")
        try harness.file("shelf/a.zip")
        harness.favorites.add(shelf)
        harness.addRule(find: "a", replace: "aa", target: shelf)
        harness.service.start()
        #expect(await eventually { !harness.log.entries.isEmpty })
        harness.service.refreshAvailability(thenScanEverything: true)
        await harness.service.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.exists("shelf/a.zip"))
        #expect(harness.log.entries.count == 1)
        guard case .skipped? = harness.log.entries.first?.outcome else {
            Issue.record("見送りとして残っていない")
            return
        }
    }

    @Test("実行ログから元の名前に戻すと、その項目は規則でまた変えない。別の項目に置き換わっていたら戻さない")
    func restoringFromTheLogExcludesTheItem() async throws {
        let harness = try Harness("restore")
        let shelf = try harness.folder("shelf")
        try harness.file("shelf/one [tag].zip")
        try harness.file("shelf/two [tag].zip")
        harness.favorites.add(shelf)
        harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()
        #expect(await eventually { harness.exists("shelf/one.zip") && harness.exists("shelf/two.zip") })
        #expect(await eventually { harness.log.entries.filter(\.isRestorable).count == 2 })

        let one = try #require(harness.log.entries.first { $0.originalName == "one [tag].zip" })
        let two = try #require(harness.log.entries.first { $0.originalName == "two [tag].zip" })
        // two は名前を変えた後で別の項目に置き換える。
        try FileManager.default.removeItem(at: shelf.appendingPathComponent("two.zip"))
        try harness.file("shelf/two.zip")

        let problem = await harness.service.restore(entryIDs: [one.id, two.id])
        #expect(problem != nil)
        #expect(harness.exists("shelf/one [tag].zip"))
        #expect(harness.exists("shelf/two.zip"))
        #expect(harness.store.excludedPaths == [AutoRename.canonicalPath(shelf.appendingPathComponent("one [tag].zip").path)])
        #expect(harness.log.entries.first { $0.id == one.id }?.outcome == .restored(fromName: "one.zip"))

        // 規則をもう一度走らせても戻した名前は変えない。
        harness.service.refreshAvailability(thenScanEverything: true)
        await harness.service.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.exists("shelf/one [tag].zip"))
    }

    /// 2026-09-21 の監査の L4。「元の名前に戻す」も名前の変更なのに、読み取り専用の間でも戻せていた。
    @Test("読み取り専用モードの間は、実行ログから元の名前に戻さず、そう報告する")
    func restoringIsRefusedInReadOnlyMode() async throws {
        let harness = try Harness("restore-read-only")
        let shelf = try harness.folder("shelf")
        try harness.file("shelf/one [tag].zip")
        harness.favorites.add(shelf)
        harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()
        #expect(await eventually { harness.log.entries.contains(where: \.isRestorable) })
        let one = try #require(harness.log.entries.first { $0.originalName == "one [tag].zip" })

        harness.preferences.fileBrowserReadOnly = true
        let problem = await harness.service.restore(entryIDs: [one.id])
        #expect(problem != nil)
        #expect(harness.exists("shelf/one.zip"))
        #expect(harness.store.excludedPaths.isEmpty)
        #expect(harness.log.entries.first { $0.id == one.id }?.isRestorable == true)
    }

    // MARK: - 変えない場面

    @Test("読み取り専用モードの間は変えず、OFF にしたら変える")
    func readOnlyModePauses() async throws {
        let harness = try Harness("read-only")
        let shelf = try harness.folder("shelf")
        try harness.file("shelf/one [tag].zip")
        harness.favorites.add(shelf)
        harness.preferences.fileBrowserReadOnly = true
        harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()
        await harness.service.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.service.isPausedForReadOnly)
        #expect(harness.exists("shelf/one [tag].zip"))

        harness.preferences.fileBrowserReadOnly = false
        #expect(await eventually { harness.exists("shelf/one.zip") })
    }

    @Test("よく使う項目の外では止め、よく使う項目に戻されたら再開する")
    func outsideFavoritesPausesUntilReAdded() async throws {
        let harness = try Harness("favorites")
        let shelf = try harness.folder("shelf")
        try harness.file("shelf/one [tag].zip")
        let rule = harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()
        let targetID = try #require(rule.targets.first?.id)
        #expect(await eventually { harness.service.availability[targetID] == .outsideFavorites })
        #expect(harness.exists("shelf/one [tag].zip"))
        #expect(harness.store.rule(withID: rule.id)?.targets.first?.state == .enabled, "状態は変えない")

        harness.favorites.add(harness.temporary.url)
        #expect(await eventually { harness.exists("shelf/one.zip") })
    }

    @Test("ビューアで開いている本は、閉じるまで変えない")
    func booksInUseWait() async throws {
        let harness = try Harness("in-use")
        let shelf = try harness.folder("shelf")
        let book = try harness.file("shelf/one [tag].zip")
        harness.favorites.add(shelf)
        harness.inUse = [book.path]
        harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()
        await harness.service.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(500))
        #expect(harness.exists("shelf/one [tag].zip"))
        harness.inUse = []
        #expect(await eventually { harness.exists("shelf/one.zip") })
    }

    @Test("Finder のコピー中の印がある間は変えない")
    func finderCopyInProgressWaits() async throws {
        let harness = try Harness("finder-copy")
        let shelf = try harness.folder("shelf")
        let file = try harness.file("shelf/one [tag].zip")
        var info = [UInt8](repeating: 0, count: 32)
        info.replaceSubrange(0..<8, with: AutoRenameFileSystem.finderCopyMarker)
        #expect(setxattr(file.path, "com.apple.FinderInfo", info, info.count, 0, 0) == 0)
        harness.favorites.add(shelf)
        harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()
        try await Task.sleep(for: .milliseconds(700))
        #expect(harness.exists("shelf/one [tag].zip"))
        #expect(removexattr(file.path, "com.apple.FinderInfo", 0) == 0)
        #expect(await eventually { harness.exists("shelf/one.zip") })
    }

    // MARK: - 見つからない対象

    @Test("フォルダが消えたら、置いた時間の後にその対象だけを OFF にし、移動先を提案する。更新すると元の状態に戻り確認し直す")
    func missingTargetIsTurnedOffAndMoveIsSuggested() async throws {
        let harness = try Harness("missing")
        let library = try harness.folder("library")
        let shelf = try harness.folder("library/shelf")
        let other = try harness.folder("library/keep")
        try harness.file("library/shelf/one.zip")
        harness.favorites.add(library)
        let rule = harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.addRule(find: " [tag]", replace: "", target: other)
        harness.service.start()
        let targetID = try #require(rule.targets.first?.id)
        #expect(await eventually { harness.service.availability[targetID] == .available })

        try FileManager.default.moveItem(at: shelf, to: library.appendingPathComponent("moved"))
        #expect(await eventually { harness.store.rule(withID: rule.id)?.targets.first?.state == .disabledMissing })
        #expect(harness.store.rules[1].targets.first?.state == .enabled, "ほかの対象は変えない")
        #expect(await eventually { harness.service.moveSuggestions.first?.status == .updatable })
        let suggestion = try #require(harness.service.moveSuggestions.first)
        #expect(suggestion.foundPath == AutoRename.canonicalPath(library.appendingPathComponent("moved").path))

        await harness.service.applyMoveSuggestions([suggestion])
        let updated = try #require(harness.store.rule(withID: rule.id)?.targets.first)
        #expect(updated.path == AutoRename.canonicalPath(library.appendingPathComponent("moved").path))
        #expect(updated.state == .enabled)
        #expect(await eventually { harness.service.moveSuggestions.isEmpty })
    }

    @Test("ゴミ箱へ入れたフォルダは更新できない提案になる。同じ場所に戻っても自動では ON にしない")
    func trashedTargetIsNotUpdatable() async throws {
        let harness = try Harness("trash")
        let library = try harness.folder("library")
        let shelf = try harness.folder("library/shelf")
        harness.favorites.add(library)
        let rule = harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()
        try FileManager.default.createDirectory(at: library.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: shelf, to: library.appendingPathComponent(".Trash/shelf"))
        #expect(await eventually { harness.service.moveSuggestions.first?.status == .inTrash })

        try FileManager.default.moveItem(at: library.appendingPathComponent(".Trash/shelf"), to: shelf)
        harness.service.refreshAvailability()
        await harness.service.waitUntilIdle()
        #expect(harness.store.rule(withID: rule.id)?.targets.first?.state == .disabledMissing)
    }

    @Test("登録したときと別のボリュームの上なら、フォルダが無くても削除扱いにしない")
    func otherVolumeIsNotConnectedRatherThanMissing() async throws {
        let harness = try Harness("volume")
        let library = try harness.folder("library")
        harness.favorites.add(library)
        var rule = harness.store.addRule()!
        rule.find = "x"
        harness.store.update(rule: rule)
        let target = AutoRenameTarget(path: library.appendingPathComponent("gone").path, volumeUUID: "another-volume")
        harness.store.add(target: target, toRule: rule.id)
        harness.service.start()
        #expect(await eventually { harness.service.availability[target.id] == .volumeNotConnected })
        try await Task.sleep(for: .milliseconds(500))
        harness.service.refreshAvailability()
        await harness.service.waitUntilIdle()
        #expect(harness.store.rule(withID: rule.id)?.targets.first?.state == .enabled)
    }

    @Test("権限の無い対象は止めるだけで OFF にしない")
    func noAccessPauses() async throws {
        let harness = try Harness("access")
        let shelf = try harness.folder("shelf")
        try harness.file("shelf/one [tag].zip")
        harness.favorites.add(shelf)
        harness.access = false
        let rule = harness.addRule(find: " [tag]", replace: "", target: shelf)
        harness.service.start()
        let targetID = try #require(rule.targets.first?.id)
        #expect(await eventually { harness.service.availability[targetID] == .noAccess })
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.exists("shelf/one [tag].zip"))
        #expect(harness.store.rule(withID: rule.id)?.targets.first?.state == .enabled)
    }

    // MARK: - 止める・また動かす(環境設定「ファイルブラウザを有効にする」。2026-09-21 の監査 docs/plans/feature-toggle-audit.md の F1・F2)

    @Test("止まっている間は、外から状態の読み直しやイベントが届いても何もしない。公開している値も空にする")
    func doesNothingWhileStopped() async throws {
        let harness = try Harness("stopped")
        let shelf = try harness.folder("shelf")
        let pending = try harness.folder("pending")
        try harness.file("pending/old [tag].zip")
        harness.favorites.add(shelf)
        harness.favorites.add(pending)
        harness.addRule(find: " [tag]", replace: "", target: shelf)
        let unconfirmed = harness.addRule(find: " [tag]", replace: "", target: pending, confirmed: false)
        harness.service.start()
        #expect(await eventually { harness.service.targetsAwaitingConfirmation == [unconfirmed.targets[0].id] })
        await harness.service.waitUntilIdle()
        #expect(!harness.service.availability.isEmpty)

        harness.service.stop()
        #expect(!harness.service.isStarted)
        #expect(harness.service.availability.isEmpty)
        #expect(harness.service.targetsAwaitingConfirmation.isEmpty)

        // 設定ウインドウの「アクセスを許可」・移動の提案の「更新」が呼ぶ口と、遅れて届いた FSEvents。
        try harness.file("shelf/new [tag].zip")
        harness.service.refreshAvailability()
        harness.service.refreshAvailability(thenScanEverything: true)
        harness.service.handle([.init(path: shelf.appendingPathComponent("new [tag].zip").path, mustScanSubdirectories: false)])
        harness.service.handle([.init(path: shelf.path, mustScanSubdirectories: true)])
        await harness.service.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.exists("shelf/new [tag].zip"), "止まっている間に名前を変えた")
        #expect(harness.service.availability.isEmpty)
        #expect(!harness.service.hasPendingRechecks)

        // また動かすと、止まっている間に置かれた項目を拾う。
        harness.service.start()
        #expect(await eventually { harness.exists("shelf/new.zip") })
    }

    @Test("走査を予約した直後に止めても、また動かせば走査する(取り消した予約が残って二度と走らなくならない)")
    func restartsAfterStoppingWithScheduledWork() async throws {
        let harness = try Harness("restart")
        let shelf = try harness.folder("shelf")
        harness.favorites.add(shelf)
        harness.addRule(find: " [tag]", replace: "", target: shelf)
        // 予約が確実に残っているうちに止められるよう、まとめる時間を長くする。
        harness.service.coalescingDelay = 0.5
        harness.service.start()
        await harness.service.waitUntilIdle()

        try harness.file("shelf/one [tag].zip")
        harness.service.handle([.init(path: shelf.appendingPathComponent("one [tag].zip").path, mustScanSubdirectories: false)])
        harness.service.stop()
        try await Task.sleep(for: .milliseconds(700))
        #expect(harness.exists("shelf/one [tag].zip"), "止めた後に予約が走った")

        harness.service.coalescingDelay = 0.05
        harness.service.start()
        #expect(await eventually { harness.exists("shelf/one.zip") })
        // 再開した後の FSEvents でも走る(予約の変数が取り消した Task を指したままだと、ここが動かない)。
        await harness.service.waitUntilIdle()
        try harness.file("shelf/two [tag].zip")
        #expect(await eventually { harness.exists("shelf/two.zip") })
    }

    @Test("状態を確かめている最中に止めると、その結果で監視や走査を始めない。すぐ動かし直しても二重にならず動く")
    func stoppingDuringTheAvailabilityPass() async throws {
        let harness = try Harness("mid-pass")
        let shelf = try harness.folder("shelf")
        try harness.file("shelf/one [tag].zip")
        harness.favorites.add(shelf)
        harness.addRule(find: " [tag]", replace: "", target: shelf)

        // start の直後は最初のパスが FileIO の上で待っている。
        harness.service.start()
        harness.service.stop()
        try await Task.sleep(for: .milliseconds(500))
        #expect(harness.exists("shelf/one [tag].zip"), "止めた後に名前を変えた")
        #expect(harness.service.availability.isEmpty)

        harness.service.start()
        harness.service.stop()
        harness.service.start()
        #expect(await eventually { harness.exists("shelf/one.zip") })
    }

    // MARK: - 保存

    @Test("元の名前に戻した除外は、親の名前の変更・移動に付いていき、項目自身の名前の変更では外れる(2026-09-22 の監査)")
    func excludedPathsFollowAncestorsButNotOwnRenames() {
        let suite = PreferencesSuite(label: "auto-rename-excluded")
        let store = AutoRenameStore(defaults: suite.defaults)
        store.exclude(path: "/Volumes/X/shelf/kept.cbz")
        store.exclude(path: "/Volumes/X/shelf/renamed.cbz")
        store.exclude(path: "/Volumes/X/other/moved.cbz")

        store.relocateExcludedPaths(using: FileSystemChange(relocations: [
            .init(from: URL(fileURLWithPath: "/Volumes/X/shelf"), to: URL(fileURLWithPath: "/Volumes/X/shelf-2")),
            .init(from: URL(fileURLWithPath: "/Volumes/X/shelf-2/renamed.cbz"), to: URL(fileURLWithPath: "/Volumes/X/shelf-2/new-name.cbz")),
            .init(from: URL(fileURLWithPath: "/Volumes/X/other/moved.cbz"), to: URL(fileURLWithPath: "/Volumes/X/elsewhere/moved.cbz")),
        ]))

        #expect(store.excludedPaths == ["/Volumes/X/shelf-2/kept.cbz", "/Volumes/X/shelf/renamed.cbz", "/Volumes/X/elsewhere/moved.cbz"])
        #expect(AutoRenameStore(defaults: suite.defaults).excludedPaths == store.excludedPaths)
    }

    @Test("対象フォルダはアプリの中での名前の変更に付いていき、確認済みなら確認の印も付け直す(2026-09-22 の監査)")
    func targetsFollowInAppRenames() throws {
        let suite = PreferencesSuite(label: "auto-rename-relocate")
        let store = AutoRenameStore(defaults: suite.defaults)
        let temporary = try TemporaryDirectory("auto-rename-relocate")
        let folder = try temporary.directory("target")
        var rule = try #require(store.addRule())
        rule.find = "a"
        store.update(rule: rule)
        let current = try #require(store.rule(withID: rule.id))
        var target = AutoRenameTarget(path: folder.path)
        target.confirmedSignature = target.signature(for: current)
        #expect(store.add(target: target, toRule: rule.id))
        let renamed = temporary.file("target-renamed")

        #expect(store.relocateTargets(using: FileSystemChange(relocations: [.init(from: folder, to: renamed)])))

        let relocated = try #require(store.rules.first?.targets.first)
        #expect(relocated.path == AutoRename.canonicalPath(renamed.path))
        #expect(relocated.confirmedSignature == relocated.signature(for: try #require(store.rule(withID: rule.id))))
    }

    @Test("規則を OFF にすると確認の印が消える。保存して読み直せば同じ")
    func storePersistsAndClearsConfirmation() throws {
        let suite = PreferencesSuite(label: "auto-rename-store")
        let store = AutoRenameStore(defaults: suite.defaults)
        var rule = try #require(store.addRule())
        rule.find = "a"
        store.update(rule: rule)
        var target = AutoRenameTarget(path: "/Volumes/X/A")
        target.confirmedSignature = target.signature(for: try #require(store.rule(withID: rule.id)))
        #expect(store.add(target: target, toRule: rule.id))
        #expect(!store.add(target: AutoRenameTarget(path: "/Volumes/X/A/"), toRule: rule.id), "同じパスは足さない")

        var disabled = try #require(store.rule(withID: rule.id))
        disabled.isEnabled = false
        store.update(rule: disabled)
        #expect(store.rules.first?.targets.first?.confirmedSignature == nil)

        let reloaded = AutoRenameStore(defaults: suite.defaults)
        #expect(reloaded.rules == store.rules)
        for _ in 1..<AutoRename.maxRules { store.addRule() }
        #expect(store.addRule() == nil, "上限")
    }
}
