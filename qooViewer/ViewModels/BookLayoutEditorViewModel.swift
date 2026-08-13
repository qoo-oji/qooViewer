import Foundation
import CoreGraphics
import Combine
import SwiftUI

/// 「ブックマーク・レイアウトの編集」ウインドウの右ペイン(4.2節)で、選択中の1冊分の
/// ページ一覧・サムネイル読み込み・並べ替え・レイアウト変更を担当する。
///
/// 今開いている本のViewerViewModelとは完全に独立した、この編集ウインドウ専用の軽量な読み込み
/// 経路を持つ(この本を今開いているウインドウ/タブがあるかどうかに関わらず動作する必要があるため。
/// 実際にビューアウインドウを開くわけではなく、サムネイル表示・並べ替え・レイアウト編集の
/// ためだけにBookLoader.load(from:)で本を独自に読み込む)。
///
/// 除外(非表示)設定のページも、通常の読書フローとは異なりここでは常に一覧に表示する
/// (設計コンセプト2.2節: 「除外ページは...4節の編集ウインドウからは常に見え、いつでも
/// 解除できる」)。そのためViewerViewModel.book.pages(除外ページを除去済み)とは異なり、
/// rowsは常に全ページを含む。パリティ計算(3.3節)の対象からは、ViewerViewModelと同じく
/// 除外ページを明示的に取り除く(readableKeys参照)。
@MainActor
final class BookLayoutEditorViewModel: ObservableObject {
    /// 右ペインの1行。安定した識別子はpageKey(PageRef.sortKey)。
    struct Row: Identifiable, Equatable {
        let pageKey: String
        /// BookLoaderが返す自然順のbook.pages内でのインデックス。PageLoader.thumbnail(at:)は
        /// この自然順インデックスを基準にするため、並べ替え後の表示位置とは別に保持する。
        let rawIndex: Int
        let displayName: String
        /// 除外ページを取り除いた「読書順」でのインデックス(ViewerViewModel.currentIndexと
        /// 同じ空間)。Bookmark.pageIndexとの突き合わせに使う。除外ページはnil。
        let effectiveReadingIndex: Int?
        var id: String { pageKey }
    }

    enum LoadState: Equatable {
        case loading
        case loaded
        case failed
    }

    let bookID: String
    private let layoutStore: LayoutStore
    private let preferences: AppPreferences
    /// ページ並べ替え時、既存のブックマークをページ番号(スロット)ではなくファイルに追従させる
    /// ために使う(applyNewOrder/migrateBookmarkIndices参照。ユーザー報告)。
    private let bookmarkStore: BookmarkStore

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var rows: [Row] = []
    /// この本の現在のページ単位レイアウト設定(pageKey→state)のスナップショット。
    ///
    /// 以前はPageRowView(右ペインの各行)が自分のcurrentLayoutStateを表示するたびに
    /// layoutStore.pageOverride(forBookID:pageKey:)でSwiftDataへ直接フェッチしていたが、
    /// 「あるページのレイアウトを変更すると無関係な他のページまで変わって見える/レイアウトなしに
    /// 戻ってしまう」という不具合が報告された(ユーザー報告)。1回のレイアウト変更の中で
    /// 複数ページへの書き込み(anchorPinStates + LayoutAutoCalculator.recalculateの結果の反映)が
    /// 連続して発生する際、各行が「今この瞬間のSwiftDataの状態」を都度フェッチしに行くと、
    /// 書き込みの合間の一時的な状態を拾ってしまう余地があった。そのため、書き込みが完了した
    /// 後にこのViewModelが1回だけ確定させたスナップショットをPublishし、各行はそれだけを
    /// 参照する形に統一する(currentOverridesByKey/refreshEffectiveIndices参照)。
    @Published private(set) var pageLayoutStates: [String: PageLayoutState] = [:]
    /// 4.3節: 並べ替えの結果、隣接関係が変わった見開き右/見開き左の設定を削除した場合に表示する
    /// 警告バナーの文言。nilなら非表示。表示中に他の操作をしても自動では消えない
    /// (呼び出し側が明示的にdismissWarning()を呼ぶまで残す。誤って見落とさないため)。
    @Published private(set) var reorderWarningMessage: String?

    private var book: MangaBook?
    private var pageLoader: PageLoader?

    /// load()でstartAccessingSecurityScopedResource()に成功したURL(していなければnil)。
    ///
    /// このViewModelは、読み込みが終わった後もサムネイル・フル解像度画像の取得のために
    /// pageLoader経由で元のファイルを読み続けるため、load()の中でアクセスを閉じることはできず、
    /// このインスタンスが生きている間ずっと開いたままにしておく必要がある。そのため対になる
    /// stopAccessingSecurityScopedResource()はdeinitで呼ぶ。
    ///
    /// 以前は`_ = url.startAccessingSecurityScopedResource()`と開きっぱなしにしており、
    /// 左ペインで本を選び替えるたび(このViewModelは右ペインごと.id(bookID)で作り直される)に
    /// 1つずつアクセス権がリークしていた。
    private var securityScopedURL: URL?

    /// この本がEPUBのpackage document、またはPDFのDocument Catalogに権威的なレイアウト指定を
    /// 持っているかどうか。キャッシュ(BookLayoutSettings.hasEpubLayoutLock)には依存せず、
    /// 読み込んだ本自身から直接判定する(この本を一度もビューアで開いたことが無く、キャッシュが
    /// まだ無い場合でも正しく判定できるようにするため)。
    var hasAuthoritativeSourceLayout: Bool {
        book?.sourceLayoutHint != nil
    }

