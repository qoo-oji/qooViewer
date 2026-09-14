import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ファイルブラウザの右クリックと既存機能をつなぐ(改善要望7 段階 8、2026-09-14): コレクションを作成 / コレクションに登録 /
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
    /// 作る先は本棚で選んでいるライブラリ。
    ///
    /// - Returns: 振り分けの Task(**テストのための口**。待ち合わせに使う)。
    @discardableResult
    func createCollection(from entries: [FileBrowserEntry]) -> Task<Void, Never>? {
        guard allowsSaving, canUseAsBooks(entries) else { return nil }
        let urls = entries.map(\.url)
        let order = preferences?.siblingBookOrder ?? .byName
        return Task { [weak self] in
            let classified = await FileIO.perform { CollectionDropClassifier.classify(urls, order: order) }
            guard let self, let welcomeLibrary = self.appState?.welcomeLibrary else { return }
            if !WelcomeDropHandling.queueCreations(from: classified, into: welcomeLibrary) {
                self.reportNoBooks(in: entries)
            }
        }
    }

    /// 「コレクションに登録」のサブメニューに並べるコレクション。ライブラリごと、本棚と同じ並び順。
    ///
    /// アイコン表示の右クリックメニューはセルの本体評価のたびに組み立てられる(OpenWithApplications の型コメント)ので、
    /// ストアの通し番号と並び順が変わらない間は同じものを返す。
    func collectionMenuLibraries() -> [CollectionMenuLibrary] {
        guard let collectionStore else { return [] }
        let sort = appState?.welcomeLibrary?.collectionSort ?? .nameAscending
        if let cached = collectionMenuCache, cached.revision == collectionStore.revision, cached.sort == sort {
            return cached.libraries
        }
        let libraries = collectionStore.libraries.map { library in
            CollectionMenuLibrary(
                id: library.id, name: library.name,
                collections: collectionStore.collections(in: library, sort: sort).map { ($0.id, $0.name) }
            )
        }
        collectionMenuCache = CollectionMenuCache(revision: collectionStore.revision, sort: sort, libraries: libraries)
        return libraries
    }

    /// 「コレクションに登録」▸ コレクション。棚はその中の本を展開して入れる(開いているコレクションへのドロップと同じ。
    /// CollectionDropClassifier.booksToAdd)。同じ本が既に入っていれば足さない(CollectionStore.add)。
    ///
    /// - Returns: 登録の Task(**テストのための口**)。
    @discardableResult
    func addToCollection(_ entries: [FileBrowserEntry], collectionID: UUID) -> Task<Void, Never>? {
        guard allowsSaving, canUseAsBooks(entries) else { return nil }
        let urls = entries.map(\.url)
        let order = preferences?.siblingBookOrder ?? .byName
        return Task { [weak self] in
            let classified = await FileIO.perform { CollectionDropClassifier.classify(urls, order: order) }
            let books = CollectionDropClassifier.booksToAdd(from: classified)
            guard !books.isEmpty else {
                self?.reportNoBooks(in: entries)
                return
            }
            // ブックマークの生成はメインアクターの外で(CollectionStore.makePendingItemsのコメント)。
            let pending = await CollectionStore.makePendingItems(for: books)
            // 待っている間に消されたコレクションには足さない(idで引き直す。WelcomeDropHandling.handle と同じ)。
            guard let self, let collectionStore = self.collectionStore,
                  let collection = collectionStore.collection(withID: collectionID), !pending.isEmpty
            else { return }
            // 足してから表紙の抽出を頼む。`coverExtractor?.enqueue(store.add(...))` と 1 行で書くと、抽出役が居ないときに
            // 引数ごと評価されず、本が足されない(テストで踏んだ)。
            let added = collectionStore.add(pending, to: collection)
            self.coverExtractor?.enqueue(added)
        }
    }

    // MARK: - このアプリケーションで開く

    /// 右クリックした項目を開けるアプリ(複数選択では先頭の項目の種類で引く)。
    func openWithApplications(for entries: [FileBrowserEntry]) -> [OpenWithApplications.Application] {
        guard let first = entries.first, !first.isVolume else { return [] }
        return OpenWithApplications.shared.applications(for: first.url, isDirectory: first.isDirectory)
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
        guard !entries.isEmpty else { return }
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = String(localized: "Open", language: locale)
        panel.message = String(localized: "Choose an application to open the selected items.", language: locale)
        guard panel.runModal() == .OK, let application = panel.url else { return }
        open(entries, withApplicationAt: application)
    }

    // MARK: - メタデータ・書き出し

    /// 「メタデータの編集…」。コレクションの外の本でも編集できる(カバーの面は出さない。BookMetadataSheet の型コメント)。
    ///
    /// - Returns: フォルダを調べる Task(**テストのための口**。ファイルならその場でシートを出して nil)。
    @discardableResult
    func editMetadata(_ entries: [FileBrowserEntry]) -> Task<Void, Never>? {
        guard allowsSaving, canUseAsSingleBook(entries), let entry = entries.first else { return nil }
        return resolveBook(entry) { [weak self] url in
            self?.state?.bookSheet = FileBrowserBookSheet(kind: .metadata(url))
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
        guard let state, state.bookSheet == nil, let preferences, let bookmarkStore, let layoutStore, let metadataStore else {
            return
        }
        let viewModel = format.makeExportViewModel(
            bookmarkStore: bookmarkStore, layoutStore: layoutStore, metadataStore: metadataStore,
            preferences: preferences, loadsEligibleRows: false
        )
        let book = MangaBook(
            id: url.path, title: CollectionStore.itemTitle(for: url, isDirectory: isDirectory),
            sourceURL: url, pages: []
        )
        let destination: OpenBookExportSheet.Destination
        let asks: Bool
        if preferences.bookExportDestinationMode(for: format) == .fixedFolder, let fixed = format.fixedFolder.lastFolder() {
            destination = .init(url: fixed, isSecurityScoped: true)
            asks = false
        } else {
            guard let chosen = ExportDestinationPanel.present(
                for: format, startingAt: nil, locale: preferences.effectiveLocale
            ) else { return }
            destination = .init(url: chosen, isSecurityScoped: false)
            asks = true
        }
        state.bookSheet = FileBrowserBookSheet(kind: .export(.init(
            format: format, viewModel: viewModel, book: book, destination: destination, asksBeforeExporting: asks
        )))
    }

    // MARK: - 下請け

    /// 1 冊として扱える場所を渡す。ファイルはそのまま、フォルダは画像フォルダのときだけ(棚・中間のフォルダは伝えて終わる)。
    @discardableResult
    private func resolveBook(_ entry: FileBrowserEntry, then perform: @escaping @MainActor (URL) -> Void) -> Task<Void, Never>? {
        guard entry.isNavigableFolder else {
            perform(entry.url)
            return nil
        }
        let url = entry.url
        let order = preferences?.siblingBookOrder ?? .byName
        return Task { [weak self] in
            let isBook = await FileIO.perform { () -> Bool in
                if case .book = ShelfFolderResolver.role(of: url, order: order) { return true }
                return false
            }
            if isBook {
                perform(url)
            } else {
                self?.reportNoBooks(in: [entry])
            }
        }
    }

    private func reportNoBooks(in entries: [FileBrowserEntry]) {
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        let title = entries.count == 1
            ? String(format: String(localized: "“%@” isn’t a book.", language: locale), entries[0].displayName)
            : String(localized: "The selected items aren’t books.", language: locale)
        state?.operations.presenter?.showProblem(FileBrowserProblem(
            title: title,
            message: String(
                localized: "Archives, PDF and EPUB files, and folders of images can be used as books. A folder of books adds the books in it.",
                language: locale
            )
        ))
    }

    private static func openWithFailure(message: String, application: URL, locale: Locale) -> FileBrowserProblem {
        FileBrowserProblem(
            title: String(
                format: String(localized: "The items couldn’t be opened with “%@”.", language: locale),
                FileManager.default.displayName(atPath: application.path)
            ),
            message: message
        )
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
    case submenu(title: String, isEnabled: Bool, children: [FileBrowserMenuNode])
    case separator
}

extension FileBrowserMenuCommand {
    /// 中身が場面で変わるサブメニュー(このアプリケーションで開く・コレクションに登録・本の書き出し)。それ以外は nil。
    @MainActor
    func dynamicChildren(
        in context: FileBrowserMenuContext, actions: FileBrowserActions, locale: Locale
    ) -> [FileBrowserMenuNode]? {
        let entries = context.entries
        switch self {
        case .openWith:
            let applications = actions.openWithApplications(for: entries)
            var nodes: [FileBrowserMenuNode] = applications.map { application in
                let title = application.isDefault
                    ? String(format: String(localized: "%@ (default)", language: locale), application.name)
                    : application.name
                return .item(
                    title: title, image: OpenWithApplications.shared.icon(for: application), isEnabled: true,
                    action: { [weak actions] in actions?.open(entries, withApplicationAt: application.url) }
                )
            }
            if let first = applications.first, first.isDefault, applications.count > 1 {
                nodes.insert(.separator, at: 1)
            }
            if !nodes.isEmpty { nodes.append(.separator) }
            nodes.append(.item(
                title: String(localized: "Other…", language: locale), image: nil, isEnabled: true,
                action: { [weak actions] in actions?.chooseApplicationAndOpen(entries) }
            ))
            return nodes
        case .addToCollection:
            let libraries = actions.collectionMenuLibraries()
            func collectionItems(_ library: CollectionMenuLibrary) -> [FileBrowserMenuNode] {
                guard !library.collections.isEmpty else {
                    return [.item(
                        title: String(localized: "No Collections", language: locale), image: nil, isEnabled: false, action: {}
                    )]
                }
                return library.collections.map { collection in
                    .item(
                        title: collection.name, image: nil, isEnabled: true,
                        action: { [weak actions] in actions?.addToCollection(entries, collectionID: collection.id) }
                    )
                }
            }
            // ライブラリが 1 つなら 1 段で並べる(ライブラリの名前を見せる意味が無い)。
            if libraries.count == 1, let only = libraries.first { return collectionItems(only) }
            return libraries.map { library in
                .submenu(title: library.name, isEnabled: true, children: collectionItems(library))
            }
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
