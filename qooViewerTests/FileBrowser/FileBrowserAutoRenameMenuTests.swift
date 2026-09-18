import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザの右クリックの「自動リネーム」(Views/FileBrowser/FileBrowserAutoRenameActions.swift)。
@MainActor
struct FileBrowserAutoRenameMenuTests {
    final class Fixture {
        let temporary: TemporaryDirectory
        let suite = PreferencesSuite(label: "fb-auto-rename-menu")
        let preferences: AppPreferences
        let favorites: FavoriteLocationStore
        let store: AutoRenameStore
        let service: AutoRenameService
        let appState: AppState
        let actions = FileBrowserActions()

        init(isPrivate: Bool = false) throws {
            temporary = try TemporaryDirectory("fb-auto-rename-menu")
            preferences = suite.makePreferences()
            favorites = FavoriteLocationStore(defaults: suite.defaults)
            store = AutoRenameStore(defaults: suite.defaults)
            service = AutoRenameService(
                store: store, log: AutoRenameActivityLog(defaults: suite.defaults), favorites: favorites,
                preferences: preferences, hasAccess: { _ in true }
            )
            appState = AppState(isPrivateWindow: isPrivate, usesPageListCache: false)
            actions.appState = appState
            actions.favoriteLocations = favorites
            actions.autoRenameStore = store
            actions.autoRenameService = service
        }

        func entry(_ url: URL, isDirectory: Bool = true) -> FileBrowserEntry {
            FileBrowserEntry(
                url: url, displayName: url.lastPathComponent, isDirectory: isDirectory, isPackage: false,
                isSymbolicLink: false, isVolume: false, fileSize: nil, typeDescription: nil, creationDate: nil,
                modificationDate: nil
            )
        }
    }

    private let english = Locale(identifier: "en")

    @Test("よく使う項目の配下のフォルダ 1 つだけで押せる。ファイル・複数・よく使う項目の外・シークレットウインドウでは淡色")
    func availability() throws {
        let fixture = try Fixture()
        let library = try fixture.temporary.directory("library")
        let shelf = try fixture.temporary.directory("library/shelf")
        let outside = try fixture.temporary.directory("outside")
        fixture.favorites.add(library)
        #expect(fixture.actions.canConfigureAutoRename([fixture.entry(shelf)]))
        #expect(fixture.actions.canConfigureAutoRename([fixture.entry(library)]))
        #expect(!fixture.actions.canConfigureAutoRename([fixture.entry(outside)]))
        #expect(!fixture.actions.canConfigureAutoRename([fixture.entry(shelf), fixture.entry(library)]))
        #expect(!fixture.actions.canConfigureAutoRename([fixture.entry(shelf.appendingPathComponent("a.zip"), isDirectory: false)]))
        #expect(FileBrowserMenuCommand.groups(for: .folder).joined().contains(.autoRename))
        #expect(FileBrowserMenuCommand.groups(for: .tree).joined().contains(.autoRename))
        #expect(!FileBrowserMenuCommand.groups(for: .file).joined().contains(.autoRename))

        let privateFixture = try Fixture(isPrivate: true)
        let privateLibrary = try privateFixture.temporary.directory("library")
        privateFixture.favorites.add(privateLibrary)
        #expect(!privateFixture.actions.canConfigureAutoRename([privateFixture.entry(privateLibrary)]))
    }

    @Test("サブメニューは規則ごとのチェックと、規則の作成・設定。チェックで対象に入れ、もう一度で外す")
    func submenuTogglesTargets() async throws {
        let fixture = try Fixture()
        let library = try fixture.temporary.directory("library")
        fixture.favorites.add(library)
        var rule = try #require(fixture.store.addRule())
        rule.find = "x"
        fixture.store.update(rule: rule)
        let context = FileBrowserMenuContext(kind: .folder, entries: [fixture.entry(library)], folder: nil)

        func toggles() -> [(String, Bool)] {
            (FileBrowserMenuCommand.autoRename.dynamicChildren(in: context, actions: fixture.actions, locale: english) ?? [])
                .compactMap { if case .toggle(let title, let isOn, _, _) = $0 { return (title, isOn) } else { return nil } }
        }
        let nodes = FileBrowserMenuCommand.autoRename.dynamicChildren(in: context, actions: fixture.actions, locale: english) ?? []
        let itemTitles = nodes.compactMap { if case .item(let title, _, _, _) = $0 { return title } else { return nil } }
        #expect(itemTitles == ["New Rule for This Folder…", "Auto Rename Settings…"])
        #expect(toggles().map(\.1) == [false])

        // 入れるほうはブックマークを作る I/O を挟む。時間で見張らず、その Task の完了を待つ
        // (以前は 5 秒の期限で見張っていて、CI の混んだ機では期限を過ぎて落ちた)。
        let adding = try #require(fixture.actions.toggleAutoRename(folder: library, ruleID: rule.id))
        await adding.value
        #expect(fixture.store.rule(withID: rule.id)?.targets.first?.path == AutoRename.canonicalPath(library.path))
        #expect(fixture.store.rule(withID: rule.id)?.targets.first?.bookmark != nil)
        #expect(toggles().map(\.1) == [true])

        // 外すほうはその場で済む(Task は返らない)。
        #expect(fixture.actions.toggleAutoRename(folder: library, ruleID: rule.id) == nil)
        #expect(fixture.store.rule(withID: rule.id)?.targets.isEmpty == true)
    }

    @Test("「このフォルダの規則を作成…」は、このフォルダを対象に入れた規則を作る")
    func createRuleForFolder() async throws {
        let fixture = try Fixture()
        let library = try fixture.temporary.directory("library")
        fixture.favorites.add(library)
        let creating = try #require(fixture.actions.createAutoRenameRule(for: library))
        await creating.value
        #expect(fixture.store.rules.count == 1)
        #expect(fixture.store.rules.first?.targets.map(\.path) == [AutoRename.canonicalPath(library.path)])
        #expect(fixture.service.requestedRuleID == fixture.store.rules.first?.id)
    }

    @Test("規則に足せないフォルダ(よく使う項目の外)は足さない")
    func ineligibleFolderIsRefused() async throws {
        let fixture = try Fixture()
        let outside = try fixture.temporary.directory("outside")
        let rule = try #require(fixture.store.addRule())
        let result = await fixture.service.addTarget(folder: outside, toRule: rule.id)
        #expect(result == .ineligible(.outsideFavorites))
        #expect(fixture.store.rule(withID: rule.id)?.targets.isEmpty == true)
    }
}
