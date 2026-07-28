import Foundation
import CoreGraphics
import SwiftData
import Combine

/// ビューワー画面(ページ表示)の状態を管理する ViewModel。
/// ページ送り、見開き/単ページの切り替え、読み方向の切り替え、表示スケーリングモード、
/// ブックマーク、スライドショーを担当する。
/// 実際の画像読み込み・デコード・キャッシュ・先読みは PageLoader(actor)に委譲し、
/// ここでは「今どのページを表示すべきか」という状態管理と、SwiftUIへの反映に専念する。
/// 本ごとの読書状態(最後に読んだページ・表示モード・読み方向・表示スケーリング)はSwiftDataで永続化する。
@MainActor
final class ViewerViewModel: ObservableObject {
    let book: MangaBook

    @Published var currentIndex: Int
    @Published var displayMode: DisplayMode
    @Published var readingDirection: ReadingDirection
    @Published var scalingMode: ScalingMode
    @Published private(set) var currentImages: [CGImage] = []
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var isSlideshowActive = false
    /// 環境設定「本を再度開いたときの動作」が「問い合わせる」のとき、かつ前回位置が
    /// 先頭でない(=本当に「再開」の余地がある)ときにtrueになる。ViewerViewがこれを見て
    /// 「前回表示したページから再開しますか?」の確認ダイアログを表示する。
    @Published private(set) var needsResumeConfirmation: Bool

    /// ページ境界(最初/最後)を超えて隣の本へ移動する必要があるときに呼ばれる。
    /// (true = 次の本へ, false = 前の本へ)。ViewerView側が appState 経由で実装をセットする。
    var onRequestSiblingBook: ((Bool) -> Void)?

    private let modelContext: ModelContext
    private let readingState: BookReadingState
    private let pageLoader: PageLoader
    private let preferences: AppPreferences
    /// 「ブックマークの編集」ウインドウ(BookmarkStore、この本を今開いていなくても操作できる
    /// 独立ウインドウ)側でこの本のブックマークが変更されたときに、自分のbookmarks配列を
    /// 読み直すための監視トークン。詳細はBookmark.swiftのNotification.Name.bookmarksDidChange
    /// のコメント参照。
    private var bookmarksChangeObserver: NSObjectProtocol?

    /// 非同期の読み込みが完了したとき、それが「一番新しいリクエストか」を判定するための世代番号。
    /// 素早くページ送りされたときに、古い読み込みが後から完了して表示を巻き戻すのを防ぐ。
    private var loadGeneration = 0
    /// 直近の画像読み込みタスク。スクロールホイールなどで素早く連続してページ送りされたとき、
    /// 古いリクエストの読み込み(デコードや先読み)がキャンセルされずに残り続けると、
    /// CPU/デコード処理の順番待ちが積み重なって最新のページの表示が遅れる原因になる。
    /// そのため新しいリクエストを出す前に必ず前回のタスクをキャンセルする。
    private var reloadTask: Task<Void, Never>?
    private var slideshowTask: Task<Void, Never>?
    /// スクロールホイールなどで素早く連続してページ送りされたときに、通過するページも
    /// 一瞬ずつ実際に表示してから最終的な目的地に着地させるための待ち行列。
    /// advance(forward:)が呼ばれるたびに目的地のインデックスを1件ずつここに積み、
    /// 専用のTask(pageFlipTask)が順番に1件ずつcurrentIndexへ反映・表示していく。
    /// 素早く連続で呼ばれても新しいタスクを起動し直すのではなく、既存のタスクが
    /// そのまま続けて処理するので、積んだ順番通りにすべてのページが画面に一瞬ずつ映る
    /// (以前は毎回reloadTaskをキャンセルして最後の1回分しか表示していなかった)。
    private var pageFlipQueue: [Int] = []
    private var pageFlipTask: Task<Void, Never>?
    /// 通過ページを一瞬だけ表示する間隔。短すぎると目に映らず、長すぎるとページ数が
    /// 多いときにもたついて見えるため、この程度が体感上ちょうどよい値。
    private let pageFlipFrameDuration: UInt64 = 10_000_000 // 0.01秒
    /// SwiftDataへの実際の保存(ディスクI/O)をまとめて行うためのデバウンス用タスク。
    private var saveDebounceTask: Task<Void, Never>?

