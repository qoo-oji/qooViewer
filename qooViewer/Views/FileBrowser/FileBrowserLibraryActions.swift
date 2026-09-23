import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ファイルブラウザの右クリックと既存機能をつなぐ(改善要望7 段階 8、2026-09-14): コレクションを作成 / コレクションに登録 /
/// スマートライブラリの対象に追加(2026-09-23) /
/// このアプリケーションで開く / メタデータの編集… / 本の書き出し。
///
/// ■ 画像フォルダかどうかは選んだときに調べる
/// 一覧の読み込みでは子フォルダの中を見ない(FileBrowserEntry の型コメント)。フォルダの項目は淡色にせず出しておき、
/// 選んだときに `FileIO` の上で `ShelfFolderResolver` に訊く(右クリックの「開く」と同じ。計画 §3.8)。
/// 本にならないフォルダだったら、そう伝える。
///
/// ■ シークレットウインドウ
/// コレクション・メタデータは保存データへの書き込みなので淡色(決定事項 Q8 の「保存だけしない」)。
/// 本の書き出しはできる(ビューアの右クリックと同じ ―― 書き出し自体は何も記録しない。カバーの選択だけ出さない)。
extension FileBrowserActions {
    // MARK: - 対象

    /// コレクション・メタデータ・書き出しの対象になりうるか。書庫・PDF・EPUB のファイルか、フォルダ(画像フォルダか棚かは
    /// 選んだときに調べる)。画像ファイル 1 枚は本にしない(CollectionDropClassifier と同じ)。
    func canUseAsBooks(_ entries: [FileBrowserEntry]) -> Bool {
        !entries.isEmpty && entries.allSatisfy { !$0.isVolume && ($0.isNavigableFolder || $0.isBookFile) }
    }

    /// 1 冊だけを相手にする操作(メタデータ・書き出し)の対象になりうるか。
    func canUseAsSingleBook(_ entries: [FileBrowserEntry]) -> Bool {
        entries.count == 1 && canUseAsBooks(entries)
    }

    // MARK: - コレクション

    /// 「コレクションを作成」。ウェルカム画面(編集モード)へのドロップと同じ振り分けで、名前を訊くシートを積む
    /// (ばらの本はまとめて 1 つ、棚はフォルダ名で 1 つずつ。WelcomeDropHandling.queueCreations)。
    ///
    /// - Parameter libraryID: 作る先のライブラリ。ライブラリが複数あるときは「コレクションを作成」がサブメニューになり、そこで選ぶ
    ///   (2026-09-21、ユーザー要望。「コレクションに登録」と同じ形)。nil(ライブラリが 1 つ)なら本棚で選んでいるライブラリ。
    /// - Returns: 振り分けの Task(**テストのための口**。待ち合わせに使う)。
    @discardableResult
    func createCollection(from entries: [FileBrowserEntry], libraryID: UUID? = nil) -> Task<Void, Never>? {
        guard isLibraryFeatureEnabled, allowsSaving, canUseAsBooks(entries) else { return nil }
        let urls = entries.map(\.url)
        let order = preferences?.siblingBookOrder ?? .byName
        return Task { [weak self] in
            let classified = await FileIO.perform { CollectionDropClassifier.classify(urls, order: order) }
            // 分類を待っているあいだにライブラリ機能を OFF にされていたら、名前を訊くシートを積まない(2026-09-21 の監査の §4)。
            guard let self, self.isLibraryFeatureEnabled, let welcomeLibrary = self.appState?.welcomeLibrary else { return }
            if !WelcomeDropHandling.queueCreations(from: classified, into: welcomeLibrary, libraryID: libraryID) {
                self.reportNoBooks(in: entries, forCollection: true)
            }
        }
    }

    /// 「コレクションに登録」のサブメニューに並べるコレクション。ライブラリごと、本棚と同じ並び順。
    ///
    /// アイコン表示の右クリックメニューはセルの本体評価のたびに組み立てられる(OpenWithApplications の型コメント)ので、
    /// ストアの通し番号と並び順が変わらない間は同じものを返す。
    func collectionMenuLibraries(locale: Locale) -> [CollectionMenuLibrary] {
        guard let collectionStore else { return [] }
        return CollectionMenuLibrary.libraries(
            in: collectionStore, sort: appState?.welcomeLibrary?.collectionSort ?? .nameAscending, locale: locale,
            cache: &collectionMenuCache
        )
    }