    /// この本の実効的な読み方向。「見開き右/見開き左」を実際の画面上の右/左と一致させるため、
    /// anchor(forPageKey:explicitState:in:)/anchorPinStates/setPageLayoutの計算にこれを使う
    /// (ViewerViewModel.readingDirectionと同じ優先順位: ソースファイル自身(EPUB/PDF)由来 >
    /// DB保存値 > 環境設定の既定値。
    /// ただしViewerViewModelと異なり、この編集ウインドウは「最後に読んでいた位置」を持つ
    /// BookReadingStateまで読み込まないため、そこは含めない。ビューアの読み方向トグルボタンで
    /// 一時的に切り替えただけ(BookLayoutSettingsへは保存されない)の場合はここでは反映されない
    /// が、通常はこの編集ウインドウの読み方向ドロップダウンで変更するとBookLayoutSettingsへ
    /// 保存されるため、実用上はビューアの表示と一致する)。
    /// (以前はprivateだったが、ユーザー報告: 編集ウインドウの読み方向ドロップダウンが
    /// 上書き未設定のときに常に「既定」と表示され、実際に画面がどちら向きで開かれるのか
    /// 分からなかったため、BookmarkListView.swift側のPickerがこの実効値を直接表示できるよう
    /// 公開した。)
    var effectiveReadingDirection: ReadingDirection {
        book?.sourceLayoutHint?.pageProgressionDirection
            ?? layoutStore.bookLayoutSettings(forBookID: bookID)?.readingDirectionOverride
            ?? preferences.defaultReadingDirection
    }

    /// この本のレイアウトデータが、このViewModel自身の書き込みメソッドを経由せずに変更された
    /// 場合(例: BookmarkListView.swift「レイアウトを全削除」ボタンがlayoutStore.
    /// discardLayoutData(forBookID:)を直接呼ぶ経路)に気づくための監視トークン。
    ///
    /// 以前はこのViewModelに通知の購読が無く、自分自身のsetPageLayout/clearPageLayout等の
    /// 書き込みメソッドの最後でrefreshEffectiveIndices()を呼ぶことでしか状態を更新しなかった。
    /// そのため「レイアウトを全削除」した直後は表示(pageLayoutStates/rows)が変わらないまま
    /// (どれか1ページを手動で変更して初めて、その書き込みのrefreshEffectiveIndices()経由で
    /// 一斉に正しい状態へ更新される)という不具合(ユーザー報告)があった。ViewerViewModelの
    /// layoutDataChangeObserverと同じ考え方で、この本(bookID)宛ての変更通知を購読し、
    /// 気づいたら都度refreshEffectiveIndices()で読み直す。
    private var layoutDataChangeObserver: NSObjectProtocol?

    init(bookID: String, layoutStore: LayoutStore, preferences: AppPreferences, bookmarkStore: BookmarkStore) {
        self.bookID = bookID
        self.layoutStore = layoutStore
        self.preferences = preferences
        self.bookmarkStore = bookmarkStore

        let ownBookID = bookID
        layoutDataChangeObserver = NotificationCenter.default.addObserver(
            forName: .layoutDataDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            // queue: .mainを指定しているため実行時には必ずMainActor上で呼ばれるが、クロージャ
            // 自体の型はMainActorに分離されていないため、コンパイラは静的にそれを保証できない
            // (ViewerViewModel.layoutDataChangeObserver/BookmarkStore.changeObserverの
            // 同種のコメント参照)。
            MainActor.assumeIsolated {
                let changedBookID = notification.userInfo?["bookID"] as? String
                guard changedBookID == nil || changedBookID == ownBookID else { return }
                self?.refreshEffectiveIndices()
            }
        }
    }