    init(book: MangaBook, modelContext: ModelContext, preferences: AppPreferences) {
        self.book = book
        self.modelContext = modelContext
        self.preferences = preferences
        self.pageLoader = PageLoader(book: book)

        let bookID = book.id
        var descriptor = FetchDescriptor<BookReadingState>(
            predicate: #Predicate<BookReadingState> { $0.bookID == bookID }
        )
        descriptor.fetchLimit = 1

        // bookID(パス)が同じでも、そのファイル/フォルダの中身が実際には別のものに
        // 差し替わっていることがある(同じ名前で別の本をダウンロードし直した、フォルダの
        // 中身を丸ごと入れ替えた等)。完全な内容比較(ハッシュ値計算など)はコストが高いため、
        // 代わりに(1)ページ数 (2)元のファイル/フォルダの更新日時 (3)ファイルサイズ
        // (フォルダの場合は取得できないため常にnil)を軽量な「指紋」として使い、前回保存した
        // 値と1つでも異なれば「差し替えられた別の内容」とみなす。
        let currentPageCount = book.pages.count
        let sourceResourceValues = try? book.sourceURL.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let currentModificationDate = sourceResourceValues?.contentModificationDate
        let currentFileSize = sourceResourceValues?.fileSize.map(Int64.init)

        let fetchedState = try? modelContext.fetch(descriptor).first
        // recordedPageCountがnilなのは、この指紋の仕組みを導入する前に保存された古いデータ
        // (まだ比較のしようがない)ということなので、その場合は「差し替えなし」として扱う。
        let contentLooksReplaced: Bool
        if let fetchedState, let recordedPageCount = fetchedState.recordedPageCount {
            contentLooksReplaced =
                recordedPageCount != currentPageCount
                || fetchedState.recordedSourceModificationDate != currentModificationDate
                || fetchedState.recordedSourceFileSize != currentFileSize
        } else {
            contentLooksReplaced = false
        }
        // 「以前から読んでいる本」として扱ってよいのは、データが見つかり、かつ中身が
        // 差し替えられていないと判断できた場合だけ。差し替えられていた場合は、古い読書状態と
        // ブックマークを削除し、初めて開く本として扱う(以下のisReturningToKnownBook参照)。
        let existingState: BookReadingState? = (fetchedState != nil && !contentLooksReplaced) ? fetchedState : nil
        let isReturningToKnownBook = existingState != nil

        let state: BookReadingState
        if let existingState {
            state = existingState
        } else {
            if let fetchedState, contentLooksReplaced {
                // 中身が差し替わっていると判断した本: 古いブックマークと読書状態を削除する。
                let staleBookID = fetchedState.bookID
                let staleBookmarkDescriptor = FetchDescriptor<Bookmark>(
                    predicate: #Predicate<Bookmark> { $0.bookID == staleBookID }
                )
                if let staleBookmarks = try? modelContext.fetch(staleBookmarkDescriptor) {
                    for bookmark in staleBookmarks {
                        modelContext.delete(bookmark)
                    }
                }
                modelContext.delete(fetchedState)
            }
            state = BookReadingState(bookID: bookID, scalingMode: preferences.defaultScalingMode)
            modelContext.insert(state)
            // 新しい本を開いたとき(初めて開く本、または中身が差し替わったと判断した本)だけ、
            // 本ごとのデータ(読書状態・ブックマーク)が環境設定の上限を超えていないか確認し、
            // 超えていれば最後に読んだ時刻が古い本から削除する(LibraryDataPruner.swift参照)。
            // 既存の本をそのまま開き直すだけのときは件数が増えないため、ここでは呼ばない。
            LibraryDataPruner.pruneIfNeeded(
                modelContext: modelContext,
                maxTrackedBooks: max(Int(preferences.maxTrackedBooksCount), 1)
            )
        }
        // 今回の指紋を常に記録しておく(次回開いたときの比較対象になる)。
        state.recordedPageCount = currentPageCount
        state.recordedSourceModificationDate = currentModificationDate
        state.recordedSourceFileSize = currentFileSize
        self.readingState = state

        // 環境設定「本を再度開いたときの動作」に応じて、実際にどのページから表示するかを決める。
        // (以前から読んでいる本(isReturningToKnownBookがtrueの場合)にのみ意味がある判定で、
        // 初めて開く本・中身が差し替わった本は常にlastPageIndexが0のため、どの設定でも結果は変わらない)
        let restoredIndex = min(max(state.lastPageIndex, 0), max(book.pages.count - 1, 0))
        let wasOnLastPage = book.pages.count > 0 && restoredIndex >= book.pages.count - 1
        let initialIndex: Int
        var needsConfirmation = false
        switch preferences.reopenBehavior {
        case .resume:
            initialIndex = restoredIndex
        case .alwaysFromStart:
            initialIndex = 0
        case .fromStartIfFinishedLastTime:
            initialIndex = wasOnLastPage ? 0 : restoredIndex
        case .ask:
            // 前回位置がすでに先頭(0)なら、尋ねるまでもなくそのまま先頭から表示する。
            initialIndex = restoredIndex
            needsConfirmation = isReturningToKnownBook && restoredIndex > 0
        }

        // EPUBがpage-progression-direction/rendition:spreadを明示している場合、保存されていた
        // 設定より優先してその値を採用する(値が無い項目は、これまで通りSwiftDataの保存値に従う)。
        // 対応する切り替え操作(toggleReadingDirection/toggleDisplayMode)自体も、この値が
        // 強制されている間は無効化する(isReadingDirectionLocked/isDisplayModeLocked参照)。
        self.displayMode = book.epubLayoutHint?.forcedDisplayMode ?? state.displayMode
        self.readingDirection = book.epubLayoutHint?.pageProgressionDirection ?? state.readingDirection
        self.scalingMode = state.scalingMode
        self.needsResumeConfirmation = needsConfirmation
        // 保存されていた(または直前に計算した)ページ位置が、EPUBのpage-spread-right指定を
        // 持つページをそのまま指していると、そのページ単体が見開きの起点であるかのように
        // 扱われてしまい、本来組になるはずの1つ前のページが表示されない状態になる。
        // jump(toPageIndex:)と同じ補正をここでも適用しておく(詳細はnormalizedAnchorIndex参照)。
        self.currentIndex = Self.normalizedAnchorIndex(initialIndex, in: book)

        Task { [weak self] in
            await self?.loadCurrentSpread()
        }
        reloadBookmarks()

        // 「ブックマークの編集」ウインドウは本のウインドウとは独立しているため、そちらで
        // この本のブックマークが削除・リネームされても、このViewerViewModelは何もしなければ
        // 気づけない。bookIDが一致する変更だけを拾って読み直す(BookmarkStoreのコメント参照)。
        // userInfoに"bookID"が無い通知(BookmarkStore.deleteAllBookmarks()による全件リセット。
        // 環境設定「リセット」タブ参照)は、本を問わず常に読み直す対象として扱う。
        let ownBookID = bookID
        bookmarksChangeObserver = NotificationCenter.default.addObserver(
            forName: .bookmarksDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            let changedBookID = notification.userInfo?["bookID"] as? String
            guard changedBookID == nil || changedBookID == ownBookID else { return }
            self?.reloadBookmarks()
        }
    }

