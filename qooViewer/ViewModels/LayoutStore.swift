import Foundation
import SwiftData
import Combine

/// 本の内容が前回保存時から差し替わっていそうかどうかの判定結果。
/// LayoutStore.checkContentReplacement(book:)が返す。
///
/// 設計コンセプト2.5節: ページ数が一致している場合(更新日時・ファイルサイズのみ不一致)は
/// 「そのまま適用する/破棄する」の2択、ページ数自体が異なる場合は「破棄する」のみを提示する
/// (ファイル名キーの誤対応を避けるため)。呼び出し側(ビューア起動シーケンス)がこの結果に
/// 応じて確認ダイアログの選択肢を出し分ける。
enum LayoutContentReplacementStatus: Equatable {
    /// 差し替えの疑いなし。この本にレイアウト設定自体が存在しない場合もこれを返す
    /// (保護すべきデータが無いため確認不要)。
    case unaffected
    /// 差し替えの疑いあり。
    case possiblyReplaced(pageCountMatches: Bool)
}

/// ページレイアウト設定(BookLayoutSettings: 本全体の設定、PageLayoutOverride: ページ単位の設定)の
/// 永続化・操作を、特定の本に限らず横断的に担当する。BookmarkStoreと同じ設計(SwiftDataを
/// 直接操作し、変更をNotification.Name.layoutDataDidChange経由で他のウインドウ/
/// ViewerViewModelへ伝える)を踏襲する。
///
/// このクラス自体は「本を開いているかどうか」を意識しない。今開いている本への反映は
/// ViewerViewModel側がlayoutDataDidChangeを購読して行う(Bookmark.swift/BookmarkStoreの
/// bookmarksDidChangeと同じ考え方)。
@MainActor
final class LayoutStore: ObservableObject {
    private let modelContext: ModelContext

    /// 「レイアウト情報がある本」のbookID一覧(4.1節の絞り込みドロップダウン用)。
    /// 本全体設定(BookLayoutSettings)が「実質的に空」(isBookLevelSettingEmpty)で、かつ
    /// ページ単位設定(PageLayoutOverride)も1件も無い本は含めない(EPUBロックのキャッシュだけの
    /// 行など、ユーザー由来のデータが実質無い本を「レイアウト情報がある本」として数えないため)。
    /// LayoutStoreは(BookmarkStoreと異なり)アプリ全体で共有される単一インスタンスとして
    /// ViewerViewModelにも直接渡されるため、すべての変更がこのインスタンスを経由する。
    /// そのためBookmarkStoreのような通知の自己購読は不要で、各更新メソッドの最後で
    /// reloadLayoutBookIDs()を呼ぶだけで常に最新の状態を保てる。
    @Published private(set) var layoutBookIDs: Set<String> = []