    /// 「コレクションに登録」▸ コレクション。棚はその中の本を展開して入れる(開いているコレクションへのドロップと同じ。
    /// CollectionDropClassifier.booksToAdd)。同じ本が既に入っていれば足さない(CollectionStore.add)。
    ///
    /// - Returns: 登録の Task(**テストのための口**)。
    @discardableResult
    func addToCollection(_ entries: [FileBrowserEntry], collectionID: UUID) -> Task<Void, Never>? {
        guard isLibraryFeatureEnabled, allowsSaving, canUseAsBooks(entries) else { return nil }
        let urls = entries.map(\.url)
        let order = preferences?.siblingBookOrder ?? .byName
        return Task { [weak self] in
            let classified = await FileIO.perform { CollectionDropClassifier.classify(urls, order: order) }
            // 分類を待っているあいだにライブラリ機能を OFF にされていたら登録しない(OFF の間はコレクションの行に触らない。
            // AppStores.applyLibraryFeature。「コレクションを作成」と同じ)。
            guard self?.isLibraryFeatureEnabled == true else { return }
            let books = CollectionDropClassifier.booksToAdd(from: classified)
            guard !books.isEmpty else {
                self?.reportNoBooks(in: entries, forCollection: true)
                return
            }
            guard let result = await CollectionBookAdding.add(
                books, to: collectionID, collectionStore: self?.collectionStore, coverExtractor: self?.coverExtractor,
                isStillEnabled: { [weak self] in self?.isLibraryFeatureEnabled == true }
            ), let self else { return }
            // 本棚ではないので登録しても画面に変化が無い。何が入ったかを短く知らせる(ユーザー要望 2026-09-14)。
            self.state?.showToast(Self.addedToCollectionMessage(
                addedTitles: result.addedTitles, requestedCount: result.requestedCount,
                collectionName: result.collectionName,
                locale: self.preferences?.effectiveLocale ?? .autoupdatingCurrent
            ))
        }
    }

    /// 「コレクションに登録」の後の知らせの文。1 冊なら本の名前、複数なら冊数。既に入っていて足さなかった本
    /// (CollectionStore.add が弾いたもの)があれば、それも分かるようにする。
    static func addedToCollectionMessage(
        addedTitles: [String], requestedCount: Int, collectionName: String, locale: Locale
    ) -> String {
        let addedCount = addedTitles.count
        if addedCount == 0 {
            return String(
                format: String(localized: "Already in the collection “%@”", language: locale), collectionName
            )
        }
        if addedCount < requestedCount {
            return String(
                format: String(localized: "Added %1$lld of %2$lld books to the collection “%3$@” (the rest were already in it)",
                               language: locale),
                addedCount, requestedCount, collectionName
            )
        }
        if addedCount == 1 {
            return String(
                format: String(localized: "Added “%1$@” to the collection “%2$@”", language: locale),
                addedTitles[0], collectionName
            )
        }
        return String(
            format: String(localized: "Added %1$lld books to the collection “%2$@”", language: locale),
            addedCount, collectionName
        )
    }

    // MARK: - スマートライブラリの対象に追加(2026-09-23、利用者の指示)

    /// 「スマートライブラリの対象に追加」を押せるか。フォルダだけ(ファイル・ボリュームが混ざったら淡色)で、まだ対象でないものが
    /// あるとき。対象フォルダは保存データなので、シークレットウインドウでは淡色(「よく使う項目に登録」と同じ)。
    /// **画像フォルダ(1 冊の本)かどうかはここでは調べない**(一覧はフォルダの中を読まない。型コメント「画像フォルダかどうかは
    /// 選んだときに調べる」)。
    func canAddToSmartLibrary(_ entries: [FileBrowserEntry]) -> Bool {
        guard isSmartLibraryFeatureEnabled, allowsSaving, let smartLibraryStore, !entries.isEmpty,
              entries.allSatisfy({ $0.isNavigableFolder && !$0.isVolume })
        else { return false }
        return entries.contains { !smartLibraryStore.containsFolder($0.url) }
    }