    deinit {
        if let bookmarksChangeObserver {
            NotificationCenter.default.removeObserver(bookmarksChangeObserver)
        }
    }

    /// 「前回表示したページから再開しますか?」の確認ダイアログへの回答を反映する。
    /// shouldResume が false のときは先頭ページへジャンプし直す。
    func confirmResumeFromLastPage(_ shouldResume: Bool) {
        needsResumeConfirmation = false
        if !shouldResume {
            jump(toPageIndex: 0)
        }
    }

    var pageCount: Int { book.pages.count }

    /// forward: true = 物語的に「次のページ」へ進む、false = 「前のページ」へ戻る
    /// ステップ数は「今表示している画像の枚数」を使う。横長画像で単ページ表示になっている場合は
    /// 1枚分だけ進む/戻るようにするため(見開き設定でも常に2ページ分ずれるわけではない)。
    func advance(forward: Bool) {
        // まだ表示できていない待ち行列中の目的地があれば、そこを起点に次の目的地を計算する
        // (currentIndexは、待ち行列の処理がまだ追いついていない古い値のことがあるため)。
        let baseIndex = pageFlipQueue.last ?? currentIndex
        let step = max(currentImages.count, 1)
        if forward {
            if baseIndex + step < book.pages.count {
                enqueuePageFlip(to: baseIndex + step)
            } else if pageFlipQueue.isEmpty {
                // アニメーションで通過中(待ち行列に処理待ちが残っている)にページ境界へ
                // 達した場合、次の本への移動などの境界処理は待ち行列が空になってから、
                // あらためてこの関数が呼ばれたときに行う(ここでは何もしない)。
                handleForwardBoundary()
            }
        } else {
            if baseIndex - step >= 0 {
                enqueuePageFlip(to: baseIndex - step)
            } else if baseIndex != 0 {
                enqueuePageFlip(to: 0)
            } else if pageFlipQueue.isEmpty {
                handleBackwardBoundary()
            }
        }
    }