    /// bookLayoutSettings(forBookID:)/pageOverrides(forBookID:)等が呼ばれるたびに絞り込み無しの
    /// 全件フェッチをやり直さずに済むよう、直近の全件フェッチ結果をキャッシュしておく。
    /// nilは「キャッシュ無効(次回読み取り時に再フェッチが必要)」を表す。
    ///
    /// このクラスがBookLayoutSettings/PageLayoutOverrideの唯一の書き込み口であり
    /// (このファイル冒頭のコメント参照。専用のModelContextを持ち、他のストアとは互いに素)、
    /// insert/deleteのたびに必ずinvalidateLayoutCaches()を呼んで即座に無効化しているため、
    /// 「挿入/削除した直後、save()より前に読み直す」場合(#if DEBUGの診断ログ等)も含めて、
    /// 常にmodelContext.fetch()を直接呼んでいた場合と同じ結果になる(書き込みが無い間だけ
    /// キャッシュが再利用され、フェッチが省略される)。
    private var cachedSettings: [BookLayoutSettings]?
    private var cachedOverrides: [PageLayoutOverride]?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        reloadLayoutBookIDs()
    }

    /// 絞り込み無しの全BookLayoutSettingsを返す(キャッシュがあれば再利用)。
    private func allBookLayoutSettings() -> [BookLayoutSettings] {
        if let cachedSettings { return cachedSettings }
        let fetched = (try? modelContext.fetch(FetchDescriptor<BookLayoutSettings>())) ?? []
        cachedSettings = fetched
        return fetched
    }

    /// 絞り込み無しの全PageLayoutOverrideを返す(キャッシュがあれば再利用)。
    private func allPageLayoutOverrides() -> [PageLayoutOverride] {
        if let cachedOverrides { return cachedOverrides }
        let fetched = (try? modelContext.fetch(FetchDescriptor<PageLayoutOverride>())) ?? []
        cachedOverrides = fetched
        return fetched
    }

    /// BookLayoutSettings/PageLayoutOverrideをinsert/deleteするたびに直後で呼ぶ。次回の
    /// allBookLayoutSettings()/allPageLayoutOverrides()呼び出しで必ず再フェッチさせる。
    private func invalidateLayoutCaches() {
        cachedSettings = nil
        cachedOverrides = nil
    }

    private func reloadLayoutBookIDs() {
        let allSettings = allBookLayoutSettings()
        let allOverrides = allPageLayoutOverrides()
        var ids = Set(allSettings.filter { !$0.isBookLevelSettingEmpty }.map(\.bookID))
        ids.formUnion(allOverrides.map(\.bookID))
        layoutBookIDs = ids
    }

    /// bookIDからこの本のURLを解決する。Bookmark.bookmarkData/BookmarkListView.resolvedURLと
    /// 同じロジック(セキュリティスコープ付きブックマークがあればそれを解決し、実際にファイル/
    /// フォルダがまだ存在するか確認する。無ければbookIDの素のパスへフォールバックする)。
    /// 「ブックマーク・レイアウトの編集」ウインドウが、今開いていない本のサムネイルを
    /// 読み込む・EPUB出力する際に使う。
    func resolvedURL(forBookID bookID: String) -> URL? {
        if let data = bookLayoutSettings(forBookID: bookID)?.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallbackURL = URL(fileURLWithPath: bookID)
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return nil }
        return fallbackURL
    }

    // MARK: - 本全体の設定(BookLayoutSettings)

    /// 指定したbookIDのBookLayoutSettingsを取得する(存在しなければnil。新規作成はしない)。
    /// 「ブックマーク・レイアウトの編集」ウインドウのように、今開いていない本も含めて
    /// 読み取り専用で参照したい場合に使う。
    ///
    /// 以前は#Predicate<BookLayoutSettings> { $0.bookID == bookID }でSwiftData側に絞り込みを
    /// 任せていたが、「レイアウトを変更した直後、bookIDで絞り込んだフェッチだけが0件を返す
    /// (絞り込み無しの全件フェッチでは正しく該当行が見つかる)」という不具合が実機で確認された
    /// (ユーザー報告: 変更後も「レイアウト情報がある」の絞り込みや「レイアウトを全削除」ボタンの
    /// 有効化は正しく機能する=reloadLayoutBookIDsの絞り込み無し全件フェッチは正しい一方、
    /// この関数のような#Predicateでの絞り込みフェッチだけが空を返す)。#Predicateのクロージャ内で
    /// キャプチャしたローカル変数(bookID)が、比較対象のモデル側プロパティ名($0.bookID)と
    /// 同名であることが関係している可能性が高い。原因の詳細な特定はできていないが、
    /// reloadLayoutBookIDsと同じ「絞り込み無しで全件取得し、Swift側でfilterする」方式に
    /// 統一することで確実に回避する。
    func bookLayoutSettings(forBookID bookID: String) -> BookLayoutSettings? {
        allBookLayoutSettings().first { $0.bookID == bookID }
    }

    /// bookIDに対応するBookLayoutSettingsを取得し、無ければ新規作成して返す(挿入済み、
    /// 未保存)。新規作成時は、現在のbookの指紋を記録しておく(以後の差し替え検知の基準になる)。
    /// 実際に何らかのレイアウトデータを書き込む直前にだけ呼ぶ(単に「参照したいだけ」の場合は
    /// bookLayoutSettings(forBookID:)を使う。空のBookLayoutSettings行を作るだけの副作用を
    /// 避けるため)。
    private func existingOrNewSettings(for book: MangaBook) -> BookLayoutSettings {
        // 診断用ログ(不具合調査中の一時的な計装。原因判明済みのため既定では無効化。
        // 再調査が必要になった場合はDEBUGビルドで有効になる)。全BookLayoutSettings行の
        // bookID一覧を出し、同じbookIDの行が複数(重複)存在していないかを確認できるように
        // する(@Attribute(.unique)のはずだが、フェッチが直前の挿入を見落として「新規作成」の
        // 分岐に入ってしまうと、実質的な重複行が作られてしまう可能性を疑っている)。
        #if DEBUG
        let allBookIDs = allBookLayoutSettings().map(\.bookID)
        NSLog(
            "qooViewer[diag]: existingOrNewSettings called for bookID=%@ allBookLayoutSettingsBookIDs=%@",
            book.id, allBookIDs.joined(separator: " | ")
        )
        #endif
        if let existing = bookLayoutSettings(forBookID: book.id) {
            #if DEBUG
            NSLog("qooViewer[diag]: existingOrNewSettings -> found existing settings row")
            #endif
            return existing
        }
        #if DEBUG
        NSLog("qooViewer[diag]: existingOrNewSettings -> NOT FOUND, creating NEW BookLayoutSettings row")
        #endif
        let created = BookLayoutSettings(bookID: book.id)
        let fingerprint = ContentFingerprint.current(for: book)
        created.recordedPageCount = fingerprint.pageCount
        created.recordedSourceModificationDate = fingerprint.modificationDate
        created.recordedSourceFileSize = fingerprint.fileSize
        // セキュリティスコープ付きブックマークを一緒に保存しておく(ViewerViewModel.addBookmarkと
        // 同じ理由。「ブックマーク・レイアウトの編集」ウインドウから、ブックマークを1件も
        // 持たない本のサムネイルを読み込むために必要。今この本を開けている=このURLへの
        // アクセス権を持っている、という前提でここで生成する)。
        created.bookmarkData = try? book.sourceURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        modelContext.insert(created)
        invalidateLayoutCaches()
        return created
    }

    func setReadingDirectionOverride(for book: MangaBook, _ direction: ReadingDirection?) {
        let settings = existingOrNewSettings(for: book)
        settings.readingDirectionOverride = direction
        settings.updatedAt = Date()
        saveAndNotify(bookID: book.id)
    }

    func setForcedDisplayMode(for book: MangaBook, _ mode: DisplayMode?) {
        let settings = existingOrNewSettings(for: book)
        settings.forcedDisplayMode = mode
        settings.updatedAt = Date()
        saveAndNotify(bookID: book.id)
    }

    /// ページ順序の補正(2.3節)。nilを渡すと自然順ソートに戻す(4.3節「表示順を初期化する」)。
    func setPageOrderOverride(for book: MangaBook, _ order: [String]?) {
        let settings = existingOrNewSettings(for: book)
        settings.pageOrderOverride = order
        settings.updatedAt = Date()
        saveAndNotify(bookID: book.id)
    }

    /// この本がEPUBで、package documentに権威的なレイアウト指定を持っているかどうかを記録する。
    /// 本を開くたびに(EPUBかどうかに関わらず)呼んでキャッシュを最新化する想定
    /// (詳細はBookLayoutSettings.hasEpubLayoutLockのコメント参照)。
    /// EPUBロックが無く、かつこの本にまだレイアウトデータが無い場合は、空のBookLayoutSettings行を
    /// 作ってまで記録する必要はないため、既存の行がある場合にのみ更新する。
    func recordEpubLayoutLock(for book: MangaBook, hasLock: Bool) {
        if hasLock {
            let settings = existingOrNewSettings(for: book)
            guard settings.hasEpubLayoutLock != hasLock else { return }
            settings.hasEpubLayoutLock = hasLock
            saveAndNotify(bookID: book.id)
        } else if let settings = bookLayoutSettings(forBookID: book.id), settings.hasEpubLayoutLock {
            settings.hasEpubLayoutLock = false
            saveAndNotify(bookID: book.id)
        }
    }

    // MARK: - カバー画像の上書き(EPUB出力用。ユーザー要望: カバー画像を選択・変更できるように
    // したい)

    /// カバー画像が上書き設定されている本のbookID一覧。読み方向やページ順の上書きが無くても、
    /// カバーだけ上書きしている本をEPUB出力ウインドウの対象一覧に含められるようにするため
    /// (EpubExportViewModel.reload参照。isBookLevelSettingEmptyはカバー関連のプロパティを
    /// 考慮していないため、layoutBookIDsだけでは拾えない)。
    func coverOverrideBookIDs() -> Set<String> {
        Set(allBookLayoutSettings().filter(\.hasCoverOverride).map(\.bookID))
    }

    /// 本に含まれる既存ページをカバーに指定する。displayNameは選択時点のPageRef.displayNameを
    /// 呼び出し元(EPUB出力ウインドウのカバーピッカー)から渡してもらい、一覧のカバー列に
    /// 本を再読み込みせずに表示できるようキャッシュしておく。
    func setCoverPageKey(for book: MangaBook, pageKey: String, displayName: String) {
        let settings = existingOrNewSettings(for: book)
        settings.coverPageKey = pageKey
        settings.coverPageDisplayName = displayName
        settings.externalCoverBookmarkData = nil
        settings.externalCoverFileName = nil
        settings.updatedAt = Date()
        saveAndNotify(bookID: book.id)
    }

    /// 本に含まれない専用ファイルをカバーに指定する。このファイルは本の一部として扱わない
    /// (LayoutStore/BookLoaderのどこからも参照しない)ため、ビューアのページ一覧には現れない。
    func setExternalCover(for book: MangaBook, fileURL: URL) throws {
        let data = try fileURL.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let settings = existingOrNewSettings(for: book)
        settings.externalCoverBookmarkData = data
        settings.externalCoverFileName = fileURL.lastPathComponent
        settings.coverPageKey = nil
        settings.coverPageDisplayName = nil
        settings.updatedAt = Date()
        saveAndNotify(bookID: book.id)
    }

    /// カバーの上書きを解除し、既定(本の実質的な先頭ページ)に戻す。
    func clearCoverOverride(forBookID bookID: String) {
        guard let settings = bookLayoutSettings(forBookID: bookID), settings.hasCoverOverride else { return }
        settings.coverPageKey = nil
        settings.coverPageDisplayName = nil
        settings.externalCoverBookmarkData = nil
        settings.externalCoverFileName = nil
        settings.updatedAt = Date()
        saveAndNotify(bookID: bookID)
    }

    /// externalCoverBookmarkDataからURLを解決する(resolvedURL(forBookID:)と同じ考え方)。
    func resolvedExternalCoverURL(forBookID bookID: String) -> URL? {
        guard let data = bookLayoutSettings(forBookID: bookID)?.externalCoverBookmarkData else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
        ), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - ページ単位の設定(PageLayoutOverride)

    /// 指定した本のページ単位設定をすべて取得する(順不同)。
    ///
    /// bookLayoutSettings(forBookID:)と同じ理由(コメント参照)で、#Predicateでの絞り込みを
    /// 使わず、絞り込み無しで全件取得してからSwift側でfilterする方式にしている。
    /// この関数はreloadLayoutBookIDs()と組み合わせて実機で問題が確認された、まさにその関数
    /// (レイアウト変更直後にこの関数の絞り込みフェッチだけが0件を返す一方、
    /// reloadLayoutBookIDsの絞り込み無し全件フェッチでは正しく該当行が見つかっていた)。
    func pageOverrides(forBookID bookID: String) -> [PageLayoutOverride] {
        allPageLayoutOverrides().filter { $0.bookID == bookID }
    }

    /// 指定した1ページの設定を取得する(未設定=「レイアウトなし」ならnil)。
    ///
    /// 以前はcompositeKey(bookID+pageKeyを合成した@Attribute(.unique)のString)を対象に
    /// 個別に#Predicateでフェッチしていたが、ページのレイアウトを変更すると意図しない他の
    /// ページ(場合によっては本の全ページ)まで同じ状態に変わって見える不具合が報告された
    /// (ユーザー報告)。原因を完全に特定できてはいないが、bookIDだけで絞り込む
    /// pageOverrides(forBookID:)(こちらは他の判定(除外ページの検出等)で問題なく機能している)を
    /// 使って一度全件取得し、pageKeyの一致をSwift側で(SwiftDataの#Predicateに頼らず)判定する
    /// 形に変更することで、compositeKey列を対象にした述語評価が疑わしいケースを避ける。
    /// 呼び出し元(Pickerの表示・レイアウト変更前の既存行チェック等)はいずれも1ページずつの
    /// 呼び出しのため、ページ数が多い本でもこの線形探索によるコストは問題にならない。
    func pageOverride(forBookID bookID: String, pageKey: String) -> PageLayoutOverride? {
        pageOverrides(forBookID: bookID).first { $0.pageKey == pageKey }
    }

    /// 指定した1ページの設定を書き換える。stateがnilなら「レイアウトなし」に戻す
    /// (行自体を削除する。詳細はPageLayoutState.swiftのコメント参照)。
    func setPageLayoutState(for book: MangaBook, pageKey: String, state: PageLayoutState?) {
        let bookID = book.id
        // 診断用ログ(不具合調査中の一時的な計装。原因判明済みのため既定では無効化。
        // 再調査が必要になった場合はDEBUGビルドで有効になる)。この時点でこのbookIDに紐づく
        // PageLayoutOverride全件(pageKey一覧)を出しておくことで、「更新」と「新規挿入」の
        // どちらの分岐に入ったか、その直前に何件・どのpageKeyの行が存在していたかを
        // 確認できるようにする。
        #if DEBUG
        let existingKeysBefore = pageOverrides(forBookID: bookID).map(\.pageKey).sorted()
        NSLog(
            "qooViewer[diag]: setPageLayoutState bookID=%@ pageKey=%@ newState=%@ existingKeysBefore=%@",
            bookID, pageKey, state?.rawValue ?? "nil", existingKeysBefore.joined(separator: ",")
        )
        #endif
        if let state {
            if let existing = pageOverride(forBookID: bookID, pageKey: pageKey) {
                #if DEBUG
                NSLog("qooViewer[diag]: setPageLayoutState -> UPDATE existing row for pageKey=%@", pageKey)
                #endif
                existing.state = state
            } else {
                // ページ単位のデータを新規に書き込むタイミングでも、本全体の指紋アンカー
                // (BookLayoutSettings行)が存在することを保証しておく(差し替え検知の対象を
                // 本全体設定だけでなくページ単位設定も含めるため)。
                #if DEBUG
                NSLog("qooViewer[diag]: setPageLayoutState -> INSERT new row for pageKey=%@", pageKey)
                #endif
                _ = existingOrNewSettings(for: book)
                let created = PageLayoutOverride(bookID: bookID, pageKey: pageKey, state: state)
                modelContext.insert(created)
                invalidateLayoutCaches()
                // 診断用ログ(不具合調査中の一時的な計装)。insert()直後・save()より前の時点で
                // 再フェッチし、「insert自体が既存行を見えなくする」のか「save()が原因」なのかを
                // 切り分ける。
                #if DEBUG
                let keysRightAfterInsert = pageOverrides(forBookID: bookID).map(\.pageKey).sorted()
                NSLog(
                    "qooViewer[diag]: setPageLayoutState right after insert() (before save) keys=%@",
                    keysRightAfterInsert.joined(separator: ",")
                )
                #endif
            }
        } else if let existing = pageOverride(forBookID: bookID, pageKey: pageKey) {
            #if DEBUG
            NSLog("qooViewer[diag]: setPageLayoutState -> DELETE row for pageKey=%@", pageKey)
            #endif
            modelContext.delete(existing)
            invalidateLayoutCaches()
        } else {
            #if DEBUG
            NSLog("qooViewer[diag]: setPageLayoutState -> no-op (state=nil, no existing row) for pageKey=%@", pageKey)
            #endif
            return
        }
        saveAndNotify(bookID: bookID)
        #if DEBUG
        let existingKeysAfter = pageOverrides(forBookID: bookID).map(\.pageKey).sorted()
        NSLog(
            "qooViewer[diag]: setPageLayoutState after save existingKeysAfter=%@",
            existingKeysAfter.joined(separator: ",")
        )
        #endif
    }

    /// 複数ページの状態を1回のトランザクションとしてまとめて書き込む(3.3節の伝播範囲。
    /// 「本全体」「このページより前/後」のようにLayoutAutoCalculator.recalculateが一度に
    /// 何十件もの結果を返すケース向け)。
    ///
    /// 以前はViewerViewModel/BookLayoutEditorViewModel側で`for (key, state) in planned`と
    /// ループし、setPageLayoutState(state:)をページ数ぶん個別に呼んでいた。この場合、対象の
    /// ページ数だけsave()・reloadLayoutBookIDs()・NotificationCenter通知が連続して発生する。
    /// 通知のたびに他ウインドウ(今開いているビューア)のlayoutDataChangeObserverが読み直しの
    /// 非同期タスクを新たに起動するため、多数の通知が短時間に連続すると、それらの再読み込み
    /// タスクが完了する順序が保証されず、古い(途中経過の)状態を反映したタスクが後から完了して
    /// 新しい状態を上書きしてしまう競合が起こりうる(ユーザー報告: 「本全体」等を選ぶと、
    /// 変更が一瞬だけ正しく反映されたように見えた直後に、すべて「レイアウトなし」の状態へ
    /// 戻ってしまう)。
    ///
    /// 対象ページの既存行を1回のフェッチでまとめて取得し、メモリ上で全件反映してから、
    /// 最後に1回だけsave・通知することで、この種の競合の余地を無くす。
    func setPageLayoutStates(for book: MangaBook, _ changes: [String: PageLayoutState]) {
        guard !changes.isEmpty else { return }
        let bookID = book.id
        let existingByKey = Dictionary(
            uniqueKeysWithValues: pageOverrides(forBookID: bookID).map { ($0.pageKey, $0) }
        )
        var didInsertAny = false
        for (pageKey, state) in changes {
            if let existing = existingByKey[pageKey] {
                existing.state = state
            } else {
                let created = PageLayoutOverride(bookID: bookID, pageKey: pageKey, state: state)
                modelContext.insert(created)
                didInsertAny = true
            }
        }
        if didInsertAny {
            invalidateLayoutCaches()
            // setPageLayoutStateと同じく、新規行を書き込む場合は本全体の指紋アンカーの存在を
            // 保証しておく。
            _ = existingOrNewSettings(for: book)
        }
        saveAndNotify(bookID: bookID)
    }

    // MARK: - 差し替え検知(2.5節)

    /// bookの指紋を、この本に記録済みのBookLayoutSettingsの指紋と比較する。
    /// BookLayoutSettings行自体が存在しない(この本にレイアウトデータが無い)場合は、
    /// 保護すべきものが無いため常に.unaffectedを返す。
    func checkContentReplacement(book: MangaBook) -> LayoutContentReplacementStatus {
        guard let settings = bookLayoutSettings(forBookID: book.id) else { return .unaffected }
        let current = ContentFingerprint.current(for: book)
        let recorded = ContentFingerprint.Recorded(
            pageCount: settings.recordedPageCount,
            modificationDate: settings.recordedSourceModificationDate,
            fileSize: settings.recordedSourceFileSize
        )
        guard ContentFingerprint.looksReplaced(recorded: recorded, current: current) else { return .unaffected }
        return .possiblyReplaced(pageCountMatches: settings.recordedPageCount == current.pageCount)
    }

    /// 差し替え検知の確認で「そのまま適用する」が選ばれた場合に呼ぶ。今回の指紋を記録し直し、
    /// 次回以降の比較の基準を更新する。
    func acceptCurrentContent(book: MangaBook) {
        guard let settings = bookLayoutSettings(forBookID: book.id) else { return }
        let fingerprint = ContentFingerprint.current(for: book)
        settings.recordedPageCount = fingerprint.pageCount
        settings.recordedSourceModificationDate = fingerprint.modificationDate
        settings.recordedSourceFileSize = fingerprint.fileSize
        saveAndNotify(bookID: book.id)
    }

    // MARK: - 削除

    /// 指定した本のレイアウトデータ(本全体設定 + ページ単位設定のすべて)を削除する。
    /// 差し替え検知(2.5節)で「破棄する」が選ばれた場合、および4.4節「レイアウトを全削除」
    /// (1冊分)から呼ぶ。
    func discardLayoutData(forBookID bookID: String) {
        if let settings = bookLayoutSettings(forBookID: bookID) {
            modelContext.delete(settings)
        }
        for override in pageOverrides(forBookID: bookID) {
            modelContext.delete(override)
        }
        saveAndNotify(bookID: bookID)
    }

    /// すべての本のレイアウトデータを削除する。環境設定「リセット」タブ(10.1節)から呼ばれる、
    /// 緊急時向けの強力な操作。BookmarkStore.deleteAllBookmarks()と同じ考え方。
    ///
    /// 以前はここも他のメソッドと同じくtry?でエラーを黙って握りつぶしていた。「レイアウトを
    /// 全て削除」した直後のはずなのに、他の(無関係な)ページの設定が消えたり戻ったりする
    /// 不具合(ユーザー報告)の原因の1つとして、この一括削除自体が(何らかの理由で)実は
    /// 失敗しており、ユーザーが「まっさらな状態から始めたはず」と思っている実は既存の行が
    /// 残ったままだった、という可能性を切り分けるため、失敗時にログを残すようにする
    /// (saveAndNotifyのlastSaveErrorMessageのコメント参照)。
    func deleteAllLayoutData() {
        invalidateLayoutCaches()
        do {
            try modelContext.delete(model: PageLayoutOverride.self)
            try modelContext.delete(model: BookLayoutSettings.self)
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            let message = "qooViewer: LayoutStore.deleteAllLayoutData() failed: \(error)"
            lastSaveErrorMessage = message
            #if DEBUG
            print(message)
            #endif
            NSLog("%@", message)
        }
        invalidateLayoutCaches()
        reloadLayoutBookIDs()
        NotificationCenter.default.post(name: .layoutDataDidChange, object: self, userInfo: nil)
    }

    // MARK: - 内部処理

    /// 直近のsave()が失敗した場合のエラーメッセージ(デバッグ用)。
    ///
    /// これまでLayoutStoreの書き込みは一貫して`try? modelContext.save()`でエラーを黙って
    /// 握りつぶしていた。「あるページのレイアウトを変更すると無関係な既存のページの設定まで
    /// 消えて見える」という不具合(ユーザー報告)の調査の過程で、save()自体が(例えば
    /// @Attribute(.unique)の制約違反等で)実は失敗しているのに、try?がそれを隠してしまっている
    /// 可能性を切り分けるため、失敗時にコンソールへログを残すようにした(Xcodeのデバッグ
    /// コンソール、またはConsole.appで「qooViewer」を検索すると見つかる)。
    ///
    /// 最終的にこの不具合の真因は、PageLayoutOverride.compositeKey/BookLayoutSettings.bookIDに
    /// 付けていた@Attribute(.unique)にあったと判明した(詳細はPageLayoutOverride.swift/
    /// BookLayoutSettings.swiftのコメント参照)。調査の途中で疑った複数ウインドウ間の通知の
    /// 再入(reentrancy)や複数ModelContextへの分裂は、いずれも無関係だったことが確認済み。
    private(set) var lastSaveErrorMessage: String?

    private func saveAndNotify(bookID: String) {
        // insert/delete箇所ではその都度invalidateLayoutCaches()を呼んでいるが、念のためここでも
        // 無効化しておく(reloadLayoutBookIDs()がキャッシュ経由になったため、ここを抜けなければ
        // 必ず最新のフェッチ結果を使うことを保証する)。
        invalidateLayoutCaches()
        do {
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            let message = "qooViewer: LayoutStore.save() failed for bookID=\(bookID): \(error)"
            lastSaveErrorMessage = message
            #if DEBUG
            print(message)
            #endif
            NSLog("%@", message)
        }
        reloadLayoutBookIDs()
        NotificationCenter.default.post(
            name: .layoutDataDidChange, object: self, userInfo: ["bookID": bookID]
        )
    }
}