    /// 選んだフォルダをスマートライブラリの対象フォルダに足す。1 冊の本になるフォルダ(画像フォルダ・章のフォルダ)は足さない ――
    /// 対象フォルダは「本が並んでいる場所」で、本そのものを足すとその本 1 冊だけの対象になる(ShelfFolderResolver.isSingleBookFolder)。
    /// 全部が本だったら、そう伝える。足したら短く知らせる(ファイルブラウザからはスマートライブラリの画面が見えないので)。
    ///
    /// 読む権限は FolderAccessStore に一本化(スマートライブラリの「フォルダを追加…」と同じ。一覧に見えている時点で読めている)。
    ///
    /// - Returns: 本かどうかを調べて足すまでの Task(**テストのための口**)。
    @discardableResult
    func addToSmartLibrary(_ entries: [FileBrowserEntry]) -> Task<Void, Never>? {
        guard canAddToSmartLibrary(entries), let smartLibraryStore else { return nil }
        let urls = entries.map(\.url)
        let names = entries.filter { !smartLibraryStore.containsFolder($0.url) }.map(\.displayName)
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        return Task { [weak self, weak smartLibraryStore] in
            guard let smartLibraryStore, let result = await SmartLibraryTargetAdding.add(
                urls, store: smartLibraryStore, folderAccess: self?.folderAccess,
                // 調べているあいだにスマートライブラリ機能を OFF にされていたら足さない。
                isFeatureEnabled: { [weak self] in
                    guard let self else { return false }
                    return self.isSmartLibraryFeatureEnabled && self.allowsSaving
                }
            ), let self else { return }
            guard !result.added.isEmpty else {
                self.state?.operations.presenter?.showProblem(Self.bookFolderCannotBeSmartTarget(names: names, locale: locale))
                return
            }
            self.state?.showToast(SmartLibraryTargetAdding.addedMessage(result.added, locale: locale))
        }
    }

    static func bookFolderCannotBeSmartTarget(names: [String], locale: Locale) -> FileBrowserProblem {
        let title = names.count == 1
            ? String(format: String(localized: "“%@” is a book, so it can’t be a target folder.", language: locale), names[0])
            : String(localized: "The selected folders are books, so they can’t be target folders.", language: locale)
        return FileBrowserProblem(
            title: title,
            message: String(localized: "Add the folder that holds the books. Every book in it appears in the smart library.",
                            language: locale)
        )
    }

    // MARK: - このアプリケーションで開く

    /// 右クリックした項目を開けるアプリ(複数選択では先頭の項目の種類で引く)。
    func openWithApplications(for entries: [FileBrowserEntry]) -> [OpenWithApplications.Application] {
        guard let first = entries.first, !first.isVolume else { return [] }
        return OpenWithApplications.shared.applications(for: first.url, isDirectory: first.isDirectory, isPackage: first.isPackage)
    }