    /// advance(forward:)から呼ばれる、待ち行列への追加とアニメーション開始。
    private func enqueuePageFlip(to index: Int) {
        guard index != (pageFlipQueue.last ?? currentIndex) else { return }
        pageFlipQueue.append(index)
        guard pageFlipTask == nil else { return }
        pageFlipTask = Task { [weak self] in
            await self?.drainPageFlipQueue()
        }
    }

    /// 待ち行列に積まれた目的地へ移動・表示していく。
    /// 通常のキー入力・ボタンクリックなど「1回だけ」の操作(待ち行列にこの1件しか
    /// 積まれていない場合)は、以前と同じくアニメーションなしで即座に目的のページへ移動する
    /// (見開き表示で2ページ先へ進む場合も、間のページを経由して見せたりはしない)。
    /// スクロールホイールなどで素早く連続して呼ばれ、待ち行列に複数の目的地が積まれている
    /// ときだけ、通過するページも(見開き表示中はその見た目のまま)1ページずつ一瞬表示する。
    private func drainPageFlipQueue() async {
        defer { pageFlipTask = nil }
        while !pageFlipQueue.isEmpty {
            if pageFlipQueue.count == 1 {
                let target = pageFlipQueue.removeFirst()
                currentIndex = target
                persistState()
                await loadCurrentSpread(prefetch: true)
                continue
            }

            let target = pageFlipQueue.removeFirst()
            let isFinalQueueItem = pageFlipQueue.isEmpty
            let direction = target > currentIndex ? 1 : (target < currentIndex ? -1 : 0)
            while currentIndex != target {
                currentIndex += direction
                let isLandingFrame = isFinalQueueItem && currentIndex == target
                if isLandingFrame {
                    // 本当に止まったページ: ここでだけ本来のページ組み合わせでの見開きペアリングと
                    // 先読みを行う(通過中のペアリングはあくまで見た目重視の簡易表示のため)。
                    persistState()
                    await loadCurrentSpread(prefetch: true)
                } else {
                    // 通過中のコマ: 先読みは行わないが、見開き表示中は見た目を保つため
                    // このページを含む隣接ページとのペア表示を試みる。
                    await loadTransitFrame(at: currentIndex)
                    // このコマの表示時間(下のsleep)を使って、次に表示する予定のページ(と、
                    // 見開き表示中ならそのペア相手)のデコードを先に始めておく(結果は待たない)。
                    // ページによってデコード時間にばらつきがあっても、1コマ分前もって着手して
                    // おくことでその待ち時間が表示中の時間と重なり、回し始めと回し終わりで
                    // 更新間隔がばらつくのを防ぐ。
                    let lookaheadIndex = currentIndex + direction
                    if book.pages.indices.contains(lookaheadIndex) {
                        let loader = pageLoader
                        Task {
                            await loader.prefetch(around: lookaheadIndex, radius: 1)
                        }
                    }
                    try? await Task.sleep(nanoseconds: pageFlipFrameDuration)
                }
            }
        }
    }

    /// ページめくりアニメーションの通過中コマ用の表示。先読みは行わないが、見開き表示中は
    /// (実際に止まったときの見た目に近づけるため)このページと次のページのペア表示を試みる
    /// 横長画像であれば単ページのまま。単ページ表示中は常にこのページ1枚だけを表示する。
    private func loadTransitFrame(at index: Int) async {
        guard let firstImage = await pageLoader.pageImage(at: index) else { return }
        var images = [firstImage]
        if shouldPairWithNextPage(at: index, firstImage: firstImage),
           let secondImage = await pageLoader.pageImage(at: index + 1) {
            images.append(secondImage)
        }
        currentImages = images
    }

