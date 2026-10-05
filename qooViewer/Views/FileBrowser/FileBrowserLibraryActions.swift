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
/// 本の書き出しはできる(ビューアの右クリックと同じ ―― 書き出し自体は保存データを書かない。カバーの選択は淡色、ページ一覧の
/// ディスクキャッシュも読み書きしない)。
extension FileBrowserActions {
    // MARK: - 対象

    /// コレクション・メタデータ・書き出しの対象になりうるか。書庫・PDF・EPUB のファイルか、フォルダ(画像フォルダか棚かは
    /// 選んだときに調べる)。画像ファイル 1 枚は本にしない(CollectionDropClassifier と同じ)。
    /// 記号リンク・エイリアスは解けている先で見る(`effective`。相手も先の項目)。
    func canUseAsBooks(_ entries: [FileBrowserEntry]) -> Bool {
        !entries.isEmpty && entries.allSatisfy {
            let entry = effective($0)
            return !entry.isVolume && (entry.isNavigableFolder || entry.isBookFile)
        }
    }

    /// コレクションに入れられる本を含むか: シークレットフォルダの外の項目が 1 つでもあるか(SecretFolderStore。中の本は
    /// `CollectionStore.makePendingItems` が断るので、全部が中なら「コレクションを作成/に登録」を淡色にする)。
    func canAddToCollections(_ entries: [FileBrowserEntry]) -> Bool {
        canUseAsBooks(entries)
            && entries.contains { secretFolderStore?.contains(path: effective($0).url.path) != true }
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
        guard isLibraryFeatureEnabled, allowsSaving, canAddToCollections(entries) else { return nil }
        let urls = entries.map { effective($0).url }
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
        guard isLibraryFeatureEnabled, allowsSaving, canAddToCollections(entries) else { return nil }
        let urls = entries.map { effective($0).url }
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
                locale: self.preferences?.effectiveLocale ?? .autoupdatingCurrent,
                skippedSecretCount: result.skippedSecretCount
            ))
        }
    }

    /// 「コレクションに登録」の後の知らせの文。1 冊なら本の名前、複数なら冊数。既に入っていて足さなかった本
    /// (CollectionStore.add が弾いたもの)があれば、それも分かるようにする。
    static func addedToCollectionMessage(
        addedTitles: [String], requestedCount: Int, collectionName: String, locale: Locale, skippedSecretCount: Int = 0
    ) -> String {
        // シークレットフォルダの本を入れなかったことを添える(CollectionStore.makePendingItems)。
        guard skippedSecretCount == 0 else {
            let secret = CollectionStore.secretBooksNotAddedMessage(count: skippedSecretCount, locale: locale)
            guard requestedCount > 0 else { return secret }
            return addedToCollectionMessage(
                addedTitles: addedTitles, requestedCount: requestedCount, collectionName: collectionName, locale: locale
            ) + " " + secret
        }
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
              entries.allSatisfy({ let entry = effective($0); return entry.isNavigableFolder && !entry.isVolume })
        else { return false }
        // シークレットフォルダそのもの・その中だけなら淡色(2026-10-04 の監査 X-7。SmartLibraryTargetAdding.isRefusedAsSecret)。
        return entries.contains {
            let url = effective($0).url
            return !smartLibraryStore.containsFolder(url) && !SmartLibraryTargetAdding.isRefusedAsSecret(url)
        }
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
        let urls = entries.map { effective($0).url }
        // 断った本のフォルダを、一覧に出ている名前で言うため(下の `bookFolderCannotBeSmartTarget`)。
        let nameByURL = Dictionary(entries.map { (effective($0).url, $0.displayName) }, uniquingKeysWith: { first, _ in first })
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
                if result.refusedBooks.isEmpty, !result.refusedSecret.isEmpty {
                    self.state?.showToast(SmartLibraryTargetAdding.secretRefusedMessage(result.refusedSecret, locale: locale))
                } else {
                    // 「本なので足せない」と言うのは本だったフォルダだけ。シークレットフォルダも一緒に選んでいたら、それは別の理由
                    // として添える(以前は選んだフォルダの名前を全部並べ、シークレットフォルダも「本」と書いた。2026-10-04 の
                    // レビューの R6-5)。
                    let names = result.refusedBooks.map { nameByURL[$0] ?? $0.lastPathComponent }
                    self.state?.operations.presenter?.showProblem(Self.bookFolderCannotBeSmartTarget(
                        names: names, secretRefused: result.refusedSecret, locale: locale
                    ))
                }
                return
            }
            // 一緒に選んだシークレットフォルダは足していない。そう添える(X-7)。
            var message = SmartLibraryTargetAdding.addedMessage(result.added, locale: locale)
            if !result.refusedSecret.isEmpty {
                message += "\n" + SmartLibraryTargetAdding.secretRefusedMessage(result.refusedSecret, locale: locale)
            }
            self.state?.showToast(message)
        }
    }

    /// - Parameter secretRefused: 一緒に選んでいて、シークレットフォルダなので足さなかったフォルダ。あれば説明に添える(R6-5)。
    static func bookFolderCannotBeSmartTarget(
        names: [String], secretRefused: [URL] = [], locale: Locale
    ) -> FileBrowserProblem {
        let title = names.count == 1
            ? String(format: String(localized: "“%@” is a book, so it can’t be a target folder.", language: locale), names[0])
            : String(localized: "The selected folders are books, so they can’t be target folders.", language: locale)
        var message = String(localized: "Add the folder that holds the books. Every book in it appears in the smart library.",
                             language: locale)
        if !secretRefused.isEmpty {
            message += "\n\n" + SmartLibraryTargetAdding.secretRefusedMessage(secretRefused, locale: locale)
        }
        return FileBrowserProblem(title: title, message: message)
    }

    // MARK: - このアプリケーションで開く

    /// 右クリックした項目を開けるアプリ(複数選択では先頭の項目の種類で引く。記号リンク・エイリアスは先の種類 ―― Finder と同じ)。
    func openWithApplications(for entries: [FileBrowserEntry]) -> [OpenWithApplications.Application] {
        guard let first = entries.first.map(effective), !first.isVolume else { return [] }
        return OpenWithApplications.shared.applications(for: first.url, isDirectory: first.isDirectory, isPackage: first.isPackage)
    }

    /// 記号リンク・エイリアスは先を渡す(LaunchServices はリンクも解くが、先の種類で選んだアプリに先を渡す方が確か)。
    func open(_ entries: [FileBrowserEntry], withApplicationAt application: URL) {
        let urls = entries.filter { !$0.isVolume }.map { effective($0).url }
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
        OpenWithApplications.chooseApplication(locale: preferences?.effectiveLocale ?? .autoupdatingCurrent) { [weak self] application in
            self?.open(entries, withApplicationAt: application)
        }
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
                    // 記号リンク・エイリアスは先に書く(開くときも先を渡すので、拡張属性は先に無いと効かない)。
                    try await setDefault(application, self?.effective(entry).url ?? entry.url)
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
        guard canAlwaysOpenWith(entries) else { return }
        OpenWithApplications.chooseApplication(locale: preferences?.effectiveLocale ?? .autoupdatingCurrent) { [weak self] application in
            // パネルはシートなので、選んでいる間に読み取り専用へ切り替わりうる。
            guard let self, canAlwaysOpenWith(entries) else { return }
            alwaysOpen(entries, withApplicationAt: application)
        }
    }

    // MARK: - メタデータ・書き出し

    /// 「メタデータの編集…」。コレクションの外の本でも編集できる。**その項目を選んでインスペクタ(ホームの右ペイン)を出し、題の欄へ
    /// 焦点を入れる**(2026-09-30、利用者の指示。以前は 1 冊ぶんのシート `BookMetadataSheet` を出していた)。
    ///
    /// - Parameter notABook: 選んだフォルダが 1 冊の本でなかったときにすること。nil なら「本ではない」と伝える(右クリック)。
    ///   編集メニューからは「メタデータの編集」ウインドウを開く ―― 本でないフォルダを選んでいるだけでメニューの項目が
    ///   ウインドウを開かなくなっていた(2026-09-22、利用者の報告)。
    /// - Returns: フォルダを調べる Task(**テストのための口**。ファイルならその場でインスペクタを出して nil)。
    @discardableResult
    func editMetadata(_ entries: [FileBrowserEntry], notABook: (@MainActor () -> Void)? = nil) -> Task<Void, Never>? {
        guard allowsSaving, canUseAsSingleBook(entries), let selected = entries.first else { return nil }
        let entry = effective(selected)
        return resolveBook(entry, notABook: notABook) { [weak self] url in
            // 選ぶのは一覧の項目そのもの(リンクなら先は別のフォルダにあり、一覧に無い)。インスペクタはリンクを先の本として見せる。
            guard let self, let state = self.state else { return }
            state.selection = [selected.id]
            state.setSelectionAnchor(selected.id)
            self.appState?.welcomeLibrary?.revealInspector(editingMetadataOf: url.path)
        }
    }

    /// 「本の書き出し」▸ 形式。保存先の決め方はビューアの右クリックと同じ(ViewerView.startOpenBookExport):
    /// 環境設定「レイアウト」で決めてあれば何も尋ねず、決めていなければ先にフォルダを選んでもらう。
    ///
    /// ビューアと違って「書き出したあとの動作」「保存データ・履歴の削除」はしない ―― どちらも読んでいる本の続きを決める設定で、
    /// 本を開いていないここには当てはまらない(そのうえ同じ本を別のウインドウで開いていると、読書位置を消せない)。
    func exportBook(_ entries: [FileBrowserEntry], format: BookExportFormat) {
        guard canUseAsSingleBook(entries), let entry = entries.first.map(effective), state?.bookSheet == nil else { return }
        resolveBook(entry) { [weak self] url in
            self?.presentExport(of: url, isDirectory: entry.isDirectory, format: format)
        }
    }

    private func presentExport(of url: URL, isDirectory: Bool, format: BookExportFormat) {
        guard let state, state.bookSheet == nil, let preferences, let bookmarkStore, let layoutStore, let metadataStore
        else { return }
        let usesPageListCache = allowsSaving
        Task { @MainActor [weak state] in
            guard let export = await FileBrowserBookSheet.Export.make(
                url: url, bookID: url.path, isDirectory: isDirectory, format: format, preferences: preferences,
                bookmarkStore: bookmarkStore, layoutStore: layoutStore, metadataStore: metadataStore,
                usesPageListCache: usesPageListCache
            ) else { return }
            // フォルダを選んでいる間(シート)に別の頼みが入っていれば、そちらを残す。
            guard let state, state.bookSheet == nil else { return }
            state.bookSheet = FileBrowserBookSheet(kind: .export(export))
        }
    }

    // MARK: - 下請け

    /// 1 冊として扱える場所を渡す。ファイルはそのまま、フォルダは画像フォルダのときだけ(棚・中間のフォルダは伝えて終わる)。
    @discardableResult
    private func resolveBook(_ entry: FileBrowserEntry, notABook: (@MainActor () -> Void)? = nil,
                             then perform: @escaping @MainActor (URL) -> Void) -> Task<Void, Never>? {
        let entry = effective(entry)
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