    func open(_ entries: [FileBrowserEntry], withApplicationAt application: URL) {
        let urls = entries.filter { !$0.isVolume }.map(\.url)
        guard !urls.isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        Task { [weak self] in
            do {
                _ = try await NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration)
            } catch {
                // 失敗の報告は presenter(ウインドウごと)へ。アプリの起動を待つ間にウインドウが閉じていれば何もしない。
                self?.state?.operations.presenter?.showProblem(
                    Self.openWithFailure(message: error.localizedDescription, application: application, locale: locale)
                )
            }
        }
    }

    /// 「その他…」。アプリケーションフォルダでアプリを選んでもらって開く。LaunchServices の候補に無いアプリは
    /// サンドボックスから開けないことがある(OpenWithApplications の型コメント)。失敗は報告する。
    func chooseApplicationAndOpen(_ entries: [FileBrowserEntry]) {
        guard !entries.isEmpty,
              let application = OpenWithApplications.chooseApplication(locale: preferences?.effectiveLocale ?? .autoupdatingCurrent)
        else { return }
        open(entries, withApplicationAt: application)
    }

    /// 「常にこのアプリケーションで開く」を出してよいか(右クリックで ⌥ を押している間。2026-09-21)。ファイルに既定のアプリを
    /// 書き込む(拡張属性)ので、読み取り専用モードの間は淡色。
    func canAlwaysOpenWith(_ entries: [FileBrowserEntry]) -> Bool {
        allowsFileChanges && !entries.isEmpty && !entries.contains(where: \.isVolume)
    }

    /// 「常にこのアプリケーションで開く」(Finder と同じ: **そのファイルだけ**の既定のアプリにして、そのアプリで開く。同じ種類の
    /// ほかのファイルは変わらない)。`NSWorkspace.setDefaultApplication(at:toOpenFileAt:)` はファイルに拡張属性
    /// `com.apple.LaunchServices.OpenWith` を書く ―― サンドボックスの中から通ることはテストホストで実測(2026-09-21)。
    /// 書けなかった項目(読み取り専用のボリュームなど)は開かずに報告する。
    ///
    /// - Parameters:
    ///   - setDefault: (アプリ, ファイル)。テストで差し替える。
    ///   - thenOpen: 書けた項目を開く。テストで差し替える(nil なら `open(_:withApplicationAt:)`)。
    /// - Returns: 書いて開くまでの Task(テストが待つ)。
    @discardableResult
    func alwaysOpen(
        _ entries: [FileBrowserEntry], withApplicationAt application: URL,
        setDefault: @escaping @MainActor (URL, URL) async throws -> Void = { application, file in
            try await NSWorkspace.shared.setDefaultApplication(at: application, toOpenFileAt: file)
        },
        thenOpen: (@MainActor ([FileBrowserEntry]) -> Void)? = nil
    ) -> Task<Void, Never>? {
        guard canAlwaysOpenWith(entries) else { return nil }
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        return Task { [weak self] in
            var updated: [FileBrowserEntry] = []
            var firstFailure: String?
            for entry in entries {
                do {
                    try await setDefault(application, entry.url)
                    updated.append(entry)
                } catch {
                    if firstFailure == nil { firstFailure = error.localizedDescription }
                }
            }
            guard let self else { return }
            if let firstFailure {
                self.state?.operations.presenter?.showProblem(FileBrowserProblem(
                    title: String(
                        format: String(localized: "“%@” couldn’t be set as the application that always opens the items.", language: locale),
                        FileManager.default.displayName(atPath: application.path)
                    ),
                    message: firstFailure
                ))
            }
            guard !updated.isEmpty else { return }
            if let thenOpen { thenOpen(updated) } else { self.open(updated, withApplicationAt: application) }
        }
    }

    func chooseApplicationAndAlwaysOpen(_ entries: [FileBrowserEntry]) {
        guard canAlwaysOpenWith(entries),
              let application = OpenWithApplications.chooseApplication(locale: preferences?.effectiveLocale ?? .autoupdatingCurrent)
        else { return }
        alwaysOpen(entries, withApplicationAt: application)
    }

    // MARK: - メタデータ・書き出し

    /// 「メタデータの編集…」。コレクションの外の本でも編集できる(カバーの面は出さない。BookMetadataSheet の型コメント)。
    ///
    /// - Parameter notABook: 選んだフォルダが 1 冊の本でなかったときにすること。nil なら「本ではない」と伝える(右クリック)。
    ///   編集メニューからは「メタデータの編集」ウインドウを開く ―― 本でないフォルダを選んでいるだけでメニューの項目が
    ///   ウインドウを開かなくなっていた(2026-09-22、利用者の報告)。
    /// - Returns: フォルダを調べる Task(**テストのための口**。ファイルならその場でシートを出して nil)。
    @discardableResult
    func editMetadata(_ entries: [FileBrowserEntry], notABook: (@MainActor () -> Void)? = nil) -> Task<Void, Never>? {
        guard allowsSaving, canUseAsSingleBook(entries), let entry = entries.first else { return nil }
        return resolveBook(entry, notABook: notABook) { [weak self] _ in
            self?.state?.bookSheet = FileBrowserBookSheet(kind: .metadata(entry))
        }
    }

    /// 「本の書き出し」▸ 形式。保存先の決め方はビューアの右クリックと同じ(ViewerView.startOpenBookExport):
    /// 環境設定「レイアウト」で決めてあれば何も尋ねず、決めていなければ先にフォルダを選んでもらう。
    ///
    /// ビューアと違って「書き出したあとの動作」「保存データ・履歴の削除」はしない ―― どちらも読んでいる本の続きを決める設定で、
    /// 本を開いていないここには当てはまらない(そのうえ同じ本を別のウインドウで開いていると、読書位置を消せない)。
    func exportBook(_ entries: [FileBrowserEntry], format: BookExportFormat) {
        guard canUseAsSingleBook(entries), let entry = entries.first, state?.bookSheet == nil else { return }
        resolveBook(entry) { [weak self] url in
            self?.presentExport(of: url, isDirectory: entry.isDirectory, format: format)
        }
    }

    private func presentExport(of url: URL, isDirectory: Bool, format: BookExportFormat) {
        guard let state, state.bookSheet == nil, let preferences, let bookmarkStore, let layoutStore, let metadataStore,
              let export = FileBrowserBookSheet.Export.make(
                url: url, bookID: url.path, isDirectory: isDirectory, format: format, preferences: preferences,
                bookmarkStore: bookmarkStore, layoutStore: layoutStore, metadataStore: metadataStore
              )
        else { return }
        state.bookSheet = FileBrowserBookSheet(kind: .export(export))
    }

    // MARK: - 下請け

    /// 1 冊として扱える場所を渡す。ファイルはそのまま、フォルダは画像フォルダのときだけ(棚・中間のフォルダは伝えて終わる)。
    @discardableResult
    private func resolveBook(_ entry: FileBrowserEntry, notABook: (@MainActor () -> Void)? = nil,
                             then perform: @escaping @MainActor (URL) -> Void) -> Task<Void, Never>? {
        guard entry.isNavigableFolder else {
            perform(entry.url)
            return nil
        }
        let url = entry.url
        return Task { [weak self] in
            // 子フォルダの中を全部読まず、保護下の場所にも入らない判定(ShelfFolderResolver.isSingleBookFolder。2 回目の監査 15)。
            let isBook = await FileIO.perform { ShelfFolderResolver.isSingleBookFolder(url) }
            if isBook {
                perform(url)
            } else if let notABook {
                notABook()
            } else {
                self?.reportNoBooks(in: [entry], forCollection: false)
            }
        }
    }

    /// - Parameter forCollection: コレクションの操作か。本が並んだフォルダを選べば中の本が入る、の一文はコレクションにだけ当てはまる
    ///   (メタデータ・書き出しで出すと、棚のフォルダでも編集できるように読める。2026-09-14 の実機検証)。
    private func reportNoBooks(in entries: [FileBrowserEntry], forCollection: Bool) {
        state?.operations.presenter?.showProblem(
            Self.noBooksProblem(names: entries.map(\.displayName), forCollection: forCollection,
                                locale: preferences?.effectiveLocale ?? .autoupdatingCurrent)
        )
    }

    static func noBooksProblem(names: [String], forCollection: Bool, locale: Locale) -> FileBrowserProblem {
        let title = names.count == 1
            ? String(format: String(localized: "“%@” isn’t a book.", language: locale), names[0])
            : String(localized: "The selected items aren’t books.", language: locale)
        let message = forCollection
            ? String(
                localized: "Archives, PDF and EPUB files, and folders of images can be used as books. A folder of books adds the books in it.",
                language: locale
            )
            : String(localized: "Archives, PDF and EPUB files, and folders of images can be used as books.", language: locale)
        return FileBrowserProblem(title: title, message: message)
    }

    private static func openWithFailure(message: String, application: URL, locale: Locale) -> FileBrowserProblem {
        FileBrowserProblem(title: OpenWithApplications.failureTitle(application: application, locale: locale), message: message)
    }
}