    /// プログレスバーでのジャンプなど、通過ページの表示が不要な「即座に移動する」操作の前に呼び、
    /// 進行中のページめくりアニメーションの残りをキャンセルする。
    /// (すでに実行中の1コマ分の表示はそのまま完了させ、それ以降の待ち行列だけを空にする。
    ///  Task自体を強制中断すると非同期処理の後始末が複雑になるため、待ち行列を空にして
    ///  自然に終了させる方式にしている)
    private func cancelPendingPageFlip() {
        pageFlipQueue.removeAll()
    }

    /// 見開き/単ページ設定にかかわらず、常にちょうど1ページだけ進む/戻る。
    /// 見開きのページの組み合わせ(奇数/偶数ペア)がずれてしまったときに、手動で調整するための操作。
    /// (advanceと違い、ページ境界に達しても隣の本へは移動しない。あくまで微調整用)
    func shiftByOnePage(forward: Bool) {
        guard !book.pages.isEmpty, !isPageShiftLocked else { return }
        cancelPendingPageFlip()
        if forward {
            guard currentIndex + 1 < book.pages.count else { return }
            currentIndex += 1
        } else {
            guard currentIndex - 1 >= 0 else { return }
            currentIndex -= 1
        }
        persistState()
        reloadAsync()
    }

    /// プログレスバーをクリック/ドラッグした位置のページへ直接ジャンプする。
    /// 着地先はnormalizedAnchorIndexで補正するため、EPUBがpage-spread-rightを指定している
    /// ページを直接指定しても、実際にはその1つ前(組になるページ)へ着地し、正しい組み合わせで
    /// 表示される。
    func jump(toPageIndex index: Int) {
        guard !book.pages.isEmpty else { return }
        cancelPendingPageFlip()
        let clamped = max(0, min(index, book.pages.count - 1))
        let normalized = Self.normalizedAnchorIndex(clamped, in: book)
        guard normalized != currentIndex else { return }
        currentIndex = normalized
        persistState()
        reloadAsync()
    }

    /// 数字キー(0〜9)によるページジャンプ用。全ページ数に対する割合(0〜100)を指定し、
    /// 対応するページへジャンプする(0なら先頭ページ、90なら全ページ数の90%に相当するページ)。
    /// 実際の着地先の補正・境界チェックはjump(toPageIndex:)にそのまま委譲する。
    func jump(toPercentile percentile: Int) {
        guard !book.pages.isEmpty else { return }
        let index = book.pages.count * percentile / 100
        jump(toPageIndex: index)
    }

    /// EPUBがrendition:spreadで本全体の見開き/単ページを強制している間はtrue。
    /// trueの間はtoggleDisplayMode()自体が何もしない(呼び出し元のUIも合わせて
    /// グレーアウトする。ViewerView/QooViewerAppの`.disabled()`参照)。
    var isDisplayModeLocked: Bool {
        book.epubLayoutHint?.forcedDisplayMode != nil
    }

    /// EPUBがpage-progression-directionで読み方向を明示している間はtrue。
    /// trueの間はtoggleReadingDirection()自体が何もしない。
    var isReadingDirectionLocked: Bool {
        book.epubLayoutHint?.pageProgressionDirection != nil
    }

    /// 現在表示中の見開きに、EPUBのpage-spread-left/right/rendition:page-spread-center指定を
    /// 持つページが含まれている間はtrue。この状態で「1ページだけ送る」調整を行うと、
    /// 著者が指定したページの組み合わせが崩れてしまうため、shiftByOnePage()自体が何もしない。
    var isPageShiftLocked: Bool {
        guard displayMode == .spread, book.pages.indices.contains(currentIndex) else { return false }
        if book.pages[currentIndex].epubSpreadPosition != nil { return true }
        let partnerIndex = currentIndex + 1
        guard currentImages.count > 1, book.pages.indices.contains(partnerIndex) else { return false }
        return book.pages[partnerIndex].epubSpreadPosition != nil
    }

    func toggleDisplayMode() {
        guard !isDisplayModeLocked else { return }
        cancelPendingPageFlip()
        displayMode = (displayMode == .spread) ? .single : .spread
        persistState()
        reloadAsync()
    }