    deinit {
        if let layoutDataChangeObserver {
            NotificationCenter.default.removeObserver(layoutDataChangeObserver)
        }
        // load()で開いたセキュリティスコープ付きアクセスを閉じる(securityScopedURLのコメント参照)。
        // pageLoaderが既に開いているファイルハンドルはこの呼び出しでは無効にならないため、
        // 読み込み中のサムネイル取得が残っていても影響しない(どのみち結果はもう表示されない)。
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    /// この本を読み込む。resolvedURL(セキュリティスコープ付きブックマーク、またはbookIDの
    /// 素のパス)が解決できない、または読み込み自体に失敗した場合は.failedになる
    /// (呼び出し側はContentUnavailableView等で案内する)。
    func load() async {
        loadState = .loading
        guard let url = layoutStore.resolvedURL(forBookID: bookID) else {
            loadState = .failed
            return
        }
        // 万一load()が複数回呼ばれた場合に備えて、前回のアクセスを閉じてから開き直す
        // (startAccessingSecurityScopedResourceは参照カウント式のため、開いた回数と同じだけ
        // 閉じないと解放されない)。
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        guard let loaded = try? await BookLoader.load(from: url) else {
            loadState = .failed
            return
        }
        book = loaded
        pageLoader = PageLoader(book: loaded)
        rebuildRows(from: loaded)
        loadState = .loaded
    }

    /// pageOrderOverride(2.3節)を反映した表示順でrowsを組み立て直す。
    private func rebuildRows(from book: MangaBook) {
        let overrideOrder = layoutStore.bookLayoutSettings(forBookID: bookID)?.pageOrderOverride
        let orderedPages = Self.reorder(pages: book.pages, by: overrideOrder)
        // sortKeyをキーにする辞書は、uniqueKeysWithValues(重複キーで実行時トラップ)ではなく
        // 「最初の1件を採る」形で組み立てる。PageRef.sortKeyは、書庫の中に`a.zip`という
        // ファイルと`a.zip/`というフォルダが同居しているような作りの本では、入れ子書庫の
        // 展開結果("a.zip/01.jpg")とフォルダ内の画像のパスが偶然一致しうる
        // (BookLoader.collectPagesのsortKeyPrefix参照。PageRef.idは区切り文字が異なるため
        // 衝突しない)。稀なケースだが、本を開いただけでクラッシュする理由にはならない。
        let rawIndexByKey = Dictionary(
            book.pages.enumerated().map { ($1.sortKey, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let baseRows = orderedPages.map { page in
            Row(
                pageKey: page.sortKey,
                rawIndex: rawIndexByKey[page.sortKey] ?? 0,
                displayName: page.displayName,
                effectiveReadingIndex: nil
            )
        }
        let overridesByKey = currentOverridesByKey()
        pageLayoutStates = overridesByKey
        rows = recomputeEffectiveIndices(for: baseRows, overridesByKey: overridesByKey)
    }

    private static func reorder(pages: [PageRef], by overrideOrder: [String]?) -> [PageRef] {
        guard let overrideOrder else { return pages }
        // rebuildRowsと同じ理由で「最初の1件を採る」形にする(コメント参照)。
        var remaining = Dictionary(pages.map { ($0.sortKey, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [PageRef] = []
        result.reserveCapacity(pages.count)
        for key in overrideOrder {
            if let page = remaining.removeValue(forKey: key) {
                result.append(page)
            }
        }
        // overrideOrderに含まれない(新しく増えた)ページは、元の自然順のまま末尾に追加する
        // (ViewerViewModel.applyLayoutDataと同じ考え方)。
        result.append(contentsOf: pages.filter { remaining[$0.sortKey] != nil })
        return result
    }

    /// この本のPageLayoutOverrideを、pageKeyをキーにした辞書として一括取得する。
    /// 以前はrecomputeEffectiveIndices/readableKeysの内部で1ページずつlayoutStore.pageOverride
    /// (SwiftDataへの個別のpredicateフェッチ)を呼んでいたが、ページ数が多い本では
    /// 1回のレイアウト変更につき数百回ものフェッチが発生していた。ViewerViewModel.
    /// reloadLayoutDataと同じく、1回の一括取得(pageOverrides(forBookID:))で辞書を組み立てて
    /// 使い回す形に統一する(setPageLayout実行中に個々のページの除外状態の判定がぶれる余地を
    /// なくす副次的な効果もある)。
    private func currentOverridesByKey() -> [String: PageLayoutState] {
        var result: [String: PageLayoutState] = [:]
        for override in layoutStore.pageOverrides(forBookID: bookID) {
            result[override.pageKey] = override.state
        }
        return result
    }

    /// 除外ページにnilを割り当てながら、順にeffectiveReadingIndexを振り直す。
    /// overridesByKeyは呼び出し元が(currentOverridesByKey()で)1回だけ取得したスナップショットを
    /// 渡す(この関数自体はSwiftDataへ問い合わせない。pageLayoutStatesのコメント参照)。
    private func recomputeEffectiveIndices(for rows: [Row], overridesByKey: [String: PageLayoutState]) -> [Row] {
        var counter = 0
        return rows.map { row in
            guard overridesByKey[row.pageKey] != .excluded else {
                return Row(pageKey: row.pageKey, rawIndex: row.rawIndex, displayName: row.displayName, effectiveReadingIndex: nil)
            }
            let index = counter
            counter += 1
            return Row(pageKey: row.pageKey, rawIndex: row.rawIndex, displayName: row.displayName, effectiveReadingIndex: index)
        }
    }

    /// サムネイル(軽量)を取得する。rawIndexはPageLoaderの自然順インデックス
    /// (Row.rawIndex参照。表示順のインデックスではないので注意)。
    func thumbnail(rawIndex: Int) async -> CGImage? {
        await pageLoader?.thumbnail(at: rawIndex)
    }

    /// フル解像度の画像を取得する。行のサムネイルにカーソルをホバーしたときの拡大プレビュー
    /// (ユーザー要望)専用。thumbnail(rawIndex:)は進捗バー用の軽量版(240px程度)で、そのまま
    /// 拡大表示すると粗くなるため、こちらはビューアと同じ解像度(ImageDecoder.pageMaxPixelSize)の
    /// 画像を返す。ホバーしたときだけ呼ばれる想定(常時読み込むと本によっては重くなるため)。
    func pageImage(rawIndex: Int) async -> CGImage? {
        await pageLoader?.pageImage(at: rawIndex)
    }

    func dismissReorderWarning() {
        reorderWarningMessage = nil
    }

    // MARK: - 並べ替え(4.3節)

    /// ドラッグ&ドロップ並べ替え(4.3節、BookmarkListView.pageListContentの.onMove)。
    ///
    /// source/destinationは、SwiftUIのList/ForEachが実際に描画している配列
    /// (displayedPageKeys。除外ページを一覧末尾へファイル名順で回す表示専用の並べ替えを
    /// 適用済みのもの。BookmarkListView.displayedRows参照)の中でのインデックスを指す。
    /// これはrows(pageOrderOverrideとして永続化される「真の」並び順)とは別のインデックス
    /// 空間のため、そのままrowsへ適用すると誤った位置に並べ替えてしまう
    /// (以前はこれを避けるため、除外ページが1件でもある間はドラッグ自体を丸ごと無効化して
    /// いたが、上下ボタン(movePageUp/movePageDown)はpageKeyでrows自体を直接操作するため
    /// 除外ページがあっても問題なく動作しており、ドラッグだけ使えないのは不自然だという
    /// ユーザー報告を受けて、この関数側でインデックス空間の変換を行うように修正した)。
    ///
    /// 除外ページ自身は、並べ替え前にrows上で直前にあった「読める(除外されていない)」ページに
    /// 付随したまま、そのページと一緒に新しい位置へ移動する(先頭にある除外ページは「先頭
    /// グループ」として扱う)。除外ページ同士やそれ単体の「正しい位置」という概念自体が
    /// 意味を持たないため、これは実用上十分な近似であり、読めるページの新しい相対順だけを
    /// 正しく反映することを優先している。
    func movePages(displayedPageKeys: [String], fromOffsets source: IndexSet, toOffset destination: Int) {
        // ドラッグでつまんだ(=ユーザーが直接操作した)ページを、更新後のビューア画面の表示に
        // 含めるための対象として通知する(ユーザー要望。postLayoutFocusChange参照)。
        // 複数選択のドラッグは現状のUIでは起こらない想定だが、念のため最初の1件を使う。
        let focusPageKey = source.first.flatMap { displayedPageKeys.indices.contains($0) ? displayedPageKeys[$0] : nil }

        var displayedOrder = displayedPageKeys
        displayedOrder.move(fromOffsets: source, toOffset: destination)

        let readableKeys = Set(rows.compactMap { $0.effectiveReadingIndex != nil ? $0.pageKey : nil })
        // displayedOrderのうち、読める(除外されていない)ページだけを取り出した新しい相対順。
        let newReadableOrder = displayedOrder.filter { readableKeys.contains($0) }

        // 並べ替え前(rows)の時点で、各除外ページが直前のどの読めるページに付いていたかを
        // 記録しておく(先頭にある除外ページはleadingExcludedへ)。
        var leadingExcluded: [String] = []
        var trailingExcludedByAnchor: [String: [String]] = [:]
        var currentAnchor: String?
        for row in rows {
            if readableKeys.contains(row.pageKey) {
                currentAnchor = row.pageKey
            } else if let currentAnchor {
                trailingExcludedByAnchor[currentAnchor, default: []].append(row.pageKey)
            } else {
                leadingExcluded.append(row.pageKey)
            }
        }

        var newOrder = leadingExcluded
        for key in newReadableOrder {
            newOrder.append(key)
            newOrder.append(contentsOf: trailingExcludedByAnchor[key] ?? [])
        }

        // rebuildRowsと同じ理由で「最初の1件を採る」形にする(Row.pageKeyはPageRef.sortKeyそのもの)。
        let rowsByKey = Dictionary(rows.map { ($0.pageKey, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = newOrder.compactMap { rowsByKey[$0] }
        applyNewOrder(reordered, focusPageKey: focusPageKey)
    }

    func movePageUp(at index: Int) {
        guard index > 0, rows.indices.contains(index) else { return }
        let focusPageKey = rows[index].pageKey
        var reordered = rows
        reordered.swapAt(index, index - 1)
        applyNewOrder(reordered, focusPageKey: focusPageKey)
    }

    func movePageDown(at index: Int) {
        guard rows.indices.contains(index), index + 1 < rows.count else { return }
        let focusPageKey = rows[index].pageKey
        var reordered = rows
        reordered.swapAt(index, index + 1)
        applyNewOrder(reordered, focusPageKey: focusPageKey)
    }

    /// 「表示順を初期化する」(4.3節)。自然順ソートへ戻す。
    func resetOrder() {
        guard let book else { return }
        layoutStore.setPageOrderOverride(for: book, nil)
        rebuildRows(from: book)
    }

    private func neighborMaps(for rows: [Row]) -> (next: [String: String], previous: [String: String]) {
        var next: [String: String] = [:]
        var previous: [String: String] = [:]
        for index in rows.indices {
            if index + 1 < rows.count {
                next[rows[index].pageKey] = rows[index + 1].pageKey
            }
            if index > 0 {
                previous[rows[index].pageKey] = rows[index - 1].pageKey
            }
        }
        return (next, previous)
    }

    /// 並べ替え結果を確定し、隣接関係が変わった「見開き右」「見開き左」の設定を削除する(2.3節)。
    /// 「単一ページ」「除外」は隣接関係に依存しないページ自体の性質のため保持する。
    ///
    /// - Parameter focusPageKey: ユーザーが直接動かしたページ(ドラッグでつまんだ行、または
    ///   上下ボタンで動かした選択中の行)。指定があれば、この本を今開いている他のウインドウ/
    ///   タブへ「更新後の表示にこのページを含めてほしい」と伝える(ユーザー要望。
    ///   postLayoutFocusChange参照)。resetOrder(本全体の並び順初期化)には単一の対象ページが
    ///   無いため、呼び出し元では渡さない。
    private func applyNewOrder(_ newRows: [Row], focusPageKey: String? = nil) {
        guard let book else { return }
        let oldNeighbors = neighborMaps(for: rows)
        // 並べ替え開始時点のスナップショットを1回だけ取得する(以前は下のループ内で行ごとに
        // layoutStore.pageOverride(forBookID:pageKey:)を個別にフェッチしていたが、pageLayoutStates
        // のコメントで説明している不具合と同じ理由で、書き込みの合間の状態を拾う余地があった)。
        let overridesByKey = currentOverridesByKey()
        let reordered = recomputeEffectiveIndices(for: newRows, overridesByKey: overridesByKey)
        let newNeighbors = neighborMaps(for: reordered)

        // ブックマークをページ番号(スロット)ではなくファイルに追従させる(ユーザー報告参照。
        // migrateBookmarkIndicesのコメント)。並べ替え前後のrowsを渡す(除外/表示状態の集合
        // 自体はこの関数では変わらないため、1対1の対応が組める)。
        migrateBookmarkIndices(from: rows, to: reordered)

        // 経緯(ユーザー報告): JSONインポートで見つかったのと同じ「1件ごとにSQLiteへコミット」の
        // 問題が、ここ(ページ並べ替え確定時に隣接関係が変わった見開き左/右の設定を削除する処理)
        // にも残っていた。以前はここでlayoutStore.setPageLayoutState(state: nil)を対象ページ数
        // ぶんループで個別に呼んでおり、そのたびに同期save()+reloadLayoutBookIDs()(全件
        // フェッチ)+通知が発生していた。見開きページを多く手動指定している本を大きく並べ替える
        // (先頭のページを末尾近くへ動かす等)と、隣接関係が変わる見開きページの数だけこれが
        // 起きていた。対象ページをいったんpageKeysToClearへ集計し、
        // clearPageLayoutStates(for:pageKeys:)へまとめて渡すことで、この並べ替え1回につき
        // 保存・再フェッチ・通知を1回にまとめる。
        var pageKeysToClear: Set<String> = []
        for row in rows {
            guard let state = overridesByKey[row.pageKey] else { continue }
            switch state {
            case .spreadLeft:
                if oldNeighbors.next[row.pageKey] != newNeighbors.next[row.pageKey] {
                    pageKeysToClear.insert(row.pageKey)
                }
            case .spreadRight:
                if oldNeighbors.previous[row.pageKey] != newNeighbors.previous[row.pageKey] {
                    pageKeysToClear.insert(row.pageKey)
                }
            case .single, .excluded:
                break
            }
        }
        layoutStore.clearPageLayoutStates(for: book, pageKeys: pageKeysToClear)
        let didClearAny = !pageKeysToClear.isEmpty
        rows = reordered
        layoutStore.setPageOrderOverride(for: book, rows.map(\.pageKey))
        // 上で見開きの設定を削除した可能性があるため、公開用スナップショットを取り直す。
        pageLayoutStates = currentOverridesByKey()
        if let focusPageKey {
            postLayoutFocusChange(pageKey: focusPageKey)
        }
        if didClearAny {
            reorderWarningMessage = String(localized: "Pages were reordered. Some layout settings need to be redone.")
        }
    }

    /// 並べ替え前後のrowsから「並べ替え前のpageIndex(effectiveReadingIndex) → 並べ替え後の
    /// pageIndex」の対応を組み立て、この本のブックマークをbookmarkStore.updatePageIndicesで
    /// 一括更新する(ユーザー報告: 「ブックマークがあるページの順番を入れ替えると、ブックマークが
    /// 追従しない(画像は入れ替わったのに元のページ順に居座る)。ブックマークはあくまでファイルに
    /// 紐づくものなので、順番が入れ替わった際はファイルに追従してほしい」)。
    ///
    /// movePages/movePageUp/movePageDownはページの除外/表示状態の集合自体を変えない(rowsの
    /// 並び順だけを変える)純粋な並べ替えのため、oldRows・newRowsに現れる
    /// effectiveReadingIndexの値の集合は完全に一致し、pageKeyを介した1対1の対応を組める。
    private func migrateBookmarkIndices(from oldRows: [Row], to newRows: [Row]) {
        var oldIndexByKey: [String: Int] = [:]
        for row in oldRows {
            if let index = row.effectiveReadingIndex {
                oldIndexByKey[row.pageKey] = index
            }
        }
        var oldIndexToNewIndex: [Int: Int] = [:]
        for row in newRows {
            guard let newIndex = row.effectiveReadingIndex, let oldIndex = oldIndexByKey[row.pageKey] else { continue }
            if newIndex != oldIndex {
                oldIndexToNewIndex[oldIndex] = newIndex
            }
        }
        guard !oldIndexToNewIndex.isEmpty else { return }
        bookmarkStore.updatePageIndices(forBookID: bookID, oldIndexToNewIndex: oldIndexToNewIndex)
    }

    // MARK: - レイアウト変更(3.2節・3.3節。ビューアと同じ仕組みをこの編集ウインドウ用に再構成)

    /// pageKey自身が新たに除外される場合を除いた、除外ページ抜きの読書順キー列
    /// (ViewerViewModel.book.pagesに相当する空間)。伝播範囲(3.3節。「本全体」「このページより
    /// 前/後」)を伴う一括更新は、常にこの戻り値(readable)だけを対象に計算する
    /// (LayoutAutoCalculator.recalculateへそのままorderedPageKeysとして渡す)ため、既に
    /// 「除外(非表示)」設定済みのページはここで確実に取り除かれ、一括更新の対象からも
    /// レイアウト計算(パリティ判定)からも除外される。
    ///
    /// overridesByKeyは呼び出し元(setPageLayout)がcurrentOverridesByKey()で一括取得したものを
    /// そのまま渡す(以前はこの関数の中で1ページずつlayoutStore.pageOverviewを呼んでいたが、
    /// ページ数が多い本では1回のレイアウト変更につき数百回のSwiftDataフェッチが発生していた)。
    private func readableKeys(
        currentPageKey: String, newState: PageLayoutState, overridesByKey: [String: PageLayoutState]
    ) -> [String] {
        rows.compactMap { row -> String? in
            if row.pageKey == currentPageKey {
                return newState == .excluded ? nil : row.pageKey
            }
            return overridesByKey[row.pageKey] == .excluded ? nil : row.pageKey
        }
    }

    /// 「見開き右/見開き左」を実際の画面上の右/左と一致させるため、どちらのページと組むか
    /// (前のページ/次のページ)の判定を読み方向(effectiveReadingDirection)で入れ替える
    /// (ViewerViewModel.anchor(forPageAtIndex:explicitState:)の同種のコメント参照)。
    private func anchor(forPageKey pageKey: String, explicitState: PageLayoutState, in readableKeys: [String]) -> LayoutAutoCalculator.Anchor {
        guard explicitState != .excluded, let index = readableKeys.firstIndex(of: pageKey) else {
            return LayoutAutoCalculator.Anchor(pageKeys: [pageKey])
        }
        let pairsWithNextPage: Bool
        switch explicitState {
        case .spreadRight:
            pairsWithNextPage = effectiveReadingDirection == .rightToLeft
        case .spreadLeft:
            pairsWithNextPage = effectiveReadingDirection != .rightToLeft
        case .single, .excluded:
            return LayoutAutoCalculator.Anchor(pageKeys: [pageKey])
        }
        if pairsWithNextPage {
            guard index + 1 < readableKeys.count else { return LayoutAutoCalculator.Anchor(pageKeys: [pageKey]) }
            return LayoutAutoCalculator.Anchor(pageKeys: [pageKey, readableKeys[index + 1]])
        } else {
            guard index - 1 >= 0 else { return LayoutAutoCalculator.Anchor(pageKeys: [pageKey]) }
            return LayoutAutoCalculator.Anchor(pageKeys: [readableKeys[index - 1], pageKey])
        }
    }

    /// anchor.pageKeysは常に[先に読むページ, 2番目に読むページ]の順(anchor(forPageKey:
    /// explicitState:in:)参照)。どちらに「見開き右」「見開き左」を割り当てるかは読み方向による。
    ///
    /// 以前(writeAnchorPin)はこの場でlayoutStore.setPageLayoutStateを直接呼んでいたが、
    /// 呼び出し元が直前にsetPageLayoutStates(まとめ書き)を済ませているため、1回のレイアウト
    /// 操作でsave()+通知が最大3回発生していた。値を返すだけにして呼び出し元でplannedへ
    /// マージしてもらう(ViewerViewModel.anchorPinStatesと同じ修正・同じ理由)。
    private func anchorPinStates(
        _ anchor: LayoutAutoCalculator.Anchor, explicitState: PageLayoutState
    ) -> [String: PageLayoutState] {
        if anchor.pageKeys.count >= 2, let earlier = anchor.pageKeys.first, let later = anchor.pageKeys.dropFirst().first {
            let isRTL = effectiveReadingDirection == .rightToLeft
            // 辞書リテラルにしないのはViewerViewModel.anchorPinStatesと同じ理由(コメント参照)。
            var states: [String: PageLayoutState] = [:]
            states[earlier] = isRTL ? .spreadRight : .spreadLeft
            states[later] = isRTL ? .spreadLeft : .spreadRight
            return states
        } else if let only = anchor.pageKeys.first {
            return [only: explicitState]
        }
        return [:]
    }

    private func isWideImage(width: Int, height: Int) -> Bool {
        guard height > 0 else { return false }
        let ratio = Double(width) / Double(height)
        return ratio >= preferences.singlePageAspectRatioThreshold
    }

    /// 対象ページが「横長画像(見開き表示中でも単ページ扱いにすべき)」かどうかを判定する。
    ///
    /// 以前はthumbnail(rawIndex:)で1ページずつサムネイルを実際にデコードして幅・高さを見て
    /// いたが、判定に必要なのは縦横比だけで、デコードしたピクセルは一切使っていなかった。
    /// 伝播範囲が「本全体」の場合はこれを全ページに対して行うため、ページ数の多い本では
    /// レイアウトの変更操作そのものが目に見えて遅くなっていた。ビューア側の同名メソッド
    /// (ViewerViewModel.wideImageAspectRatios)は既に、ピクセルデコードを伴わない
    /// PageLoader.pageSize(at:)(フォーマットのヘッダーだけを読む)へ置き換え済みで、
    /// この編集ウインドウ側だけが古いままだった。同じ方式に揃える。
    private func wideImageAspectRatios(for pageKeys: [String]) async -> [String: Bool] {
        let keySet = Set(pageKeys)
        var result: [String: Bool] = [:]
        for row in rows where keySet.contains(row.pageKey) {
            guard let size = await pageLoader?.pageSize(at: row.rawIndex) else { continue }
            result[row.pageKey] = isWideImage(width: size.width, height: size.height)
        }
        return result
    }

    /// 4.2節の「レイアウト」ドロップダウンで、レイアウトなし以外に変更した際に呼ぶ。
    /// ビューアのViewerViewModel.setPageLayout(atIndex:to:scope:)と同じアルゴリズムを、
    /// この編集ウインドウのrows(除外ページも含む)向けに再構成したもの。
    ///
    /// overridesByKeyは、起点ページ自身への書き込み(anchorPinStates)より前の時点で1回だけ
    /// 取得したスナップショットを使う。そちら自体が「他のページ」の除外状態を変えることは無い
    /// (起点ページ自身の状態しか書き込まない)ため、この後のreadableKeys/
    /// wideImageAspectRatios/recalculateの計算中に除外状態が変化する心配はない。
    func setPageLayout(pageKey: String, to state: PageLayoutState, scope: LayoutPropagationScope) async {
        guard let book else { return }
        let overridesByKey = currentOverridesByKey()

        // 除外(非表示)から除外以外の状態に変わる場合、ファイル名基準の自然順で想定される位置へ
        // 並び順を補正する(ユーザー要望)。除外中はrows内の位置がそのまま保持される
        // (exclusion自体はrowsを並べ替えない)ため、解除しても元あった無関係な位置に取り残されて
        // しまう。readable/anchorの計算より前に行うことで、以降のパリティ計算・見開き相手の
        // 判定もこの補正後の位置を基準にする(repositionExcludedPageByFilename参照)。
        if overridesByKey[pageKey] == .excluded, state != .excluded {
            repositionExcludedPageByFilename(pageKey: pageKey, overridesByKey: overridesByKey)
        }

        guard scope != .thisPageOnly else {
            // 「このページだけ」は、ユーザーが直接操作したページ自身の行だけを書き換える。
            // 以前はここでもwriteAnchorPin(見開き左/右の相方ページへの書き込みを含む)を
            // 呼んでいたが、「ページ2を見開き左に設定すると、指示していないページ3まで
            // 見開き右に変わる」というユーザー報告により、相方ページへは触れない仕様に変更した。
            // 見開き左/右は、相方ページに明示的な設定が無くても表示時に自動でペアと判定される
            // (ViewerViewModel.shouldPairWithNextPage/layoutHint参照: 隣接する2ページの
            // どちらか一方でも明示指定があれば、もう一方がcenter/left(またはcenter/right)相当
            // でない限りペア表示になる)ため、相方ページの行を書き換える必要は無い。
            layoutStore.setPageLayoutState(for: book, pageKey: pageKey, state: state)
            // 除外状態が変わった可能性がある(このページ自身が除外される/除外から戻る)ため、
            // effectiveReadingIndexを振り直す。
            refreshEffectiveIndices()
            postLayoutFocusChange(pageKey: pageKey)
            return
        }

        let readable = readableKeys(currentPageKey: pageKey, newState: state, overridesByKey: overridesByKey)
        let pageAnchor = anchor(forPageKey: pageKey, explicitState: state, in: readable)
        let wideness = await wideImageAspectRatios(for: readable)
        let planned = LayoutAutoCalculator.recalculate(
            orderedPageKeys: readable, anchor: pageAnchor, scope: scope,
            isWideImage: { wideness[$0] ?? false }, isRightToLeft: effectiveReadingDirection == .rightToLeft
        )
        // plannedはreadable(既に除外ページを取り除いた読書順キー列)の範囲内でしか計算されない
        // ため、この書き込みが「除外」設定済みのページに触れることは無い(3.3節・要望)。
        // 1件ずつsetPageLayoutStateを呼ぶのではなく、まとめて1回のトランザクションとして
        // 書き込む(setPageLayoutStatesのコメント参照。連続した個別書き込みが原因と思われる
        // 不具合(ユーザー報告)への対策)。起点ページ自身への書き込み(anchorPinStates)も、
        // 別の書き込みとして分けずにここへマージして1回で済ませる。
        //
        // マージの向きは「anchorPinStatesがplannedを上書きする」。これは以前
        // writeAnchorPinをplannedの適用より後に呼んでいたのと同じ意味になる
        // (ViewerViewModel.setPageLayoutと同じ修正・同じ理由)。
        //
        // 経緯(ユーザー報告): 本の先頭ページを「見開き左」に設定しても、実際には「単一
        // ページ」に置き換わってしまう不具合があった。原因は書き込み順序にあった:
        // writeAnchorPinを先に呼ぶと、いったんは正しくspreadLeftが書き込まれるが、
        // scope==.wholeBookの場合、直後にLayoutAutoCalculator.recalculateが内部で
        // anchorPin(起点の組み合わせをそのまま固定する処理。本来はViewerViewModel.
        // autoLayoutFromCurrentView()向けに「現在表示されている組み合わせ」から起点の状態を
        // 再構成するための関数で、ユーザーが直接指定したstateそのものは知らない)を再計算し、
        // plannedに含めてしまう。先頭ページは相方(1つ前のページ)が存在しないためAnchorが
        // 1件だけになり、この場合anchorPinの実装は常に.singleを返す(2ページ揃った通常の
        // ケースでは「見開き左/右」を返すため、この不具合は表面化しなかった)。この.singleが
        // 後からlayoutStore.setPageLayoutStates(planned)で書き込まれ、直前にwriteAnchorPinが
        // 書いた正しいspreadLeftを上書きしてしまっていた。writeAnchorPinをplannedの適用
        // より後に呼ぶことで、ユーザーが直接指定したstateが常に最終的な書き込みとして
        // 勝つようにする(2ページ揃った通常のケースでは、planned側のanchorPinと
        // anchorPinStatesが同じ値を書くため、どちらが勝っても結果は変わらない)。
        var merged = planned
        for (pinnedPageKey, pinnedState) in anchorPinStates(pageAnchor, explicitState: state) {
            merged[pinnedPageKey] = pinnedState
        }
        layoutStore.setPageLayoutStates(for: book, merged)
        // 除外状態が変わった可能性があるため、effectiveReadingIndex(ブックマークの突き合わせに
        // 使う空間)を振り直す。並び順自体(rowsの順序)は変わらない。
        refreshEffectiveIndices()
        postLayoutFocusChange(pageKey: pageKey)
    }

    /// 4.2節の「レイアウト」ドロップダウンで「レイアウトなし」に戻した場合。伝播範囲の選択は
    /// 行わない(このページ自体を未設定に戻すだけの操作のため。ViewerViewModel.clearPageLayoutと
    /// 同じ考え方)。
    func clearPageLayout(pageKey: String) {
        guard let book else { return }
        let overridesByKey = currentOverridesByKey()
        let wasExcluded = overridesByKey[pageKey] == .excluded
        layoutStore.setPageLayoutState(for: book, pageKey: pageKey, state: nil)
        // 「レイアウトなし」に戻す操作も、除外からの解除に当たる場合はsetPageLayoutと同じく
        // ファイル名基準の位置へ補正する(repositionExcludedPageByFilename参照)。
        if wasExcluded {
            repositionExcludedPageByFilename(pageKey: pageKey, overridesByKey: overridesByKey)
        }
        refreshEffectiveIndices()
        postLayoutFocusChange(pageKey: pageKey)
    }

    /// 除外(非表示)から除外以外の状態に変更されたページを、ファイル名基準の自然順で想定される
    /// 位置へ挿入し直す(ユーザー要望: 「除外からそれ以外の状態に設定変更した場合、ページの
    /// 並び順はファイル名から想定される位置に自動で移動してください」)。
    ///
    /// 除外中はrows(=pageOrderOverride)内の位置がそのまま保持される(除外の設定・解除自体は
    /// 並び順を変更しないため)。そのため、並べ替え済みの本で一部ページを除外→解除すると、
    /// 除外前にたまたま置かれていた無関係な位置に取り残されてしまう(4.3節の編集ウインドウでは
    /// 除外ページを常に一覧末尾にファイル名順で表示している(Round5)ため、解除した瞬間に
    /// 無関係な位置へワープして見えるのを防ぐ狙いもある)。
    ///
    /// book.pages(BookLoaderが返す自然順=ファイル名/アーカイブ内パス順)上で、対象ページの
    /// 直前にあたり、かつ現在除外されていない(=表示上visibleな)ページを探し、現在のrows
    /// (カスタム並び替え後の順序でもよい)上でのそのページの直後に挿入する。該当する直前の
    /// ページが見つからない場合(自然順で最初のページ、またはそれより前が全て除外中)は、
    /// rowsの先頭に挿入する。
    ///
    /// - overridesByKey: 呼び出し元がこのページ自身の状態変更より前に取得したスナップショット
    ///   (他ページの除外状態の判定に使う。このページ自身の除外状態はここでは参照しない)。
    private func repositionExcludedPageByFilename(pageKey: String, overridesByKey: [String: PageLayoutState]) {
        guard let book else { return }
        let naturalOrderKeys = book.pages.map(\.sortKey)
        guard let naturalIndex = naturalOrderKeys.firstIndex(of: pageKey) else { return }

        var predecessorKey: String?
        var cursor = naturalIndex - 1
        while cursor >= 0 {
            let candidate = naturalOrderKeys[cursor]
            if overridesByKey[candidate] != .excluded {
                predecessorKey = candidate
                break
            }
            cursor -= 1
        }

        guard let targetIndex = rows.firstIndex(where: { $0.pageKey == pageKey }) else { return }
        var reordered = rows
        let targetRow = reordered.remove(at: targetIndex)
        if let predecessorKey, let predecessorIndex = reordered.firstIndex(where: { $0.pageKey == predecessorKey }) {
            reordered.insert(targetRow, at: predecessorIndex + 1)
        } else {
            reordered.insert(targetRow, at: 0)
        }
        rows = reordered
        layoutStore.setPageOrderOverride(for: book, rows.map(\.pageKey))
    }

    /// この本のレイアウト設定を、この編集ウインドウから直接操作したページ(pageKey)込みで
    /// 変更したことを、この本を今開いているウインドウ/タブ(ビューア)へ伝える。
    /// layoutStore.setPageLayoutState/setPageOrderOverride自体が既にbookIDのみの通知
    /// (.layoutDataDidChange)を投げているが、userInfoに"focusPageKey"を追加したこの通知を
    /// 別途投げることで、ViewerViewModel.layoutDataChangeObserverが「どのページを更新後の
    /// 表示に含めるべきか」を判定できるようにする(ユーザー要望: 「更新後のビューア画面は、
    /// 直接操作されたページを表示に含める」。ViewerViewModel.postLayoutFocusChangeと対になる)。
    private func postLayoutFocusChange(pageKey: String) {
        guard let book else { return }
        NotificationCenter.default.post(
            name: .layoutDataDidChange, object: nil, userInfo: ["bookID": book.id, "focusPageKey": pageKey]
        )
    }

    /// レイアウト変更の書き込みがすべて完了した後に1回だけ呼ぶ。pageLayoutStates
    /// (Picker表示用の公開スナップショット)とrows[].effectiveReadingIndexの両方を、
    /// この時点のSwiftDataの状態から同時に更新する。
    private func refreshEffectiveIndices() {
        let overridesByKey = currentOverridesByKey()
        pageLayoutStates = overridesByKey
        rows = recomputeEffectiveIndices(for: rows, overridesByKey: overridesByKey)
    }

    // MARK: - 本全体の設定(4.2節上部の読み方向ドロップダウン)

    /// 読み方向の上書き(未設定ならnil、環境設定の既定値/BookReadingStateに従う)。
    /// bookをこのクラスの外に公開せず、LayoutStore呼び出しをここに閉じ込めるためのラッパー。
    func setReadingDirectionOverride(_ direction: ReadingDirection?) {
        guard let book else { return }
        layoutStore.setReadingDirectionOverride(for: book, direction)
    }
}