/// 「コレクションに登録」のサブメニューの 1 ライブラリぶん。
struct CollectionMenuLibrary: Equatable {
    let id: UUID
    let name: String
    let collections: [(id: UUID, name: String)]

    static func == (lhs: CollectionMenuLibrary, rhs: CollectionMenuLibrary) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
            && lhs.collections.map(\.id) == rhs.collections.map(\.id)
            && lhs.collections.map(\.name) == rhs.collections.map(\.name)
    }
}

struct CollectionMenuCache {
    let revision: UInt64
    let sort: FavoritesSortOption
    /// ライブラリの名前を引いた表示言語(既定のライブラリの名前は言語で変わる)。
    let localeIdentifier: String
    let libraries: [CollectionMenuLibrary]
}

extension FileBrowserEntry {
    /// 1 冊の本になるファイル(書庫・PDF・EPUB)。画像ファイルは含まない(登録して開き直せる対象ではない。
    /// CollectionDropClassifier.classifyOne のコメント)。
    var isBookFile: Bool {
        guard !isDirectory else { return false }
        let name = url.lastPathComponent
        return isArchiveFile(name) || isPDFFile(name) || isEpubFile(name)
    }
}

/// 右クリックメニューのうち、中身が場面で変わるサブメニューの項目(段階 8)。リスト・ツリー(AppKit)と
/// アイコン表示(SwiftUI)が同じものを描く。**閉包は FileBrowserActions を weak で持つ**(FileBrowserActions の型コメント)。
enum FileBrowserMenuNode {
    case item(title: String, image: NSImage?, isEnabled: Bool, action: @MainActor () -> Void)
    /// チェックの付く項目(自動リネームの規則。2026-09-15)。押すと `action`(値の反転は受け取る側が決める)。
    case toggle(title: String, isOn: Bool, isEnabled: Bool, action: @MainActor () -> Void)
    case submenu(title: String, isEnabled: Bool, children: [FileBrowserMenuNode])
    case separator
}