    func toggleReadingDirection() {
        guard !isReadingDirectionLocked else { return }
        // 表示中の画像自体は変わらず、並び順だけがViewer側で反転するので再読み込みは不要
        readingDirection = (readingDirection == .rightToLeft) ? .leftToRight : .rightToLeft
        persistState()
    }

    func cycleScalingMode() {
        scalingMode = scalingMode.next
        persistState()
    }

    /// メニューバーの「表示モード切替」サブメニューから、特定のモードへ直接切り替えるために使う
    /// (cycleScalingModeが常に「次のモード」へ進めるのに対し、こちらは指定したモードへ直接移る)。
    func setScalingMode(_ mode: ScalingMode) {
        guard scalingMode != mode else { return }
        scalingMode = mode
        persistState()
    }

    /// ページ一覧(グリッド)のセルや、プログレスバーのホバープレビュー用の軽量なサムネイル取得。
    /// @Publishedプロパティを経由しないため、1件の読み込みがViewerViewModel全体を
    /// 購読している他のView(ページ本体の巨大な画像領域や他のセルなど)の再描画を
    /// 引き起こさない。(実体のキャッシュはPageLoaderのNSCacheが担うので、
    /// 呼び出し側でThumbnailを保持しておけば、二重にキャッシュすることにはならない)
    func loadThumbnail(at index: Int) async -> CGImage? {
        guard book.pages.indices.contains(index) else { return nil }
        return await pageLoader.thumbnail(at: index)
    }

    // MARK: - ブックマーク

