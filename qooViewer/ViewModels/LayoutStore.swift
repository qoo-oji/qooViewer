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
    /// (saveAndNotify経由で)refreshLayoutBookID(_:)を呼ぶだけで常に最新の状態を保てる。
    @Published private(set) var layoutBookIDs: Set<String> = []

    /// bookLayoutSettings(forBookID:)/pageOverrides(forBookID:)等が呼ばれるたびに絞り込み無しの
    /// 全件フェッチをやり直さずに済むよう、全件フェッチ結果をbookIDで引ける形にしてキャッシュ
    /// しておく。nilは「キャッシュ未構築(次回読み取り時にフェッチが必要)」を表す。
    ///
    /// このクラスがBookLayoutSettings/PageLayoutOverrideの唯一の書き込み口であり
    /// (このファイル冒頭のコメント参照。modelContextはFavoritesStore/BookmarkStore、
    /// およびContentView/ViewerViewModel側の`@Environment(\.modelContext)`とも同じ単一の
    /// ModelContext(modelContainer.mainContext)を共有しているが、BookLayoutSettings/
    /// PageLayoutOverrideへ書き込むのはこのストアだけ)、insert/deleteのたびにこのキャッシュ
    /// 自身を同じ内容へ更新している。そのため「挿入/削除した直後、save()より前に読み直す」場合
    /// (#if DEBUGの診断ログ等)も含めて、常にmodelContext.fetch()を直接呼んでいた場合と同じ
    /// 結果になる。
    ///
    /// 経緯: 以前は`[BookLayoutSettings]`/`[PageLayoutOverride]`という平坦な配列で持ち、
    /// insert/deleteのたびにinvalidateLayoutCaches()でまるごと捨てて、次のアクセスで全件を
    /// フェッチし直していた。この方式だと、ページ単位のレイアウトを1ページ書き換えるだけでも
    /// 全PageLayoutOverride行のフェッチ+SwiftDataオブジェクトの再生成が発生する。ページ単位設定を
    /// 多数持つ本が増えるほど、1回の編集操作のコストが「アプリ全体の行数」に比例して重くなって
    /// いくため、捨てて取り直すのをやめ、書き込んだぶんだけをキャッシュへ反映する形に変えた。
    /// あわせてbookIDをキーにした辞書にすることで、bookLayoutSettings(forBookID:)/
    /// pageOverrides(forBookID:)の線形探索も無くしている。
    ///
    /// なお「絞り込み無しで全件フェッチしてからSwift側で振り分ける」という方針自体は変えて
    /// いない(#Predicateでの絞り込みフェッチが誤って0件を返す不具合を避けるため。詳細は
    /// bookLayoutSettings(forBookID:)のコメント参照)。辞書はその全件フェッチ結果を
    /// Swift側で仕分けたものにすぎない。
    private var cachedSettingsByBookID: [String: BookLayoutSettings]?
    private var cachedOverridesByBookID: [String: [PageLayoutOverride]]?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        rebuildLayoutBookIDs()
    }

    /// bookID → その本のBookLayoutSettings行。同じbookIDの行が万一複数あった場合は、
    /// 従来の`first { $0.bookID == bookID }`と同じくフェッチ順で最初の1件を採用する。
    private func settingsByBookID() -> [String: BookLayoutSettings] {
        if let cachedSettingsByBookID { return cachedSettingsByBookID }
        let fetched = (try? modelContext.fetch(FetchDescriptor<BookLayoutSettings>())) ?? []
        var byBookID: [String: BookLayoutSettings] = [:]
        byBookID.reserveCapacity(fetched.count)
        for settings in fetched where byBookID[settings.bookID] == nil {
            byBookID[settings.bookID] = settings
        }
        cachedSettingsByBookID = byBookID
        return byBookID
    }

    /// bookID → その本のPageLayoutOverride行(順不同)。
    private func overridesByBookID() -> [String: [PageLayoutOverride]] {
        if let cachedOverridesByBookID { return cachedOverridesByBookID }
        let fetched = (try? modelContext.fetch(FetchDescriptor<PageLayoutOverride>())) ?? []
        let grouped = Dictionary(grouping: fetched, by: \.bookID)
        cachedOverridesByBookID = grouped
        return grouped
    }

    /// 絞り込み無しの全BookLayoutSettings(順不同)。特定のbookIDに閉じない横断的な検索
    /// (ファイルノード識別子での照合など)にだけ使う。bookIDが分かっている場合は
    /// bookLayoutSettings(forBookID:)を使うこと。
    private func allBookLayoutSettings() -> [BookLayoutSettings] {
        Array(settingsByBookID().values)
    }

    /// 新規insertしたBookLayoutSettingsをキャッシュへ反映する(キャッシュ未構築なら何もしない。
    /// 次回の読み取り時にフェッチで拾われるため)。
    private func cacheInsertedSettings(_ settings: BookLayoutSettings) {
        cachedSettingsByBookID?[settings.bookID] = settings
    }

    /// 新規insertしたPageLayoutOverrideをキャッシュへ反映する。
    private func cacheInsertedOverride(_ override: PageLayoutOverride) {
        guard cachedOverridesByBookID != nil else { return }
        cachedOverridesByBookID?[override.bookID, default: []].append(override)
    }

    /// deleteしたPageLayoutOverrideをキャッシュから取り除く。
    private func cacheRemovedOverrides(_ removed: [PageLayoutOverride], forBookID bookID: String) {
        guard cachedOverridesByBookID != nil, !removed.isEmpty else { return }
        let removedIdentities = Set(removed.map { ObjectIdentifier($0) })
        let remaining = (cachedOverridesByBookID?[bookID] ?? []).filter {
            !removedIdentities.contains(ObjectIdentifier($0))
        }
        cachedOverridesByBookID?[bookID] = remaining.isEmpty ? nil : remaining
    }

    /// 起動時(init)と全件削除後にだけ使う、layoutBookIDsの全件再構築。通常の書き込み経路は
    /// refreshLayoutBookID(_:)で変更のあった1冊分だけを更新する。
    private func rebuildLayoutBookIDs() {
        var ids = Set(settingsByBookID().values.filter { !$0.isBookLevelSettingEmpty }.map(\.bookID))
        ids.formUnion(overridesByBookID().keys)
        layoutBookIDs = ids
    }

    /// 1冊分のlayoutBookIDsへの所属を更新する。実際に所属が変わったときだけ代入することで、
    /// @Publishedによる不要な再描画も避ける。
    private func refreshLayoutBookID(_ bookID: String) {
        let hasBookLevelData = settingsByBookID()[bookID].map { !$0.isBookLevelSettingEmpty } ?? false
        let hasPageLevelData = !(overridesByBookID()[bookID] ?? []).isEmpty
        let shouldContain = hasBookLevelData || hasPageLevelData
        guard shouldContain != layoutBookIDs.contains(bookID) else { return }
        if shouldContain {
            layoutBookIDs.insert(bookID)
        } else {
            layoutBookIDs.remove(bookID)
        }
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

    /// ユーザー要望: レイアウト設定が付いている本が、同一ボリューム内で移動・リネームされた
    /// 場合でも設定を引き継げるようにしたい(ボリュームを跨いだ移動は諦める)。
    ///
    /// 現在のbookID(パス)でBookLayoutSettingsが1件でも見つかれば、移動していない(または
    /// 既に追従済み)とみなして何もしない。見つからない場合、この本のファイルノード識別子と
    /// 一致するBookLayoutSettingsを探し、見つかればそのbookIDと、同じ旧bookIDを持つ
    /// PageLayoutOverride(ページ単位設定)のbookIDをまとめて現在のパスへ書き換える。
    /// AppState.open(url:)から、本を開くたびに呼ばれる想定。
    func reconcileBookIDIfMoved(book: MangaBook) {
        guard bookLayoutSettings(forBookID: book.id) == nil else { return }
        guard let identifier = FileNodeIdentifier.current(for: book.sourceURL) else { return }
        // 候補が複数ある(同じiノードを指す行が、過去のパスぶん複数残っている)場合に備えて、
        // 最後に使われた行(updatedAtが最新のもの)を選ぶ。以前は全件フェッチ結果の先頭を
        // 採っていたが、キャッシュを辞書にした結果この順序が不定になったため、明示的な基準に
        // 置き換えている。
        guard let matched = allBookLayoutSettings()
            .filter({ $0.bookID != book.id && $0.fileNodeIdentifier == identifier })
            .max(by: { $0.updatedAt < $1.updatedAt })
        else { return }

        let oldBookID = matched.bookID
        let movedOverrides = overridesByBookID()[oldBookID] ?? []
        matched.bookID = book.id
        matched.updatedAt = Date()
        for override in movedOverrides {
            override.bookID = book.id
            override.compositeKey = PageLayoutOverride.makeCompositeKey(bookID: book.id, pageKey: override.pageKey)
        }
        // bookIDはキャッシュ辞書のキーそのものなので、書き換えたぶんを旧キーから新キーへ移す
        // (行の追加・削除と違い、ここだけはキーの引っ越しになる)。
        cachedSettingsByBookID?[oldBookID] = nil
        cachedSettingsByBookID?[book.id] = matched
        if cachedOverridesByBookID != nil, !movedOverrides.isEmpty {
            cachedOverridesByBookID?[oldBookID] = nil
            cachedOverridesByBookID?[book.id, default: []].append(contentsOf: movedOverrides)
        }
        // 旧bookIDも「レイアウト情報がある本」から外す必要があるため、saveAndNotifyが面倒を見る
        // 新bookIDとは別に明示的に更新する。
        refreshLayoutBookID(oldBookID)
        saveAndNotify(bookID: book.id)
    }

    /// ユーザー要望: JSONインポート(LibraryImportExportService)時、ファイルパスが古くなって
    /// いても、ファイルノード識別子(iノード番号)を手がかりに、ローカルに既に保存されている
    /// セキュリティスコープ付きブックマークから現在の実際のURLを解決できるようにしたい。
    func resolvedURL(matching identifier: FileNodeIdentifier) -> URL? {
        for settings in allBookLayoutSettings() where settings.fileNodeIdentifier == identifier {
            guard let data = settings.bookmarkData else { continue }
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// ユーザー要望(後方互換性): ファイルノード識別子を持たない古いBookLayoutSettings行
    /// (この属性を追加する前に作成されたもの)について、ファイルパス(bookID)なら実在が確認
    /// できている場合に、そのパスから改めて識別子を取得して補完する。BookmarkStore.
    /// backfillFileNodeIdentifier(forBookID:identifier:)と同じ考え方(LibraryImportExportService.
    /// exportLayoutsが、書き出し対象の本のURLを解決できたタイミングで呼ぶ)。
    func backfillFileNodeIdentifier(forBookID bookID: String, identifier: FileNodeIdentifier) {
        guard let settings = bookLayoutSettings(forBookID: bookID), settings.fileNodeIdentifier == nil else { return }
        settings.inodeNumber = identifier.inodeNumber
        settings.volumeDeviceNumber = identifier.volumeDeviceNumber
        try? modelContext.save()
        // キャッシュが保持しているのはこのsettings自身(同じ参照)なので、フィールドを書き換えた
        // だけのここではキャッシュ側に手を入れる必要は無い(行の増減もbookIDの変化も無い)。
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
    /// 有効化は正しく機能する=layoutBookIDsを組み立てる絞り込み無し全件フェッチは正しい一方、
    /// この関数のような#Predicateでの絞り込みフェッチだけが空を返す)。#Predicateのクロージャ内で
    /// キャプチャしたローカル変数(bookID)が、比較対象のモデル側プロパティ名($0.bookID)と
    /// 同名であることが関係している可能性が高い。原因の詳細な特定はできていないが、
    /// rebuildLayoutBookIDsと同じ「絞り込み無しで全件取得し、Swift側で振り分ける」方式に
    /// 統一することで確実に回避する(全件フェッチの結果をbookIDで引ける辞書にしてあるだけで、
    /// SwiftDataへ絞り込みを任せていない点は変わらない。settingsByBookID()参照)。
    func bookLayoutSettings(forBookID bookID: String) -> BookLayoutSettings? {
        settingsByBookID()[bookID]
    }

    /// bookIDに対応するBookLayoutSettingsを取得し、無ければ新規作成して返す(挿入済み、
    /// 未保存)。新規作成時は、現在のbookの指紋を記録しておく(以後の差し替え検知の基準になる)。
    /// 実際に何らかのレイアウトデータを書き込む直前にだけ呼ぶ(単に「参照したいだけ」の場合は
    /// bookLayoutSettings(forBookID:)を使う。空のBookLayoutSettings行を作るだけの副作用を
    /// 避けるため)。
    ///
    /// かつてここには、同じbookIDの行が重複していないかを確認するための診断用ログ
    /// (全BookLayoutSettings行のbookID一覧を毎回joinして出力するもの)を仕込んでいたが、
    /// 疑っていた「フェッチが直前の挿入を見落とす」という筋ではなく@Attribute(.unique)が
    /// 真因だったと判明し(lastSaveErrorMessageのコメント参照)、既に対処済みのため撤去した。
    /// 呼ばれるたびに全行を走査して文字列を組み立てる計装だったため、残しておくと
    /// DEBUGビルドでの編集操作がデータ量に比例して重くなる。
    private func existingOrNewSettings(for book: MangaBook) -> BookLayoutSettings {
        if let existing = bookLayoutSettings(forBookID: book.id) {
            return existing
        }
        let created = BookLayoutSettings(
            bookID: book.id, fileNodeIdentifier: FileNodeIdentifier.current(for: book.sourceURL)
        )
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
        cacheInsertedSettings(created)
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

    /// ユーザー要望: 古いスキャン本(紙の黄ばみ等)を、きっちりした白黒に見えるよう補正する機能の
    /// 本単位でのON/OFF。ViewerViewModel.toggleContrastCorrectionから呼ばれる。
    func setContrastCorrectionEnabled(for book: MangaBook, _ enabled: Bool) {
        let settings = existingOrNewSettings(for: book)
        settings.contrastCorrectionEnabled = enabled
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

    /// この本がEPUBのpackage document、またはPDFのDocument Catalogに権威的なレイアウト指定を
    /// 持っているかどうかを記録する。本を開くたびに(形式やロックの有無に関わらず)呼んで
    /// キャッシュを最新化する想定(詳細はBookLayoutSettings.hasEpubLayoutLockのコメント参照)。
    /// ロックが無く、かつこの本にまだレイアウトデータが無い場合は、空のBookLayoutSettings行を
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
    /// 使わず、絞り込み無しで全件取得してからSwift側で振り分ける方式にしている。
    /// この関数はlayoutBookIDsの再構築と組み合わせて実機で問題が確認された、まさにその関数
    /// (レイアウト変更直後にこの関数の絞り込みフェッチだけが0件を返す一方、絞り込み無しの
    /// 全件フェッチでは正しく該当行が見つかっていた)。
    func pageOverrides(forBookID bookID: String) -> [PageLayoutOverride] {
        overridesByBookID()[bookID] ?? []
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
    ///
    /// existingOrNewSettingsと同じく、ここにあった診断用ログ(呼び出しのたびにこの本の
    /// PageLayoutOverride全件のpageKeyをsort+joinして出力するものが、書き込み前・insert直後・
    /// save後の3箇所)も、真因(@Attribute(.unique))の判明・対処に伴って撤去した。
    func setPageLayoutState(for book: MangaBook, pageKey: String, state: PageLayoutState?) {
        let bookID = book.id
        if let state {
            if let existing = pageOverride(forBookID: bookID, pageKey: pageKey) {
                existing.state = state
            } else {
                // ページ単位のデータを新規に書き込むタイミングでも、本全体の指紋アンカー
                // (BookLayoutSettings行)が存在することを保証しておく(差し替え検知の対象を
                // 本全体設定だけでなくページ単位設定も含めるため)。
                _ = existingOrNewSettings(for: book)
                let created = PageLayoutOverride(bookID: bookID, pageKey: pageKey, state: state)
                modelContext.insert(created)
                cacheInsertedOverride(created)
            }
        } else if let existing = pageOverride(forBookID: bookID, pageKey: pageKey) {
            modelContext.delete(existing)
            cacheRemovedOverrides([existing], forBookID: bookID)
        } else {
            return
        }
        saveAndNotify(bookID: bookID)
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
        var insertedOverrides: [PageLayoutOverride] = []
        for (pageKey, state) in changes {
            if let existing = existingByKey[pageKey] {
                existing.state = state
            } else {
                let created = PageLayoutOverride(bookID: bookID, pageKey: pageKey, state: state)
                modelContext.insert(created)
                insertedOverrides.append(created)
            }
        }
        if !insertedOverrides.isEmpty {
            for created in insertedOverrides {
                cacheInsertedOverride(created)
            }
            // setPageLayoutStateと同じく、新規行を書き込む場合は本全体の指紋アンカーの存在を
            // 保証しておく。
            _ = existingOrNewSettings(for: book)
        }
        saveAndNotify(bookID: bookID)
    }

    /// JSONインポート専用: 本1冊分の本全体設定(読み方向・見開き強制・ページ順)とページ単位設定を
    /// まとめて1回のトランザクションで書き込む(LibraryImportExportService.applyLayouts参照)。
    ///
    /// 経緯(ユーザー報告): JSONインポートが非常に遅い。従来のapplyLayoutsは、本全体設定を
    /// setReadingDirectionOverride/setForcedDisplayMode/setPageOrderOverrideで最大3回、
    /// ページ単位設定をsetPageLayoutStateでページ数ぶんループしてそれぞれ個別に呼んでいた。
    /// これらはいずれも呼び出しのたびにsaveAndNotify(save()+reloadLayoutBookIDs()の全件
    /// フェッチ+NotificationCenter通知)を伴うため、ページ単位設定を数百〜数千件持つ本を
    /// 含むインポートでは、本1冊だけでそれだけの回数SQLiteへコミットしていたことになる。
    ///
    /// 対応: setPageLayoutStates(複数ページ分をまとめて1回で保存する既存メソッド)と同じ考え方を
    /// 本全体設定にも広げ、本全体設定+全ページ単位設定を1回のsave・再フェッチ・通知にまとめる。
    /// readingDirection/forcedDisplayMode/pageOrderは、呼び出し側(LibraryImportExportService)が
    /// 「マージ時は既存の本全体設定が空の場合のみ適用する」等の判断を済ませた上でnilを渡すことを
    /// 想定する(3つすべてnilかつpageChangesも空の場合は何もしない)。
    func applyImportedLayout(
        for book: MangaBook,
        readingDirection: ReadingDirection?,
        forcedDisplayMode: DisplayMode?,
        pageOrder: [String]?,
        pageChanges: [String: PageLayoutState]
    ) {
        let hasPageOrder = pageOrder.map { !$0.isEmpty } ?? false
        guard readingDirection != nil || forcedDisplayMode != nil || hasPageOrder || !pageChanges.isEmpty else {
            return
        }
        let bookID = book.id
        // 本全体設定・ページ単位設定のどちらか一方でも書き込む対象がある以上、必ず指紋アンカー
        // (BookLayoutSettings行)の存在を保証しておく(既存のsetXxxOverride系・
        // setPageLayoutState(States)系と同じ考え方)。
        let settings = existingOrNewSettings(for: book)
        if let readingDirection {
            settings.readingDirectionOverride = readingDirection
        }
        if let forcedDisplayMode {
            settings.forcedDisplayMode = forcedDisplayMode
        }
        if hasPageOrder {
            settings.pageOrderOverride = pageOrder
        }
        settings.updatedAt = Date()

        if !pageChanges.isEmpty {
            let existingByKey = Dictionary(
                uniqueKeysWithValues: pageOverrides(forBookID: bookID).map { ($0.pageKey, $0) }
            )
            for (pageKey, state) in pageChanges {
                if let existing = existingByKey[pageKey] {
                    existing.state = state
                } else {
                    let created = PageLayoutOverride(bookID: bookID, pageKey: pageKey, state: state)
                    modelContext.insert(created)
                    cacheInsertedOverride(created)
                }
            }
        }
        saveAndNotify(bookID: bookID)
    }

    /// 複数ページのページ単位設定をまとめて削除する(1回のトランザクション)。
    /// BookLayoutEditorViewModel.applyNewOrder(ページ並べ替え確定時、隣接関係が変わった
    /// 見開き左/右の設定を削除する処理)向け。
    ///
    /// 経緯(ユーザー報告): JSONインポートで見つかったのと同じ「1件ごとにSQLiteへコミット」の
    /// 問題が、ページ並べ替え時にも残っていた。setPageLayoutState(state: nil)を対象ページ数
    /// ぶんループで個別に呼ぶと、見開き左/右を多く手動指定している本を大きく並べ替えた際、
    /// 隣接関係が変わったページの数だけsave()+reloadLayoutBookIDs()+通知が発生してしまう。
    /// 対象行をまとめて削除し、保存・再フェッチ・通知をこの並べ替え1回につき1回にまとめる。
    func clearPageLayoutStates(for book: MangaBook, pageKeys: Set<String>) {
        guard !pageKeys.isEmpty else { return }
        let bookID = book.id
        let existing = pageOverrides(forBookID: bookID).filter { pageKeys.contains($0.pageKey) }
        guard !existing.isEmpty else { return }
        for override in existing {
            modelContext.delete(override)
        }
        cacheRemovedOverrides(existing, forBookID: bookID)
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
            cachedSettingsByBookID?[bookID] = nil
        }
        let overrides = pageOverrides(forBookID: bookID)
        for override in overrides {
            modelContext.delete(override)
        }
        cachedOverridesByBookID?[bookID] = nil
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
        // 一括削除はdelete(model:)でSwiftDataに直接まとめて消させるため、どの行が消えたかを
        // 個別に追えない。キャッシュは「空」として作り直す(nilにして次回フェッチさせるのでも
        // 正しいが、削除に失敗していた場合に古い行を拾い直してしまうため、明示的に空にする。
        // 上のcatch節が示すとおり、この一括削除が実は失敗していた可能性の切り分けが必要に
        // なった経緯がある)。
        cachedSettingsByBookID = [:]
        cachedOverridesByBookID = [:]
        layoutBookIDs = []
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
    /// 再入(reentrancy)や複数ModelContextへの分裂は、いずれも無関係だったことが確認済み
    /// (その後、QooViewerApp.init()のコメントにある通り、コンテキスト分裂に起因する別の問題
    /// (別コンテキストのオブジェクトを渡すと削除等が静かに失敗する)を解消する目的で、改めて
    /// 全ストアを単一のModelContext(modelContainer.mainContext)に統一している。真因だった
    /// @Attribute(.unique)は既に外してあるため、この統一自体が本コメントの不具合を再発させる
    /// ものではない)。
    private(set) var lastSaveErrorMessage: String?

    private func saveAndNotify(bookID: String) {
        // 以前はここで無条件にキャッシュを捨てていたが、insert/delete箇所がその都度キャッシュへ
        // 差分を反映するようになったため不要になった(捨てると、この直後のrefreshLayoutBookID()と
        // 呼び出し元の続きの読み取りで、必ず全件フェッチが走り直してしまう)。
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
        refreshLayoutBookID(bookID)
        NotificationCenter.default.post(
            name: .layoutDataDidChange, object: self, userInfo: ["bookID": bookID]
        )
    }
}