extension FileBrowserMenuCommand {
    /// 中身が場面で変わるサブメニュー(コレクションを作成〈ライブラリが複数のとき〉・このアプリケーションで開く・
    /// 常にこのアプリケーションで開く・コレクションに登録・本の書き出し)。
    /// それ以外は nil。
    @MainActor
    func dynamicChildren(
        in context: FileBrowserMenuContext, actions: FileBrowserActions, locale: Locale
    ) -> [FileBrowserMenuNode]? {
        let entries = context.entries
        switch self {
        case .openWith:
            return OpenWithApplications.shared.menuNodes(
                for: actions.openWithApplications(for: entries), locale: locale,
                open: { [weak actions] application in actions?.open(entries, withApplicationAt: application) },
                chooseOther: { [weak actions] in actions?.chooseApplicationAndOpen(entries) }
            )
        case .alwaysOpenWith:
            return OpenWithApplications.shared.menuNodes(
                for: actions.openWithApplications(for: entries), locale: locale,
                open: { [weak actions] application in actions?.alwaysOpen(entries, withApplicationAt: application) },
                chooseOther: { [weak actions] in actions?.chooseApplicationAndAlwaysOpen(entries) }
            )
        case .createCollection:
            // ライブラリが 1 つなら選ぶものが無いので、サブメニューにしない(押すとそのまま名前を訊く)。
            return CollectionMenuLibrary.createMenuNodes(for: actions.collectionMenuLibraries(locale: locale)) {
                [weak actions] libraryID in actions?.createCollection(from: entries, libraryID: libraryID)
            }
        case .addToCollection:
            return CollectionMenuLibrary.addMenuNodes(for: actions.collectionMenuLibraries(locale: locale), locale: locale) {
                [weak actions] collectionID in actions?.addToCollection(entries, collectionID: collectionID)
            }
        case .autoRename:
            return actions.autoRenameMenuNodes(for: entries, locale: locale)
        case .exportBook:
            return BookExportFormat.allCases.map { format in
                .item(
                    title: String(localized: format.menuTitleResource, language: locale), image: nil, isEnabled: true,
                    action: { [weak actions] in actions?.exportBook(entries, format: format) }
                )
            }
        default:
            return nil
        }
    }
}

extension BookExportFormat {
    /// `menuTitleKey` の文字列版(AppKit のメニュー項目用。同じキー)。
    var menuTitleResource: String.LocalizationValue {
        switch self {
        case .epub: "Export This Book as EPUB"
        case .pdf: "Export This Book as PDF"
        case .cbz: "Export This Book as CBZ"
        }
    }
}