    private func reloadBookmarks() {
        let bookID = book.id
        let descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate<Bookmark> { $0.bookID == bookID },
            sortBy: [SortDescriptor(\.pageIndex)]
        )
        bookmarks = (try? modelContext.fetch(descriptor)) ?? []
    }

    func addBookmark() {
        // 同じページに対するブックマークが既にある場合は、重複して追加しない(要望)。
        // bookmarksはreloadBookmarks()で都度読み直しているため、ここでの判定は常に最新の状態を見る。
        guard !bookmarks.contains(where: { $0.pageIndex == currentIndex }) else { return }
        // ブックマークの名前(SwiftDataに永続化される実データ)は、後から表示言語を切り替えても
        // 変わらない「作成時点の言語」で作られる。作成時点の表示言語設定(preferences.effectiveLocale)を
        // 使ってその場で解決することで、システム言語とは独立したアプリ内表示言語にも対応する。
        let pagePrefix = String(localized: "Page", locale: preferences.effectiveLocale)
        // セキュリティスコープ付きブックマークを一緒に保存しておく(FavoriteBook.bookmarkDataと
        // 同じ理由。「ブックマークの編集」ウインドウから、今開いていない本を新たに開いてジャンプ
        // する機能(要望2〜4)のために必要。今この本を開けている=このURLへのアクセス権を
        // 持っている、という前提でここで生成する)。
        let bookmarkData = try? book.sourceURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let bookmark = Bookmark(
            bookID: book.id,
            pageIndex: currentIndex,
            name: "\(pagePrefix) \(currentIndex + 1)",
            bookmarkData: bookmarkData
        )
        modelContext.insert(bookmark)
        try? modelContext.save()
        reloadBookmarks()
        postBookmarksDidChange()
    }

    // 以前はここに削除(removeBookmark)・リネーム(renameBookmark)もあったが、「ブックマークの
    // 編集」ウインドウがすべての本を横断する構成になり、BookmarkStore.delete(_:)/
    // rename(_:to:)がSwiftDataを直接操作するようになったため(本を開いているかどうかに関わらず
    // 操作できる必要があるため)、これらは不要になり削除した。この本を今開いている間の反映は
    // 上のbookmarksChangeObserverが担う。

    /// 「ブックマークの編集」ウインドウ(横断的に全ての本を扱うBookmarkStore)側にも、この本の
    /// ブックマークが変更されたことを伝える。自分自身が投げた通知を上のbookmarksChangeObserverで
    /// 再度受け取ることになるが、reloadBookmarks()をもう一度呼ぶだけの無害な重複であるため、
    /// あえて自分自身を除外する仕組みは設けていない。
    private func postBookmarksDidChange() {
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: ["bookID": book.id])
    }

    func jump(to bookmark: Bookmark) {
        jump(toPageIndex: bookmark.pageIndex)
    }

    func jumpToNextBookmark() {
        guard let next = bookmarks.first(where: { $0.pageIndex > currentIndex }) else { return }
        jump(toPageIndex: next.pageIndex)
    }

    func jumpToPreviousBookmark() {
        guard let previous = bookmarks.last(where: { $0.pageIndex < currentIndex }) else { return }
        jump(toPageIndex: previous.pageIndex)
    }

    // MARK: - スライドショー

    func toggleSlideshow() {
        if isSlideshowActive {
            stopSlideshow()
        } else {
            startSlideshow()
        }
    }

    func startSlideshow() {
        guard !isSlideshowActive else { return }
        isSlideshowActive = true
        let intervalSeconds = preferences.slideshowInterval
        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(intervalSeconds, 0.5) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await MainActor.run {
                    guard self.isSlideshowActive else { return }
                    let step = max(self.currentImages.count, 1)
                    if self.currentIndex + step < self.book.pages.count {
                        self.advance(forward: true)
                    } else {
                        self.stopSlideshow()
                    }
                }
            }
        }
    }

    func stopSlideshow() {
        isSlideshowActive = false
        slideshowTask?.cancel()
        slideshowTask = nil
    }

    // MARK: - 境界処理(ループ設定)

    private func handleForwardBoundary() {
        switch preferences.loopBehavior {
        case .loop:
            cancelPendingPageFlip()
            currentIndex = Self.normalizedAnchorIndex(0, in: book)
            persistState()
            reloadAsync()
        case .nextBookFirstPage, .nextBook:
            onRequestSiblingBook?(true)
        case .none:
            break
        }
    }

    private func handleBackwardBoundary() {
        switch preferences.loopBehavior {
        case .loop:
            cancelPendingPageFlip()
            let step = max(currentImages.count, 1)
            let rawIndex = max(0, book.pages.count - step)
            // ページ数と表示枚数だけから計算した折り返し先は、EPUBのpage-spread-right指定を
            // 持つページに直接着地する可能性がある(詳細はnormalizedAnchorIndexのコメント参照)。
            currentIndex = Self.normalizedAnchorIndex(rawIndex, in: book)
            persistState()
            reloadAsync()
        case .nextBookFirstPage, .nextBook:
            onRequestSiblingBook?(false)
        case .none:
            break
        }
    }

    // MARK: - 内部処理

    private func persistState() {
        // メモリ上のreadingStateは即座に更新する(他のコードから参照されても常に最新の状態になるように)。
        readingState.lastPageIndex = currentIndex
        readingState.displayMode = displayMode
        readingState.readingDirection = readingDirection
        readingState.scalingMode = scalingMode
        readingState.updatedAt = Date()

        // 実際のディスクへの保存(modelContext.save())は、ホイール操作などで素早く連続して
        // ページ送りされるたびに毎回行うとメインスレッドの処理が詰まり、画像の更新が
        // 遅れる原因になる。そのため保存だけは少し間隔を空けてまとめて行う(デバウンス)。
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            try? self.modelContext.save()
        }
    }

    /// デバウンス待ちの保存が残っている状態で本を閉じたり切り替えたりしても
    /// 読書位置が失われないよう、保留中の保存があれば即座に確定させる。
    /// ViewerViewのonDisappearから呼ばれる。
    func flushPendingSave() {
        guard saveDebounceTask != nil else { return }
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        try? modelContext.save()
    }

    private func reloadAsync() {
        // 前回の読み込みタスクが残っていれば、まずキャンセルしてから新しいタスクを開始する。
        // こうしないと、素早く連続してページ送りしたときに古いリクエストのデコード処理が
        // キャンセルされずキューに残り続け、最新のページの表示が遅れてしまう。
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.loadCurrentSpread()
        }
    }

    private func loadCurrentSpread(prefetch: Bool = true) async {
        loadGeneration += 1
        let generation = loadGeneration
        let targetIndex = currentIndex

        guard !Task.isCancelled else { return }

        var images: [CGImage] = []
        if let firstImage = await pageLoader.pageImage(at: targetIndex) {
            guard !Task.isCancelled else { return }
            images.append(firstImage)

            if shouldPairWithNextPage(at: targetIndex, firstImage: firstImage),
               let secondImage = await pageLoader.pageImage(at: targetIndex + 1) {
                images.append(secondImage)
            }
        }

        // 読み込み中にさらに新しいページ送りが起きていたら、この結果は古いので捨てる
        guard generation == loadGeneration, !Task.isCancelled else { return }
        currentImages = images

        // キャンセル済みなら、先読み(周辺ページのデコード)は行わずここで打ち切る。
        // これも「古いリクエストが最新のリクエストのデコード処理待ちを引き起こす」ことを防ぐため。
        guard !Task.isCancelled, prefetch else { return }
        let radius = max(Int(preferences.prefetchPageCount), 0)
        await pageLoader.prefetch(around: targetIndex, radius: radius)
    }

    /// 見開き表示中でも単ページとして扱うべき横長画像かどうかを判定する
    private func isWideImage(_ image: CGImage) -> Bool {
        guard image.height > 0 else { return false }
        let ratio = Double(image.width) / Double(image.height)
        return ratio >= preferences.singlePageAspectRatioThreshold
    }

    /// targetIndexのページを、次のページ(targetIndex + 1)と組にして見開き表示すべきかどうかを
    /// 判定する。loadCurrentSpread(実際に止まったページの表示)とloadTransitFrame(通過中の
    /// コマの簡易表示)の両方から共通で使う(ロジックが分かれていると、どちらかだけ直し忘れる
    /// バグの元になるため)。
    ///
    /// EPUBのpage-spread-left/right/rendition:page-spread-center指定がある場合は、その指定を
    /// 横長画像の自動単ページ化ヒューリスティック(isWideImage)より優先する。
    /// - targetIndex自身がcenter/right指定なら、そのページは見開きの起点(1枚目)にはなれない
    ///   (rightは常に直前のページと組むページであり、targetIndexより後ろのページとは組まない)。
    /// - 次のページ(targetIndex + 1)がcenter/left指定なら、そちらは単独表示、または
    ///   自分より後ろのページと組むべきページなので、targetIndexとは組まない。
    /// - どちらのページにもEPUBの明示指定が無い場合(CBZ等、EPUB以外のソースを含む)だけ、
    ///   従来通り横長画像なら単ページ扱いにするヒューリスティックを適用する。
    private func shouldPairWithNextPage(at targetIndex: Int, firstImage: CGImage) -> Bool {
        guard displayMode == .spread, targetIndex + 1 < book.pages.count else { return false }

        let currentPosition = book.pages[targetIndex].epubSpreadPosition
        let nextPosition = book.pages[targetIndex + 1].epubSpreadPosition

        if currentPosition == .center || currentPosition == .right { return false }
        if nextPosition == .center || nextPosition == .left { return false }

        if currentPosition != nil || nextPosition != nil { return true }

        return !isWideImage(firstImage)
    }

    /// 生のページインデックスを、そのページがEPUBのpage-spread-right指定を持つ場合に、
    /// 正しい組み合わせの起点(1つ前のページ)へ補正する。
    ///
    /// page-spread-rightは「このページは見開きの右側に配置する」という指定であり、常に
    /// その直前のページと組みになる(shouldPairWithNextPage参照)。そのため、このページを
    /// そのままcurrentIndex(=見開きの起点/1枚目)として扱ってしまうと、本来一緒に表示される
    /// はずの直前のページが表示されないまま、指定されたページだけが単独表示されてしまう。
    ///
    /// 通常のページ送り(advance)は、直前の見開き判定(shouldPairWithNextPage)に基づいて
    /// 表示枚数(1枚か2枚か)を決めてから次の目的地を計算するため、自然に正しい起点に
    /// 着地する。この補正が必要になるのは、それまでの経緯を無視してどこか任意のページへ
    /// 直接着地する経路(jump(toPageIndex:)、本を開いたときの再開位置、ページ境界での
    /// ループ折り返し)だけである。
    private static func normalizedAnchorIndex(_ rawIndex: Int, in book: MangaBook) -> Int {
        guard book.pages.indices.contains(rawIndex), rawIndex > 0 else { return rawIndex }
        guard book.pages[rawIndex].epubSpreadPosition == .right else { return rawIndex }
        return rawIndex - 1
    }
}
