import Foundation
import CoreGraphics
import SwiftData
import Combine

/// 見開き表示の1コマ分の表示内容(実画像 or 空白)。ViewerView.pageAreaが、EPUB Reading
/// Systems 3.3 6.1.4節の「page-spread-left/rightの指定は、相方が見つからない場合でも
/// 空白ページを挿入してでも尊重しなければならない(MUST)」という挙動を再現するために使う
/// (ViewerViewModel.currentSoleImageForcedSpreadPositionのコメント参照)。
enum SpreadPageSlot {
    case image(CGImage)
    case blank
}

/// ビューワー画面(ページ表示)の状態を管理する ViewModel。
/// ページ送り、見開き/単ページの切り替え、読み方向の切り替え、表示スケーリングモード、
/// ブックマーク、スライドショーを担当する。
/// 実際の画像読み込み・デコード・キャッシュ・先読みは PageLoader(actor)に委譲し、
/// ここでは「今どのページを表示すべきか」という状態管理と、SwiftUIへの反映に専念する。
/// 本ごとの読書状態(最後に読んだページ・表示モード・読み方向・表示スケーリング)はSwiftDataで永続化する。
@MainActor
final class ViewerViewModel: ObservableObject {
    /// @Publishedなのは、除外(非表示)・並べ替えの変更(reloadLayoutData参照)をViewerView/
    /// ProgressBarViewが直接読んでいるbook.pages/book.titleなどへ即座に反映するため。
    @Published private(set) var book: MangaBook
    /// この本を開いたときの、除外・並べ替え適用前の生のページ一覧(BookLoaderがそのまま返した
    /// 順序)。reloadLayoutDataが、DB由来の設定(pageOrderOverride・excluded)が変わるたびに、
    /// ここから都度book.pagesを再構築し直すために保持する(book.pages自体は既に絞り込まれた
    /// 後の配列のため、一度除外したページを後から復元する、といった操作の元データにはできない)。
    private let rawPages: [PageRef]

    @Published var currentIndex: Int
    @Published var displayMode: DisplayMode
    @Published var readingDirection: ReadingDirection
    @Published var scalingMode: ScalingMode
    @Published private(set) var currentImages: [CGImage] = []
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var isSlideshowActive = false
    /// カーソル位置を中心に画像の一部を拡大表示する「ルーペ」が現在表示中かどうか
    /// (toggleLoupe参照)。
    @Published private(set) var isLoupeActive = false
    /// 環境設定「本を再度開いたときの動作」が「問い合わせる」のとき、かつ前回位置が
    /// 先頭でない(=本当に「再開」の余地がある)ときにtrueになる。ViewerViewがこれを見て
    /// 「前回表示したページから再開しますか?」の確認ダイアログを表示する。
    @Published private(set) var needsResumeConfirmation: Bool

    /// ページ境界(最初/最後)を超えて隣の本へ移動する必要があるときに呼ばれる。
    /// (true = 次の本へ, false = 前の本へ)。ViewerView側が appState 経由で実装をセットする。
    var onRequestSiblingBook: ((Bool) -> Void)?

    /// この本にレイアウトデータ(BookLayoutSettings/PageLayoutOverride)が記録されていて、
    /// かつ差し替えの疑いがある(2.5節)ときだけ非nilになる。ViewerViewがこれを見て確認
    /// ダイアログを表示し、resolveLayoutReplacement(applyExisting:)で解決する。
    /// 解決されるまでの間、DB由来のレイアウトヒント(pageLayoutStates/bookLayoutSettings)は
    /// 意図的に空のまま扱う(誤った組み合わせで表示してしまうことを避ける安全策)。
    @Published private(set) var pendingLayoutReplacementStatus: LayoutContentReplacementStatus?

    private let modelContext: ModelContext
    private let readingState: BookReadingState
    private let pageLoader: PageLoader
    private let preferences: AppPreferences
    private let layoutStore: LayoutStore
    /// この本のBookLayoutSettings(本全体の読み方向上書き・見開き強制・ページ順補正)。
    /// 差し替えの疑いがあり未解決の間はnil(pendingLayoutReplacementStatus参照)。
    private var bookLayoutSettings: BookLayoutSettings?
    /// この本のPageLayoutOverride(ページ単位の設定)を、pageKey(PageRef.sortKey)をキーにした
    /// 辞書として保持する。差し替えの疑いがあり未解決の間は空のまま。
    private var pageLayoutStates: [String: PageLayoutState] = [:]
    /// 一度でも画像を読み込んで横長判定(isWideImage)を行ったページの結果を、pageKeyをキーに
    /// 覚えておくキャッシュ。
    ///
    /// 経緯(ユーザー報告): backwardStepSize/forwardStepSizeは同期的なAPIのため、EPUB/DB由来の
    /// 明示指定(layoutHint)が無いページの横長判定には本来画像の読み込みが必要で、それができない
    /// 場合は「今表示中の画像の枚数」を使った近似(fallback)にフォールバックしていた。しかし
    /// この近似は、直前の見開きの実際の構成(枚数)が今表示中の見開きと異なる場合(例:
    /// 1ページ目が横長で単独ページ、2ページ目以降が縦長で通常通りペアになる本)に誤った歩幅を
    /// 算出してしまい、「前のページへ戻る」操作で本来単独表示されるべきページが飛ばされて
    /// しまう不具合があった。
    ///
    /// このキャッシュは、shouldPairWithNextPage/loadCurrentSpread/wideImageAspectRatios(自動
    /// レイアウト計算)など、実際に画像(またはサムネイル)を読み込んで横長判定を行った箇所すべてで
    /// 埋める。一度でも表示・判定済みのページであれば、backwardStepSize/forwardStepSizeは
    /// 画像を読み込み直さずにこのキャッシュから正確な判定を再利用できる(cachedIsWideImage(at:)
    /// 参照)。未判定のページについては、従来通りの近似にフォールバックする。
    private var wideImageCache: [String: Bool] = [:]
    /// コンテキストメニュー「情報を見る」(ユーザー要望)向けの、ページごとの画像ファイル情報
    /// キャッシュ。pageKeyをキーにする(wideImageCacheと同じ考え方)。
    ///
    /// SwiftUIのコンテキストメニュー(NSMenu backed)は、開いている最中に内容を非同期に
    /// 更新する手段が無いため、メニューを開く時点で同期的に参照できる値が必要になる。
    /// そのため、実際に表示するページが決まるたび(loadCurrentSpread)にバックグラウンドで
    /// 取得してこのキャッシュへ格納しておき(cachePageImageInfo(at:)参照)、コンテキスト
    /// メニュー自身(ViewerView.contextMenuContent)はpageImageInfo(atIndex:)でこの
    /// キャッシュを読むだけにする。
    private var pageImageInfoCache: [String: PageImageInfo] = [:]
    /// 「ブックマーク・レイアウトの編集」ウインドウ(LayoutStore、この本を今開いていなくても
    /// 操作できる独立ウインドウ)側でこの本のレイアウト設定が変更されたときに、pageLayoutStates/
    /// bookLayoutSettingsを読み直すための監視トークン。bookmarksChangeObserverと同じ考え方
    /// (詳細はBookLayoutSettings.swiftのNotification.Name.layoutDataDidChangeのコメント参照)。
    /// ページの並び替え・除外(book.pagesの構造そのもの)も、reloadLayoutData内でrawPagesから
    /// 都度再構築することで、この本を開き直さずに反映する(詳細はreloadLayoutDataのコメント参照)。
    private var layoutDataChangeObserver: NSObjectProtocol?
    /// 「ブックマークの編集」ウインドウ(BookmarkStore、この本を今開いていなくても操作できる
    /// 独立ウインドウ)側でこの本のブックマークが変更されたときに、自分のbookmarks配列を
    /// 読み直すための監視トークン。詳細はBookmark.swiftのNotification.Name.bookmarksDidChange
    /// のコメント参照。
    private var bookmarksChangeObserver: NSObjectProtocol?
    /// 環境設定「横長画像のしきい値」(preferences.singlePageAspectRatioThreshold)が本を
    /// 開いたまま変更されたときに、wideImageCache(古いしきい値で判定した結果)を破棄するための
    /// 購読。破棄しないと、しきい値変更前に判定・キャッシュ済みのページについて、
    /// backwardStepSize/forwardStepSizeが古い判定結果を使い続けてしまう
    /// (wideImageCacheのコメント参照)。
    private var singlePageAspectRatioThresholdObserver: AnyCancellable?

    /// 非同期の読み込みが完了したとき、それが「一番新しいリクエストか」を判定するための世代番号。
    /// 素早くページ送りされたときに、古い読み込みが後から完了して表示を巻き戻すのを防ぐ。
    private var loadGeneration = 0
    /// loadCurrentSpreadが直前に実際に表示したページの範囲(見開きなら2ページ分、単ページなら
    /// 1ページ分)。shouldPairWithNextPageが、新しい組み合わせの相方としてこの範囲のページを
    /// 再び取り込んでしまう(=直前の見開きの一方を、無関係な別のページと組み直して再表示して
    /// しまう)ことを防ぐために参照する。
    ///
    /// 経緯(ユーザー報告): 「1ページだけ送る」操作などで見開きの組み合わせを手動でずらした
    /// 状態(例: ページ3・4が見開きとして表示されている状態。本来の横長画像ヒューリスティック
    /// だけなら2・3が組になるはずの本で、手動調整によりずれた状態)から「前のページへ戻る」を
    /// 行うと、backwardStepSizeは正しく1ページだけ戻る(ページ2)と判断するが、その着地点で
    /// 独立に再計算されるshouldPairWithNextPageは横長ヒューリスティックだけで判定するため、
    /// (ページ2もページ3も横長ではない場合)ページ2をページ3と新たに組み直してしまっていた。
    /// しかしページ3は直前まで(異なる相手である)ページ4と組んで表示されていたページであり、
    /// これを今回のペアの相方として再利用すると、直前の見開きの右側が別の見開きの左側として
    /// 二重に使われる(=本来単独表示されるべきページ2が、ページ3を巻き込んで見開きに
    /// なってしまう)という不整合が生じる。stepSize自体の計算(何ページ分移動するか)と、
    /// 着地点でのペア判定(そのページが次のページと組むか)が別々に(互いを知らずに)
    /// 計算されていたことが根本原因のため、着地点での判定側に「直前表示していたページを
    /// 再利用しない」という制約を追加することで、双方の計算がどのような経路で呼ばれても
    /// (advance/jump/ループ折り返し等を問わず)常に整合するようにした。
    private var lastDisplayedPageRange: Range<Int>?
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

    init(book incomingBook: MangaBook, modelContext: ModelContext, preferences: AppPreferences, layoutStore: LayoutStore) {
        self.modelContext = modelContext
        self.preferences = preferences
        self.layoutStore = layoutStore

        // レイアウト設定(ページ順補正・除外ページの除去。2.3節・2.2節)を、実際に読書フローで
        // 使うページ一覧に適用してからbookを確定する(設計コンセプト12節「アーキテクチャ上の
        // 変更点」参照)。差し替えの疑いがある場合(2.5節)は何も適用せず、生のページ一覧のまま
        // pendingLayoutReplacementStatusを立てる(確認ダイアログで解決されるまで安全側に倒す)。
        let prepared = Self.prepareBook(from: incomingBook, layoutStore: layoutStore)
        // book(@Published)は、他のストアドプロパティ(全体)が出揃うまでself経由で読み出せない
        // (@Publishedはラッパー経由の算出プロパティのため、Swiftの2段階初期化規則上「selfを
        // 使う」扱いになる。以前bookが単純なletストアドプロパティだった頃はこの制約が無く、
        // 下記の各所でbookを直接読んでいたが、@Publishedへの変更に伴いコンパイルエラーになった)。
        // そのため、初期化がすべて完了するまで(下のself.currentIndex = initialIndexの代入まで)は
        // このpreparedBookローカル変数を代わりに使う。
        let preparedBook = prepared.book
        self.book = preparedBook
        // reloadLayoutDataでの再構築の元データとして、除外・並べ替え適用前の生のページ一覧を
        // 保持しておく(rawPagesのコメント参照)。
        self.rawPages = incomingBook.pages
        self.bookLayoutSettings = prepared.settings
        self.pageLayoutStates = prepared.overrides
        if case .possiblyReplaced = prepared.replacementStatus {
            self.pendingLayoutReplacementStatus = prepared.replacementStatus
        } else {
            self.pendingLayoutReplacementStatus = nil
        }
        // 権威的なレイアウト指定(の有無)を、本を開くたびにキャッシュし直しておく
        // (「ブックマーク・レイアウトの編集」ウインドウが、本を読み込み直さずに判定できるように
        // するため。詳細はBookLayoutSettings.hasEpubLayoutLockのコメント参照)。
        layoutStore.recordEpubLayoutLock(
            for: prepared.book,
            hasLock: prepared.book.sourceLayoutHint?.forcedDisplayMode != nil
                || prepared.book.sourceLayoutHint?.pageProgressionDirection != nil
        )

        self.pageLoader = PageLoader(book: preparedBook)

        let bookID = preparedBook.id

        // bookID(パス)が同じでも、そのファイル/フォルダの中身が実際には別のものに
        // 差し替わっていることがある(同じ名前で別の本をダウンロードし直した、フォルダの
        // 中身を丸ごと入れ替えた等)。完全な内容比較(ハッシュ値計算など)はコストが高いため、
        // 代わりに(1)ページ数 (2)元のファイル/フォルダの更新日時 (3)ファイルサイズ
        // (フォルダの場合は取得できないため常にnil)を軽量な「指紋」として使い、前回保存した
        // 値と1つでも異なれば「差し替えられた別の内容」とみなす。
        // 指紋の計算・比較ロジック自体はContentFingerprintへ切り出してある(BookLayoutSettingsも
        // 同じ仕組みを使うため。詳細はContentFingerprint.swift参照)。
        let currentFingerprint = ContentFingerprint.current(for: preparedBook)

        // #Predicate<BookReadingState> { $0.bookID == bookID }による絞り込みフェッチが、
        // レイアウト変更直後などに0件を誤って返すことがある不具合が実機で確認された
        // (LayoutStore.pageOverrides(forBookID:)のコメント参照。キャプチャしたローカル変数名が
        // モデル側プロパティ名と同名であることが関係している可能性が高い)。同じ問題を避けるため、
        // 絞り込み無しで全件取得してからSwift側でfilterする。
        let allReadingStates = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        let fetchedState = allReadingStates.first { $0.bookID == bookID }
        // recordedPageCountがnilなのは、この指紋の仕組みを導入する前に保存された古いデータ
        // (まだ比較のしようがない)ということなので、その場合は「差し替えなし」として扱う
        // (ContentFingerprint.looksReplaced内で判定)。
        let recordedFingerprint = fetchedState.map {
            ContentFingerprint.Recorded(
                pageCount: $0.recordedPageCount,
                modificationDate: $0.recordedSourceModificationDate,
                fileSize: $0.recordedSourceFileSize
            )
        }
        let contentLooksReplaced = ContentFingerprint.looksReplaced(
            recorded: recordedFingerprint, current: currentFingerprint
        )
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
            // readingDirectionは、BookReadingState.initのデフォルト引数(右開き固定)に頼らず、
            // 環境設定の既定読み方向(初回起動時にシステム言語から一度だけ決定したもの。
            // 設計コンセプト11.1節、AppPreferences.defaultReadingDirection参照)を明示的に渡す。
            state = BookReadingState(
                bookID: bookID,
                readingDirection: preferences.defaultReadingDirection,
                scalingMode: preferences.defaultScalingMode
            )
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
        state.recordedPageCount = currentFingerprint.pageCount
        state.recordedSourceModificationDate = currentFingerprint.modificationDate
        state.recordedSourceFileSize = currentFingerprint.fileSize
        self.readingState = state

        // 環境設定「本を再度開いたときの動作」に応じて、実際にどのページから表示するかを決める。
        // (以前から読んでいる本(isReturningToKnownBookがtrueの場合)にのみ意味がある判定で、
        // 初めて開く本・中身が差し替わった本は常にlastPageIndexが0のため、どの設定でも結果は変わらない)
        let restoredIndex = min(max(state.lastPageIndex, 0), max(preparedBook.pages.count - 1, 0))
        let wasOnLastPage = preparedBook.pages.count > 0 && restoredIndex >= preparedBook.pages.count - 1
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

        // EPUBがpage-progression-direction/rendition:spreadを明示している場合、またはPDFが
        // Document Catalogの/ViewerPreferences/Direction・/PageLayoutで同等の情報を明示している
        // 場合、保存されていた設定より優先してその値を採用する(値が無い項目は、これまで通り
        // SwiftDataの保存値に従う)。対応する切り替え操作(toggleReadingDirection/
        // toggleDisplayMode)自体も、この値が強制されている間は無効化する
        // (isReadingDirectionLocked/isDisplayModeLocked参照)。
        //
        // それ以外の形式(フォルダ・cbz/cbr/cb7、および上記ヒントを持たないPDF)でも、
        // BookLayoutSettingsに読み方向/見開き強制の上書きが記録されていれば(4.1節の編集
        // ウインドウで設定する)、ソース側のヒントに次ぐ優先順位でそれを採用する
        // (優先順位: ソースファイル自身のヒント > DB > SwiftDataの保存値。設計コンセプト2.4節)。
        self.displayMode = preparedBook.sourceLayoutHint?.forcedDisplayMode ?? bookLayoutSettings?.forcedDisplayMode ?? state.displayMode
        self.readingDirection = preparedBook.sourceLayoutHint?.pageProgressionDirection
            ?? bookLayoutSettings?.readingDirectionOverride
            ?? state.readingDirection
        self.scalingMode = state.scalingMode
        self.needsResumeConfirmation = needsConfirmation
        // Swiftの初期化規則上、self(のインスタンスメソッド)は全ストアドプロパティに値が
        // 入るまで呼べない。currentIndex自体もその1つのため、まず素の値を代入して初期化を
        // 完了させる(このself.currentIndex = initialIndexの代入をもって、以後selfを
        // 自由に使える状態になる)。
        self.currentIndex = initialIndex

        // 保存されていた(または直前に計算した)ページ位置が、EPUBのpage-spread-right指定
        // (またはDB由来の「見開き右」指定)を持つページをそのまま指していると、そのページ単体が
        // 見開きの起点であるかのように扱われてしまい、本来組になるはずの1つ前のページが
        // 表示されない状態になる。jump(toPageIndex:)と同じ補正をここでも適用しておく
        // (詳細はnormalizedAnchorIndex参照。プロパティが出揃った後でしか呼べないインスタンス
        // メソッドのため、上のcurrentIndexへの代入が完了した後のこの位置で呼ぶ)。
        currentIndex = normalizedAnchorIndex(initialIndex)

        Task { [weak self] in
            await self?.loadCurrentSpread()
        }
        // 本を開いた直後から、本全体についてバックグラウンドで横長判定を進めておく
        // (warmUpWideImageCacheForEntireBookのコメント参照。ユーザー報告: スクロールホイールを
        // 高速に連続して回すと、primeWideImageCache(around:radius:)によるcurrentIndex付近だけの
        // 先読みでは判定が追いつかず、まだ未判定の遠いページまで一気に進んでしまうことがある)。
        warmUpWideImageCacheForEntireBook()
        reloadBookmarks()

        // 設計コンセプト7.5節「逆方向」: EPUBの目次(nav.xhtml)、またはPDFのアウトライン(しおり)が
        // あり、この本にまだブックマークが1件も無い場合は自動的にブックマークとして取り込む。
        // どちらの経路を試すかはファイル形式(拡張子)そのもので判定する(sourceLayoutHintの
        // 有無では判定しない。PDFはレイアウトヒントを持たない本の方が多く、その場合でも
        // アウトラインだけは持っていることがあるため)。読み込み・解析はTask内で非同期に行い、
        // 本を開く処理自体をブロックしない。
        if bookmarks.isEmpty {
            let sourceFileName = book.sourceURL.lastPathComponent
            if isEpubFile(sourceFileName) {
                Task { [weak self] in
                    await self?.autoImportEpubTableOfContentsAsBookmarksIfNeeded()
                }
            } else if isPDFFile(sourceFileName) {
                Task { [weak self] in
                    await self?.autoImportPDFOutlineAsBookmarksIfNeeded()
                }
            }
        }

        // 「ブックマークの編集」ウインドウは本のウインドウとは独立しているため、そちらで
        // この本のブックマークが削除・リネームされても、このViewerViewModelは何もしなければ
        // 気づけない。bookIDが一致する変更だけを拾って読み直す(BookmarkStoreのコメント参照)。
        // userInfoに"bookID"が無い通知(BookmarkStore.deleteAllBookmarks()による全件リセット。
        // 環境設定「リセット」タブ参照)は、本を問わず常に読み直す対象として扱う。
        let ownBookID = bookID
        bookmarksChangeObserver = NotificationCenter.default.addObserver(
            forName: .bookmarksDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            // queue: .mainを指定しているため実行時には必ずMainActor(メインスレッド)上で
            // 呼ばれるが、NotificationCenterのクロージャ自体の型はMainActorに分離されて
            // いないため、コンパイラは静的にそれを保証できない。Task { @MainActor in ... }で
            // 包み直すと、今度はSwift 6の厳格な並行性チェックで「非同期に実行されるコードで
            // selfをキャプチャしている」という別の警告/エラーになる(FavoritesStore.swiftの
            // 同種のコメント参照)ため、代わりにMainActor.assumeIsolatedで「実行時には
            // 既にMainActor上にいる」ことを伝える(queue: .mainにより保証されている前提の
            // 表明であり、Task化のような余分な非同期ホップも発生させない)。
            MainActor.assumeIsolated {
                let changedBookID = notification.userInfo?["bookID"] as? String
                guard changedBookID == nil || changedBookID == ownBookID else { return }
                self?.reloadBookmarks()
            }
        }

        // 「ブックマーク・レイアウトの編集」ウインドウ側でこの本のレイアウト設定が変更されても
        // 気づけないため、bookmarksChangeObserverと同じ考え方でbookIDが一致する変更だけを拾う。
        // ページの並び替え・除外を含め、reloadLayoutDataがその場でbook.pagesへ反映する
        // (詳細はreloadLayoutDataのコメント参照)。userInfoに"focusPageKey"が含まれていれば
        // (postLayoutFocusChange/BookLayoutEditorViewModelから、ユーザーが直接操作したページとして
        // 明示的に付与されたもの)、更新後の表示にそのページを含めるようreloadLayoutDataへ
        // そのまま渡す(ユーザー要望)。
        layoutDataChangeObserver = NotificationCenter.default.addObserver(
            forName: .layoutDataDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            // 上のbookmarksChangeObserverと同じ理由でMainActor.assumeIsolatedを使う。
            MainActor.assumeIsolated {
                let changedBookID = notification.userInfo?["bookID"] as? String
                guard changedBookID == nil || changedBookID == ownBookID else { return }
                let focusPageKey = notification.userInfo?["focusPageKey"] as? String
                self?.reloadLayoutData(focusPageKey: focusPageKey)
            }
        }

        // 環境設定ウインドウは本のウインドウとは独立して開けるため、この本を表示したまま
        // しきい値を変更されることがある。dropFirst()で初期値の即時発火は無視し、
        // 実際に値が変わったときだけwideImageCacheを破棄する(singlePageAspectRatioThreshold
        // Observerのコメント参照)。
        singlePageAspectRatioThresholdObserver = preferences.$singlePageAspectRatioThreshold
            .dropFirst()
            .sink { [weak self] _ in
                self?.wideImageCache.removeAll()
            }
    }

    deinit {
        if let bookmarksChangeObserver {
            NotificationCenter.default.removeObserver(bookmarksChangeObserver)
        }
        if let layoutDataChangeObserver {
            NotificationCenter.default.removeObserver(layoutDataChangeObserver)
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
    /// 前進のステップ数はforwardStepSize(from:fallback:)参照(EPUB/DB由来の明示指定が
    /// baseIndexにあればそれを優先し、無ければ「今表示している画像の枚数」に近似する。
    /// 横長画像で単ページ表示になっている場合は1枚分だけ進むようにするため。見開き設定でも
    /// 常に2ページ分ずれるわけではない)。後退のステップ数はbackwardStepSize(from:fallback:)
    /// 参照(「今表示している画像の枚数」をそのまま歩幅に使うと、baseIndexが待ち行列中の
    /// 未表示の目的地を指している場合や、直前の見開きの実際の枚数と食い違う場合に不具合が
    /// 起きるため、別ロジックにしている)。
    func advance(forward: Bool) {
        // まだ表示できていない待ち行列中の目的地があれば、そこを起点に次の目的地を計算する
        // (currentIndexは、待ち行列の処理がまだ追いついていない古い値のことがあるため)。
        let baseIndex = pageFlipQueue.last ?? currentIndex
        // 「今表示している画像の枚数」(currentImages.count)は、待ち行列が空でない間は
        // baseIndex(=次に着地する予定の、まだ表示できていない目的地)ではなく、現在画面に
        // 出ている別のページ(処理待ちのアニメーション途中のコマ、または古いページ)の枚数を
        // 指してしまっている。スクロールホイールで素早く連続してページ送りすると、この
        // ズレたforwardStepでbaseIndexへ加算してしまい、EPUB/DBのpage-spread-left/right
        // 指定を持つページの組の片方(特に「見開き右」ページ)だけへ直接着地することがあった
        // (本来は必ずその直前のページとセットで着地しなければならない)。結果、着地後に
        // currentSoleImageForcedSpreadPosition(EPUB仕様6.1.4節)が働き、実際には組になる
        // ページが存在するにもかかわらず、片割れを空白ページとして描画してしまっていた
        // (ユーザー報告: epubやレイアウト情報がある本で、スクロールホイールを高速で回して
        // ページ送りし、止まった際に見開きの半分が空白ページになる)。
        // forwardStepSize(from:fallback:)はbackwardStepSize(from:fallback:)と同じ考え方で、
        // baseIndex自身にEPUB/DB由来の明示指定があるときはそれを同期的に使って正しい歩幅を
        // 決め、明示指定が無い(横長画像ヒューリスティックの判定に画像読み込みが必要な)場合
        // だけ、従来通りcurrentImages.countへフォールバックする。
        let forwardStep = forwardStepSize(from: baseIndex, fallback: max(currentImages.count, 1))
        if forward {
            if baseIndex + forwardStep < book.pages.count {
                enqueuePageFlip(to: baseIndex + forwardStep)
            } else if pageFlipQueue.isEmpty {
                // アニメーションで通過中(待ち行列に処理待ちが残っている)にページ境界へ
                // 達した場合、次の本への移動などの境界処理は待ち行列が空になってから、
                // あらためてこの関数が呼ばれたときに行う(ここでは何もしない)。
                handleForwardBoundary()
            }
        } else {
            let step = backwardStepSize(from: baseIndex, fallback: forwardStep)
            if baseIndex - step >= 0 {
                enqueuePageFlip(to: baseIndex - step)
            } else if baseIndex != 0 {
                enqueuePageFlip(to: 0)
            } else if pageFlipQueue.isEmpty {
                handleBackwardBoundary()
            }
        }
    }

    /// advance(forward: false)(前のページへ戻る)のステップ数を決める。
    ///
    /// 経緯(ユーザー報告): 「今表示している画像の枚数」をそのまま戻り幅に使っていたところ、
    /// レイアウト自動計算(3.1節)などでパリティがずれ、見開きの並びの途中に単独ページが
    /// 1枚だけ挟まっているケース(例: …見開きA/B, 単独C, 見開きD/E…)で、見開きD/Eの表示中に
    /// 「前のページへ戻る」と、今表示中の枚数(2枚)をそのまま戻り幅に使ってしまうため、
    /// 単独ページCを飛び越えて見開きB(実際にはAとのペアの後半)へ直接着地してしまっていた
    /// (Cが未表示のまま、Bが「見開きの片方だけ表示され反対側は空白」という誤った見た目に
    /// なる不具合も併発していた)。
    ///
    /// 正しい戻り幅は、今表示中の枚数ではなく、baseIndexの直前にある見開きが実際に何枚で
    /// 構成されているか(baseIndex-2とbaseIndex-1がshouldPairWithNextPageと同じ基準で
    /// ペアと判定されるか)によって決まる。shouldPairWithNextPage自体は横長画像ヒューリス
    /// ティックのフォールバックのために画像の読み込み(非同期)を必要とするが、advance自体は
    /// 同期的なAPIのため画像を読み込めない。ただし、layoutHint(at:)(EPUB/DB由来の明示指定)
    /// だけで判定がつく場合は画像を読み込む必要が無い(shouldPairWithNextPageのコメント
    /// 参照: currentPosition/nextPositionのどちらかでも非nilなら、横長ヒューリスティックの
    /// フォールバックまで行かずに結論が出る)。そのため、明示指定だけで判定できる範囲はここで
    /// 同期的に正しく計算し、判定できない(どちらの位置にも明示指定が無く、横長ヒューリス
    /// ティックの結果を画像無しに知りようが無い)場合だけ、従来通りの近似(fallback。今表示中の
    /// 枚数)にフォールバックする。
    private func backwardStepSize(from index: Int, fallback: Int) -> Int {
        guard displayMode == .spread else { return fallback }
        guard index - 1 >= 0 else { return fallback }
        guard index - 2 >= 0 else { return 1 }

        let earlierPosition = layoutHint(at: index - 2)
        let laterPosition = layoutHint(at: index - 1)
        let isRTL = readingDirection == .rightToLeft
        let disallowedForEarlier: PageSpreadPosition = isRTL ? .left : .right
        let disallowedForLater: PageSpreadPosition = isRTL ? .right : .left

        if earlierPosition == .center || earlierPosition == disallowedForEarlier { return 1 }
        if laterPosition == .center || laterPosition == disallowedForLater { return 1 }
        if earlierPosition != nil || laterPosition != nil { return 2 }

        // どちらの位置にも明示指定が無い場合、本来は横長ヒューリスティックの判定に画像の
        // 読み込みが必要で、この同期的なAPIでは判定できない。ただし、index - 2のページを
        // 過去に一度でも表示していれば、その判定結果がwideImageCacheに残っているため、
        // 画像を読み込み直さずに正確な判定ができる(shouldPairWithNextPageと同じ基準:
        // index - 2自身が横長なら単独ページとして確定するのでindex - 1と組めず、戻り幅は1。
        // 横長でなければindex - 2とindex - 1が組になっていたはずなので、戻り幅は2)。
        //
        // 経緯(ユーザー報告): 1ページ目が横長画像で単独ページ、2ページ目以降は縦長画像で
        // 通常通り2ページずつ組になる本で、見開き表示中に「前のページへ戻る」を実行すると、
        // 本来は間にある単独ページ(1ページ目)を経由して2ページ目が単独表示されるべきところ、
        // このキャッシュが無い頃は「今表示中の枚数(2枚)」をそのまま戻り幅として使う近似に
        // 頼っており、1ページ目・2ページ目をまとめて飛び越えてしまっていた。
        if let earlierIsWide = cachedIsWideImage(at: index - 2) {
            return earlierIsWide ? 1 : 2
        }

        // キャッシュにも判定結果が無い(index - 2のページを一度も表示していない)場合だけ、
        // 従来通りの近似(fallback)にフォールバックする。
        return fallback
    }

    /// advance(forward: true)(次のページへ進む)のステップ数を決める。backwardStepSizeの
    /// 前進版(コメント参照)。
    ///
    /// 経緯(ユーザー報告): 以前はadvance(forward:)が常にforwardStep = currentImages.count
    /// (今表示している画像の枚数)をそのままbaseIndexへの加算幅に使っていた。baseIndexは
    /// 「待ち行列中の目的地(まだ表示できていない、これから着地する予定の位置)」なのに対し、
    /// currentImages.countは「現在画面に実際に出ているページ(待ち行列の処理がまだ追いついて
    /// いない、別の位置のことがある)」の枚数であり、スクロールホイールなどで素早く連続して
    /// advanceが呼ばれる(画像の読み込みが追いつく前に次のadvanceが呼ばれる)と、この2つが
    /// 指す位置がずれる。ずれたforwardStepでbaseIndexに加算すると、EPUB/DB由来の
    /// page-spread-left/right指定を持つページの組の片方(特に「見開き右」側)へ、相方の
    /// ページを経由せずに直接着地してしまうことがあり、着地後にcurrentSoleImageForced-
    /// SpreadPositionが働いて本来組になるはずのページを空白扱いにしてしまっていた
    /// (epubやレイアウト情報がある本で、スクロールホイールを高速で回してページ送りし、
    /// 止まった際に見開きの半分が空白ページになる)。
    ///
    /// backwardStepSizeと同じく、baseIndex自身とその次のページ(baseIndex+1)がEPUB/DB由来の
    /// 明示指定だけで判定できる範囲はここで同期的に正しく計算し(shouldPairWithNextPageと
    /// 同じ基準)、判定できない(どちらにも明示指定が無く、横長ヒューリスティックの結果を
    /// 画像無しに知りようが無い)場合だけ、従来通りの近似(fallback)にフォールバックする。
    private func forwardStepSize(from index: Int, fallback: Int) -> Int {
        guard displayMode == .spread else { return fallback }
        guard index >= 0, index + 1 < book.pages.count else { return fallback }

        let currentPosition = layoutHint(at: index)
        let nextPosition = layoutHint(at: index + 1)
        let isRTL = readingDirection == .rightToLeft
        let disallowedForCurrent: PageSpreadPosition = isRTL ? .left : .right
        let disallowedForNext: PageSpreadPosition = isRTL ? .right : .left

        if currentPosition == .center || currentPosition == disallowedForCurrent { return 1 }
        if nextPosition == .center || nextPosition == disallowedForNext { return 1 }
        if currentPosition != nil || nextPosition != nil { return 2 }

        // indexが現在実際に表示中のページ(currentIndex)と一致する場合、fallback
        // (max(currentImages.count, 1)、advance参照)は「今まさに画面に出ている、実際の
        // 表示状態」をそのまま表しているため、wideImageCacheによる横長判定だけの予測より
        // 優先して信頼できる。
        //
        // 経緯(ユーザー報告): shouldPairWithNextPageには、直前に表示していたページを新しい
        // ペアの相方として再利用しない制約(previousDisplayedRange、lastDisplayedPageRangeの
        // コメント参照)を追加した。この制約により、横長画像でなくても「直前の見開きの相方
        // だった」という理由で単ページ化されることがあるが、wideImageCache単体の判定
        // (indexのページ自身が横長かどうか)はこの制約を知らないため、実際には単ページ化
        // されているページを「横長ではないから次と組むはず」と誤って予測し、本来1ページだけ
        // 進むべきところを2ページ分進めて次のページを飛び越えてしまっていた。fallbackは
        // その制約も含めて実際にレンダリングされた結果(currentImages.count)をそのまま使うため、
        // この問題が起きない。
        if index == currentIndex {
            return fallback
        }

        // indexが現在表示中のページと一致しない(スクロールホイールなどで素早く連続して
        // advanceが呼ばれ、待ち行列に複数の目的地が積まれている)場合は、fallbackの元になる
        // currentImages.countが「今画面に実際に出ている(baseIndexとは別の、処理待ちの)ページ」
        // の枚数を指してしまうため信頼できない(advance内のforwardStepのコメント参照)。
        // この場合に限り、wideImageCacheを参照する(indexのページを過去に一度でも表示して
        // いれば、shouldPairWithNextPageと同じ基準(indexのページ自身が横長かどうか)で、
        // fallbackよりはましな判定ができる。前述のpreviousDisplayedRangeによる制約までは
        // 反映できないため完全ではないが、素の近似よりは精度が高い)。
        if let currentIsWide = cachedIsWideImage(at: index) {
            return currentIsWide ? 1 : 2
        }

        // キャッシュにも判定結果が無い場合だけ、従来通りの近似(fallback)にフォールバックする。
        return fallback
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
            // loadCurrentSpreadと同じ理由でwideImageCacheへ記録しておく(コメント参照)。
            _ = isWideImage(width: secondImage.width, height: secondImage.height, pageIndex: index + 1)
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
    ///
    /// 経緯(ユーザー報告): 例えばページ3・4を見開き表示中に「1枚だけ前の画像へ」を使うと、
    /// ページ2・3の見開きに切り替わることが期待されるが、実際にはページ2が単独ページとして
    /// 表示されていた。原因はloadCurrentSpread/shouldPairWithNextPageが持つ
    /// 「直前に表示していたページ(lastDisplayedPageRange)を新しい組み合わせの相方として
    /// 再利用しない」という制約(そのコメント参照)。この制約自体は、advance(forward:)で
    /// 見開き丸ごと分の「前のページへ戻る」を行った際に、手動でずらした組み合わせの片方
    /// (直前まで別のページと組んでいたページ)を誤って巻き込まないようにするためのものだが、
    /// shiftByOnePageはその制約が想定する操作(advance)ではなく、まさに「組み合わせを1ページ分
    /// 意図的にずらす」ための操作自体であるため、この制約を適用すると新しく組みたいはずの
    /// 相方まで拒否してしまっていた。shiftByOnePage自身の再読み込みに限り、この制約を無視する
    /// ことで、常に新しい組み合わせを素直に(横長判定/レイアウト指定に基づいて)再計算する
    /// ようにする(この呼び出しの結果でlastDisplayedPageRangeは新しい実際の表示範囲に更新される
    /// ため、その後のadvance()では引き続き正しく保護がかかる)。
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
        reloadAsync(ignorePreviousDisplayedRange: true)
    }

    /// プログレスバーをクリック/ドラッグした位置のページへ直接ジャンプする。
    /// 着地先はnormalizedAnchorIndexで補正するため、EPUBがpage-spread-rightを指定している
    /// ページを直接指定しても、実際にはその1つ前(組になるページ)へ着地し、正しい組み合わせで
    /// 表示される。
    func jump(toPageIndex index: Int) {
        guard !book.pages.isEmpty else { return }
        cancelPendingPageFlip()
        let clamped = max(0, min(index, book.pages.count - 1))
        let normalized = normalizedAnchorIndex(clamped)
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

    /// EPUBがrendition:spreadで、またはPDFがDocument Catalogの/PageLayoutで本全体の見開き/
    /// 単ページを強制している間、またはBookLayoutSettingsで本全体の見開き/単ページ強制が
    /// 設定されている間はtrue。trueの間はtoggleDisplayMode()自体が何もしない(呼び出し元のUIも
    /// 合わせてグレーアウトする。ViewerView/QooViewerAppの`.disabled()`参照)。
    ///
    /// ソースファイル自身(EPUB/PDF)由来・DB由来のどちらも「著者(またはそれに代わって
    /// ユーザーが明示した)権威的なレイアウト指定」という同じ役割を担うため、同じロック扱いに
    /// している(優先順位自体はソースファイル自身 > DBだが、ロックするかどうかという意味では
    /// 両者は対等。設計コンセプト2.4節・12節参照)。
    var isDisplayModeLocked: Bool {
        book.sourceLayoutHint?.forcedDisplayMode != nil || bookLayoutSettings?.forcedDisplayMode != nil
    }

    /// EPUBがpage-progression-directionで、またはPDFがDocument Catalogの
    /// /ViewerPreferences/Directionで読み方向を明示している間、またはBookLayoutSettingsで
    /// 読み方向が上書きされている間はtrue。trueの間はtoggleReadingDirection()自体が何もしない。
    var isReadingDirectionLocked: Bool {
        book.sourceLayoutHint?.pageProgressionDirection != nil || bookLayoutSettings?.readingDirectionOverride != nil
    }

    /// 現在表示中の見開きに、EPUBのpage-spread-left/right/rendition:page-spread-center指定
    /// (またはDB由来の同等の設定。3.2節で明示的に設定したもの)を持つページが含まれている間はtrue。
    /// この状態で「1ページだけ送る」調整を行うと、明示的に指定したページの組み合わせが
    /// 崩れてしまうため、shiftByOnePage()自体が何もしない。
    var isPageShiftLocked: Bool {
        guard displayMode == .spread, book.pages.indices.contains(currentIndex) else { return false }
        if layoutHint(at: currentIndex) != nil { return true }
        let partnerIndex = currentIndex + 1
        guard currentImages.count > 1, book.pages.indices.contains(partnerIndex) else { return false }
        return layoutHint(at: partnerIndex) != nil
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

    /// ページ一覧(グリッド)のセルにカーソルをホバーしたときの拡大プレビュー用
    /// (ユーザー要望。ThumbnailGridView参照)。loadThumbnail(at:)は軽量版(進捗バー用の
    /// 低解像度)で、そのまま拡大表示すると粗くなるため、こちらはビューアと同じ解像度
    /// (ImageDecoder.pageMaxPixelSize)の画像を返す。BookLayoutEditorViewModel.pageImage
    /// (rawIndex:)と同じ考え方(ホバーしたときだけ呼ばれる想定で、常時読み込むと重くなるため)。
    func pageImage(at index: Int) async -> CGImage? {
        guard book.pages.indices.contains(index) else { return nil }
        return await pageLoader.pageImage(at: index)
    }

    // MARK: - 画像のエクスポート(要望)

    /// このページの生データ(デコード前、画質を落とさない)。「このページをエクスポート」で、
    /// 元のファイルをそのまま複製するために使う(ViewerView.exportImage参照)。
    func rawImageData(at index: Int) async -> Data? {
        guard book.pages.indices.contains(index) else { return nil }
        return await pageLoader.rawImageData(at: index)
    }

    /// 「見開きを結合してエクスポート」で、2枚の画像を合成するために使う、ダウンサンプリング
    /// しないフルサイズの画像。
    func fullResolutionImage(at index: Int) async -> CGImage? {
        guard book.pages.indices.contains(index) else { return nil }
        return await pageLoader.fullResolutionImage(at: index)
    }

    // MARK: - ブックマーク

    private func reloadBookmarks() {
        let bookID = book.id
        // #Predicateでの絞り込み(旧実装)が、レイアウト変更直後などに0件を誤って返すことがある
        // 不具合が実機で確認された(LayoutStore.pageOverrides(forBookID:)のコメント参照)ため、
        // 絞り込み無しで全件取得してからSwift側でfilter・sortする。
        let all = (try? modelContext.fetch(FetchDescriptor<Bookmark>())) ?? []
        bookmarks = all.filter { $0.bookID == bookID }.sorted { $0.pageIndex < $1.pageIndex }
    }

    /// EPUBの目次(nav.xhtml)から、ブックマークを自動的に取り込む(設計コンセプト7.5節「逆方向」)。
    /// この本にまだブックマークが1件も無い場合に限り行う。目次が無い/解析できない/リンク先が
    /// どのページにも一致しない場合は何もしない。EPUB2形式のtoc.ncxへのフォールバックは
    /// 未対応(EpubStructureResolver.resolveTableOfContentsのコメント参照)。
    ///
    /// EPUBのzipコンテナを(BookLoader.loadEpubとは別に)もう一度読み直す必要がある
    /// (MangaBook自体は目次データを保持していないため。本を開くたびに毎回この処理を行うのは
    /// 無駄になるが、実際にファイルへ書き込む(ブックマークを追加する)のは最初の1回だけで、
    /// 2回目以降はbookmarks.isEmptyがfalseになるため、そもそもこのメソッド自体が呼ばれない)。
    private func autoImportEpubTableOfContentsAsBookmarksIfNeeded() async {
        guard bookmarks.isEmpty else { return }
        let sourceURL = book.sourceURL
        let entries: [EpubTOCEntry] = await Task.detached(priority: .utility) { () -> [EpubTOCEntry] in
            guard let reader = try? ZipArchiveReader(url: sourceURL),
                  let structure = try? EpubStructureResolver.resolve(reader: reader)
            else { return [] }
            return EpubStructureResolver.resolveTableOfContents(reader: reader, structure: structure)
        }.value
        importAutoTOCEntries(entries.map { (title: $0.title, pageIndex: $0.pageIndex) })
    }

    /// PDFのアウトライン(しおり)から、ブックマークを自動的に取り込む。autoImportEpub
    /// TableOfContentsAsBookmarksIfNeededのPDF版で、役割・タイミングの制約(ブックマークが
    /// 1件も無い場合に限る等)はすべて同じ(詳細はそちらのコメント参照)。
    ///
    /// PDFもEPUBと同じく(BookLoader.loadPDFとは別に)PDFKitでもう一度読み直す必要がある
    /// (MangaBook自体はアウトラインデータを保持していないため。BookLoader側はページ描画に
    /// 使うCGPDFDocumentしか開いておらず、アウトラインの読み取りにはPDFKitを使うため
    /// (PDFStructureResolver.resolveOutline参照)、どのみち専用の読み込みが必要になる)。
    private func autoImportPDFOutlineAsBookmarksIfNeeded() async {
        guard bookmarks.isEmpty else { return }
        let sourceURL = book.sourceURL
        let entries = await Task.detached(priority: .utility) { () -> [PDFOutlineEntry] in
            PDFStructureResolver.resolveOutline(url: sourceURL)
        }.value
        importAutoTOCEntries(entries.map { (title: $0.title, pageIndex: $0.pageIndex) })
    }

    /// EPUBの目次/PDFのアウトラインから取り込んだ項目を、実際にブックマークとしてSwiftDataへ
    /// 挿入する共通処理。呼び出し元(autoImportEpubTableOfContentsAsBookmarksIfNeeded/
    /// autoImportPDFOutlineAsBookmarksIfNeeded)がTask.detachedでの読み込みを待っている間に、
    /// ユーザーが手動でブックマークを追加した可能性もゼロではないため、書き込み直前に
    /// もう一度bookmarks.isEmptyを確認する。
    private func importAutoTOCEntries(_ entries: [(title: String, pageIndex: Int)]) {
        guard !entries.isEmpty, bookmarks.isEmpty else { return }

        let bookID = book.id
        let fileNodeIdentifier = FileNodeIdentifier.current(for: book.sourceURL)
        for entry in entries {
            guard book.pages.indices.contains(entry.pageIndex) else { continue }
            guard !bookmarks.contains(where: { $0.pageIndex == entry.pageIndex }) else { continue }
            // isEpubDerived: true — 「ブックマーク・レイアウトの編集」ウインドウには表示しない
            // (BookmarkStore.reload()/bookmarks(forBookID:)側のフィルタ、Bookmark.swiftの
            // isEpubDerivedのコメント参照。名前はEPUB由来だが、PDFのアウトラインから自動的に
            // 取り込んだブックマークにも同じ扱いとしてtrueを立てる)。
            modelContext.insert(
                Bookmark(
                    bookID: bookID, pageIndex: entry.pageIndex, name: entry.title, isEpubDerived: true,
                    fileNodeIdentifier: fileNodeIdentifier
                )
            )
        }
        try? modelContext.save()
        reloadBookmarks()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: ["bookID": bookID])
    }

    /// 現在の起点ページ(currentIndex)にブックマークを追加する。以前はこのメソッドが
    /// 唯一のブックマーク追加経路で、見開き表示中でも常にcurrentIndex側だけを対象にしていたが、
    /// ユーザー報告(見開き表示でのブックマーク追加対象を左右で正しく指定できるようにしてほしい)
    /// を受けて、対象ページを明示的に指定できるaddBookmark(atIndex:)を新設した。こちらは
    /// その薄いラッパーとして残している(呼び出し元を洗い出したところ、見開きの相方ページを
    /// 意図的に対象にする経路は無く、すべてcurrentIndexを渡していたことを確認済み)。
    func addBookmark() {
        addBookmark(atIndex: currentIndex)
    }

    /// 指定したページインデックスにブックマークを追加する。見開き表示中、クリック位置
    /// (コンテキストメニュー)や環境設定(SpreadBookmarkTargetBehavior)に応じて、起点ページ
    /// (currentIndex)ではなく相方ページ(currentIndex + 1)を対象にしたい場合があるため、
    /// インデックスを明示的に指定できるようにしている(ViewerView.toggleCurrentPageBookmark/
    /// contextMenuContent参照)。
    func addBookmark(atIndex index: Int) {
        // 同じページに対するブックマークが既にある場合は、重複して追加しない(要望)。
        // bookmarksはreloadBookmarks()で都度読み直しているため、ここでの判定は常に最新の状態を見る。
        guard !bookmarks.contains(where: { $0.pageIndex == index }) else { return }
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
            pageIndex: index,
            name: "\(pagePrefix) \(index + 1)",
            bookmarkData: bookmarkData,
            fileNodeIdentifier: FileNodeIdentifier.current(for: book.sourceURL)
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

    // MARK: - ルーペ

    func toggleLoupe() {
        isLoupeActive.toggle()
    }

    // MARK: - 境界処理(ループ設定)

    private func handleForwardBoundary() {
        switch preferences.loopBehavior {
        case .loop:
            cancelPendingPageFlip()
            currentIndex = normalizedAnchorIndex(0)
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
            currentIndex = normalizedAnchorIndex(rawIndex)
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

    /// - Parameter ignorePreviousDisplayedRange: trueの場合、lastDisplayedPageRangeによる
    ///   「直前に表示していたページを新しい相方として再利用しない」制約を今回の読み込みに限り
    ///   適用しない。shiftByOnePage()のように、組み合わせを意図的に1ページ分ずらすための操作
    ///   自身の再読み込みで使う(shiftByOnePageのコメント参照)。
    private func reloadAsync(ignorePreviousDisplayedRange: Bool = false) {
        // 前回の読み込みタスクが残っていれば、まずキャンセルしてから新しいタスクを開始する。
        // こうしないと、素早く連続してページ送りしたときに古いリクエストのデコード処理が
        // キャンセルされずキューに残り続け、最新のページの表示が遅れてしまう。
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.loadCurrentSpread(ignorePreviousDisplayedRange: ignorePreviousDisplayedRange)
        }
    }

    private func loadCurrentSpread(prefetch: Bool = true, ignorePreviousDisplayedRange: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        let targetIndex = currentIndex
        // まだ上書きされていない、直前にloadCurrentSpreadが表示したページの範囲を保持しておく
        // (このロードの結果でlastDisplayedPageRangeを新しい範囲に更新する前に読む必要がある)。
        // shouldPairWithNextPageへ渡し、直前のページを再利用したペア化を防ぐために使う
        // (lastDisplayedPageRangeのコメント参照)。ignorePreviousDisplayedRangeがtrueの場合は
        // この制約自体を今回に限り適用しない(reloadAsyncのコメント参照)。
        let previousRange = ignorePreviousDisplayedRange ? nil : lastDisplayedPageRange

        guard !Task.isCancelled else { return }

        // wideImageCacheのカバー範囲をtargetIndex付近に広げておく(バックグラウンドで行うため
        // ここでは待たない)。詳細はprimeWideImageCacheのコメント参照。読みかけの本を「前回の
        // 続きから」再開した直後など、targetIndexより前のページを一度も表示していない状態で
        // すぐに「前のページへ戻る」を行うケースに備える。
        primeWideImageCache(around: targetIndex, radius: max(Int(preferences.prefetchPageCount), 2))

        var images: [CGImage] = []
        if let firstImage = await pageLoader.pageImage(at: targetIndex) {
            guard !Task.isCancelled else { return }
            images.append(firstImage)

            if shouldPairWithNextPage(at: targetIndex, firstImage: firstImage, previousDisplayedRange: previousRange),
               let secondImage = await pageLoader.pageImage(at: targetIndex + 1) {
                images.append(secondImage)
                // ペアの相方(targetIndex + 1)自身の横長判定はこの組み合わせの成立可否には
                // 使っていない(shouldPairWithNextPageはfirstImage側だけを見る)が、実際に
                // 画像を読み込めた以上、wideImageCacheへ記録しておく手間は小さく、backward/
                // forwardStepSizeが後で同期的に参照できるようになる恩恵の方が大きい
                // (wideImageCacheのコメント参照)。
                _ = isWideImage(width: secondImage.width, height: secondImage.height, pageIndex: targetIndex + 1)
            }
        }

        // 読み込み中にさらに新しいページ送りが起きていたら、この結果は古いので捨てる
        guard generation == loadGeneration, !Task.isCancelled else { return }
        currentImages = images
        // 次にloadCurrentSpreadが呼ばれたときに参照できるよう、今回実際に表示した範囲を
        // 記録しておく(lastDisplayedPageRangeのコメント参照)。
        lastDisplayedPageRange = targetIndex..<(targetIndex + images.count)

        // コンテキストメニュー「情報を見る」(ユーザー要望)向けに、実際に表示するページの
        // 画像ファイル情報をバックグラウンドで取得しておく(pageImageInfoCacheのコメント参照)。
        cachePageImageInfo(at: targetIndex)
        if images.count > 1 {
            cachePageImageInfo(at: targetIndex + 1)
        }

        // キャンセル済みなら、先読み(周辺ページのデコード)は行わずここで打ち切る。
        // これも「古いリクエストが最新のリクエストのデコード処理待ちを引き起こす」ことを防ぐため。
        guard !Task.isCancelled, prefetch else { return }
        let radius = max(Int(preferences.prefetchPageCount), 0)
        await pageLoader.prefetch(around: targetIndex, radius: radius)
    }

    /// 見開き表示中でも単ページとして扱うべき横長画像かどうかを判定する。
    ///
    /// pageIndexを渡すと、判定結果をwideImageCacheに記録する(そのページについて画像を
    /// 読み込んで実際に判定した、という事実そのものが後から同期的に再利用できる価値を持つため。
    /// wideImageCacheのコメント参照)。呼び出し側がどのページの判定かを特定できない場合
    /// (現状は無いが将来のため)はnilのままでよく、その場合は単に判定結果を返すだけで
    /// キャッシュへの記録は行わない。
    private func isWideImage(width: Int, height: Int, pageIndex: Int? = nil) -> Bool {
        guard height > 0 else { return false }
        let ratio = Double(width) / Double(height)
        let result = ratio >= preferences.singlePageAspectRatioThreshold
        if let pageIndex, book.pages.indices.contains(pageIndex) {
            wideImageCache[book.pages[pageIndex].sortKey] = result
        }
        return result
    }

    /// wideImageCacheに記録済みの横長判定結果があれば返す(無ければnil)。
    /// backwardStepSize/forwardStepSizeが、画像を読み込み直さずに同期的に参照するために使う
    /// (wideImageCacheのコメント参照)。
    private func cachedIsWideImage(at index: Int) -> Bool? {
        guard book.pages.indices.contains(index) else { return nil }
        return wideImageCache[book.pages[index].sortKey]
    }

    /// コンテキストメニュー「情報を見る」(ユーザー要望)から、指定ページの画像ファイル情報を
    /// 同期的に参照する。pageImageInfoCacheのコメント参照。まだ取得できていない場合はnilを
    /// 返す(通常は現在表示中のページのため、loadCurrentSpreadの時点で取得を開始しており、
    /// メニューを開くまでには揃っているはず)。
    func pageImageInfo(atIndex index: Int) -> PageImageInfo? {
        guard book.pages.indices.contains(index) else { return nil }
        return pageImageInfoCache[book.pages[index].sortKey]
    }

    /// indexのページの画像ファイル情報を取得し、pageImageInfoCacheへ格納する。既に取得済みの
    /// ページは何もしない(同じページに何度も右クリックしても取得し直さない)。
    private func cachePageImageInfo(at index: Int) {
        guard book.pages.indices.contains(index) else { return }
        let key = book.pages[index].sortKey
        guard pageImageInfoCache[key] == nil else { return }
        Task { [weak self] in
            guard let self, let info = await self.pageLoader.pageImageInfo(at: index) else { return }
            self.pageImageInfoCache[key] = info
        }
    }

    /// index付近(前後radius枚)のうち、まだwideImageCacheに判定結果が無いページについて、
    /// 画像のヘッダー情報(PageLoader.pageSize(at:)、ピクセルデコードを伴わない)だけを使って
    /// 横長判定を行い、キャッシュへ記録しておく。
    ///
    /// PageLoader.prefetch(around:radius:)は、フルサイズ画像をデコードしてPageLoader自身の
    /// キャッシュへ格納するだけで、isWideImageによる横長判定までは行わない(判定はあくまで
    /// ViewerViewModel側の責務のため)。そのため、prefetchだけではwideImageCacheは埋まらない。
    ///
    /// 経緯(ユーザー報告): 読みかけの本を「前回の続きから」開いた場合、再開位置(targetIndex)
    /// より前のページは一度も表示・判定していないため、この本を開いた直後にwideImageCacheは
    /// 空に近い状態になる。この状態のまま「前のページへ戻る」を行うと、backwardStepSizeは
    /// キャッシュを参照できず、横長画像ヒューリスティックのフォールバック(近似)に頼ることに
    /// なり、修正前と同じ理由でページが飛ばされる不具合が再現しうる。そのため、実際に
    /// 見開きを表示するたび(loadCurrentSpread、本を開いた直後を含む)に、その付近を
    /// あらかじめ判定してキャッシュを温めておく。
    ///
    /// ピクセルデコードを伴わないPageLoader.pageSize(at:)を使うのはwideImageAspectRatios
    /// (自動レイアウト計算)と同じ理由(体感速度優先。以前はサムネイルデコードを使っていたが、
    /// 判定に必要なのは縦横比だけのため、ヘッダー読み取りだけで済むこちらに置き換えた)。
    /// 結果を待たずバックグラウンドで行い(prefetchと同じ考え方)、呼び出し元
    /// (loadCurrentSpread)をブロックしない。既に判定済みのページはmissingIndicesに
    /// 含めないため、同じ範囲に対して繰り返し呼んでも(通常のページ送りのたびに呼ばれる)
    /// 無駄な再判定は発生しない。
    private func primeWideImageCache(around index: Int, radius: Int) {
        guard book.pages.indices.contains(index), radius > 0 else { return }
        let lower = max(0, index - radius)
        let upper = min(book.pages.count - 1, index + radius)
        guard lower <= upper else { return }
        let missingIndices = (lower...upper).filter { cachedIsWideImage(at: $0) == nil }
        guard !missingIndices.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            for pageIndex in missingIndices {
                guard !Task.isCancelled else { return }
                guard let size = await self.pageLoader.pageSize(at: pageIndex) else { continue }
                _ = self.isWideImage(width: size.width, height: size.height, pageIndex: pageIndex)
            }
        }
    }

    /// 本を開いた直後に、本全体のページについて横長判定を低優先度のバックグラウンドタスクで
    /// 先に済ませておく。
    ///
    /// 経緯(ユーザー報告): primeWideImageCache(around:radius:)は表示するたびにcurrentIndex
    /// 付近だけを先読みするが、スクロールホイールを高速に連続して回した場合、advance(forward:)
    /// は待ち行列(pageFlipQueue)へ次々に目的地を積みながらそのつど同期的に歩幅
    /// (backwardStepSize/forwardStepSize)を計算するため、その付近の先読み判定用バックグラウンド
    /// タスクが完了するより先に、まだ判定していない遠いページの歩幅計算に到達してしまうことが
    /// ある(そうなると結局、横長ヒューリスティックのフォールバック(近似)に頼ることになり、
    /// ページが飛ばされる不具合が再発しうる)。
    ///
    /// これを補うため、本を開いた時点でcurrentIndexを起点に近い順(前後交互)へ本全体を
    /// バックグラウンドで先読み判定しておく。優先度を.utilityにし、実際のページ表示に使う
    /// フルサイズ画像のデコード(.userInitiated、PageLoader.decodedImage参照)より優先度を
    /// 下げているため、通常の読書体験(表示速度)を妨げない。ピクセルデコードを伴わない
    /// PageLoader.pageSize(at:)を使うのはwideImageAspectRatiosと同じ理由(以前はサムネイル
    /// デコードを使っていたが、ヘッダー読み取りだけで済むこちらに置き換えた)。
    ///
    /// ヘッダー読み取りのみのため、以前のサムネイルデコードに比べて大幅に軽いが、数百ページ
    /// 規模の本では合計の所要時間がゼロにはならない。低優先度のバックグラウンド処理のため
    /// 許容している。開いた直後・再開位置からごく近い範囲は既にprimeWideImageCache(即座に、
    /// 同じくバックグラウンドで)がカバーするため、この関数はあくまで「その先の、より広い
    /// 範囲への保険」という位置づけ。
    private func warmUpWideImageCacheForEntireBook() {
        let total = book.pages.count
        guard total > 0 else { return }
        let start = min(max(currentIndex, 0), total - 1)

        // currentIndexから近い順(前後交互)に判定していく。高速スクロールで壊れやすいのは
        // 「今いる位置から少し離れた、まだ見ていないページ」であるため、遠いページより
        // 近いページを先に判定した方が実際の被害軽減効果が大きい。
        var order: [Int] = [start]
        var offset = 1
        while order.count < total {
            let forwardIndex = start + offset
            let backwardIndex = start - offset
            if forwardIndex < total { order.append(forwardIndex) }
            if backwardIndex >= 0 { order.append(backwardIndex) }
            offset += 1
        }

        Task(priority: .utility) { [weak self] in
            for pageIndex in order {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.cachedIsWideImage(at: pageIndex) == nil else { continue }
                guard let size = await self.pageLoader.pageSize(at: pageIndex) else { continue }
                guard !Task.isCancelled else { return }
                _ = self.isWideImage(width: size.width, height: size.height, pageIndex: pageIndex)
            }
        }
    }

    /// targetIndexのページを、次のページ(targetIndex + 1)と組にして見開き表示すべきかどうかを
    /// 判定する。loadCurrentSpread(実際に止まったページの表示)とloadTransitFrame(通過中の
    /// コマの簡易表示)の両方から共通で使う(ロジックが分かれていると、どちらかだけ直し忘れる
    /// バグの元になるため)。
    ///
    /// EPUBのpage-spread-left/right/rendition:page-spread-center指定(またはDB由来の同等の
    /// 設定。3.2節)がある場合は、その指定を横長画像の自動単ページ化ヒューリスティック
    /// (isWideImage)より優先する(詳細はlayoutHint(at:)参照)。
    ///
    /// page-spread-left/rightは実際の画面上の左右を指す(EPUB仕様上、page-progression-directionに
    /// 応じて著者側が画面上の位置として付与する値。DB由来のPageLayoutState.spreadLeft/
    /// spreadRightも、anchor(forPageAtIndex:explicitState:)/writeAnchorPinのコメントで説明して
    /// いる通り、常に画面上の左右と一致させる設計にしている)。そのため「targetIndex自身が
    /// 見開きの起点(1枚目、=読み順で先に読むページ)にはなれない位置」「次のページ
    /// (targetIndex+1)が単独、またはtargetIndexより後ろのページと組むべき位置」は、読み方向に
    /// よって画面上の左右が入れ替わる(右開き=読み順で先のページが画面右、左開き=画面左。
    /// orderedCurrentImages参照)ため、判定もそれに応じて入れ替える。
    /// - 右開き: targetIndex自身がcenter/left相当なら組めない(leftは2番目に読むページ=常に
    ///   直前のページと組む)。次のページがcenter/right相当なら組めない(rightは1番目に読む
    ///   ページ=常に次のページと組む)。
    /// - 左開き: 従来通り、targetIndex自身がcenter/right相当、次のページがcenter/left相当なら
    ///   組めない。
    /// - どちらのページにも明示指定が無い場合だけ、従来通り横長画像なら単ページ扱いにする
    ///   ヒューリスティックを適用する。ただしその場合でも、previousDisplayedRangeが指定されて
    ///   いれば、その範囲のページ(直前にloadCurrentSpreadが実際に表示していたページ)を
    ///   相方として再利用することはしない(lastDisplayedPageRangeのコメント参照。「1ページだけ
    ///   送る」操作等で見開きの組み合わせを手動でずらした状態から前後にページ送りしたとき、
    ///   直前の見開きの一方を無関係な別のページと組み直してしまう不整合を防ぐため)。
    ///
    /// - Parameter previousDisplayedRange: 直前にloadCurrentSpreadが実際に表示していたページの
    ///   範囲。loadCurrentSpread以外(loadTransitFrame、通過中コマの簡易表示)から呼ぶ場合は
    ///   デフォルトのnilのままでよい(通過中の表示はあくまで見た目重視の簡易表示のため、この
    ///   制約を適用する必要が無い)。
    private func shouldPairWithNextPage(
        at targetIndex: Int, firstImage: CGImage, previousDisplayedRange: Range<Int>? = nil
    ) -> Bool {
        guard displayMode == .spread, targetIndex + 1 < book.pages.count else { return false }

        let currentPosition = layoutHint(at: targetIndex)
        let nextPosition = layoutHint(at: targetIndex + 1)
        let isRTL = readingDirection == .rightToLeft
        let disallowedForCurrent: PageSpreadPosition = isRTL ? .left : .right
        let disallowedForNext: PageSpreadPosition = isRTL ? .right : .left

        if currentPosition == .center || currentPosition == disallowedForCurrent { return false }
        if nextPosition == .center || nextPosition == disallowedForNext { return false }

        if currentPosition != nil || nextPosition != nil { return true }

        // 明示指定がどちらにも無く、横長ヒューリスティックだけで判定する場合に限り、直前の
        // 見開きのページを再利用したペア化を拒否する(lastDisplayedPageRangeのコメント参照)。
        // 明示指定がある場合(上のガードで既にtrue/falseが確定している場合)は、そちらの
        // 権威的な指定を優先し、この制約は適用しない(EPUB/DB側の指定自体が常に整合した
        // ペアを表しているはずのため、実務上ここに抵触することは無い想定だが、優先順位を
        // 明確にしておく)。
        if let previousDisplayedRange, previousDisplayedRange.contains(targetIndex + 1) {
            return false
        }

        return !isWideImage(width: firstImage.width, height: firstImage.height, pageIndex: targetIndex)
    }

    /// 現在1枚だけ表示中(見開き表示中だが相方が見つからない、または単ページ表示モード)の
    /// とき、そのページ自身にEPUB/DB由来の明示的な見開き左右指定(center以外)があれば返す。
    /// nilなら「そもそも指定が無い(横長画像ヒューリスティックによる単ページ化、または
    /// 単ページ表示モード)」ため、通常通り中央に単ページ表示すればよい。
    ///
    /// ViewerViewはこの値を使い、EPUB Reading Systems 3.3 6.1.4節の「page-spread-left/right
    /// の指定は、相方が見つからない場合でも空白ページを挿入してでも尊重しなければならない
    /// (MUST: 'it MUST be honored (e.g., by inserting a blank page)')」という挙動を再現する
    /// (qooViewerの画像ビューアはEPUB出力前のプレビューとして機能させたい、というユーザー要望
    /// による)。
    ///
    /// 返す値(.left/.right)は常に画面上の絶対位置を表す(EPUB仕様のpage-spread-left/right
    /// 自体が画面上の絶対位置を表すプロパティであり、読み方向に応じた変換は行わない設計。
    /// Task #82の調査・PageLayoutState.spreadLeft/spreadRightの設計、layoutHint(at:)の
    /// コメント参照)。そのためViewerView側でも読み方向による変換は不要で、.leftならそのまま
    /// 画面左に実画像・画面右に空白、.rightならその逆、という単純な対応でよい。
    var currentSoleImageForcedSpreadPosition: PageSpreadPosition? {
        guard displayMode == .spread, currentImages.count == 1 else { return nil }
        let position = layoutHint(at: currentIndex)
        return position == .center ? nil : position
    }

    /// 生のページインデックスを、そのページがEPUBのpage-spread-right指定(またはDB由来の
    /// 「見開き右」設定)を持つ場合に、正しい組み合わせの起点(1つ前のページ)へ補正する。
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
    ///
    /// インスタンスメソッド(以前はstatic)にしたのはlayoutHint(at:)(DB由来の設定を含む)を
    /// 参照するため。init内で呼ぶ場合は、book/pageLayoutStates/bookLayoutSettingsが
    /// 出揃った後(displayMode等の代入より後)でなければならない点に注意。
    ///
    /// shouldPairWithNextPageと同じ理由(コメント参照)で、「単独で着地してはいけない位置」は
    /// 読み方向によって入れ替わる(右開き=2番目に読むページ=.left相当、左開き=.right相当)。
    private func normalizedAnchorIndex(_ rawIndex: Int) -> Int {
        guard book.pages.indices.contains(rawIndex), rawIndex > 0 else { return rawIndex }
        let disallowedAlone: PageSpreadPosition = readingDirection == .rightToLeft ? .left : .right
        guard layoutHint(at: rawIndex) == disallowedAlone else { return rawIndex }
        return rawIndex - 1
    }

    // MARK: - レイアウト設定(BookLayoutSettings/PageLayoutOverride)の解決

    /// あるページについて、EPUB由来・DB由来のどちらかにレイアウトヒントがあれば返す
    /// (優先順位: EPUB > DB。設計コンセプト2.4節)。どちらも無ければnil(呼び出し側で
    /// isWideImageヒューリスティックにフォールバックする)。
    ///
    /// 戻り値はPageSpreadPosition(left/right/center)に統一する。EPUB由来はそのまま、
    /// DB由来のPageLayoutStateはasEpubEquivalentSpreadPositionで変換する。除外(excluded)は
    /// ここには現れない(prepareBook/applyLayoutDataの時点でbook.pagesから既に取り除かれて
    /// いるため。設計コンセプト12節「アーキテクチャ上の変更点」参照)。
    private func layoutHint(at index: Int) -> PageSpreadPosition? {
        guard book.pages.indices.contains(index) else { return nil }
        if let epub = book.pages[index].epubSpreadPosition { return epub }
        let pageKey = book.pages[index].sortKey
        return pageLayoutStates[pageKey]?.asEpubEquivalentSpreadPosition
    }

    /// レイアウト設定(BookLayoutSettings/PageLayoutOverride)を、実際に読書フローで使う
    /// ページ一覧に適用する。BookLoaderが返す生のMangaBookに対して、
    /// (1) ページ順序の補正(2.3節のpageOrderOverride)、
    /// (2) 除外(非表示)ページの除去(2.2節)
    /// の2つを行う。差し替えの疑いがある場合(2.5節)は何も適用せず、生のbookと差し替え
    /// ステータスをそのまま返す(呼び出し元がViewerView経由で確認ダイアログを出し、
    /// resolveLayoutReplacement(applyExisting:)で解決するまで安全側に倒す)。
    private static func prepareBook(
        from rawBook: MangaBook, layoutStore: LayoutStore
    ) -> (
        book: MangaBook,
        replacementStatus: LayoutContentReplacementStatus,
        settings: BookLayoutSettings?,
        overrides: [String: PageLayoutState]
    ) {
        let replacementStatus = layoutStore.checkContentReplacement(book: rawBook)
        guard replacementStatus == .unaffected else {
            return (rawBook, replacementStatus, nil, [:])
        }

        let settings = layoutStore.bookLayoutSettings(forBookID: rawBook.id)
        var overridesByKey: [String: PageLayoutState] = [:]
        for override in layoutStore.pageOverrides(forBookID: rawBook.id) {
            overridesByKey[override.pageKey] = override.state
        }
        let adjustedPages = applyLayoutData(
            to: rawBook.pages, pageOrderOverride: settings?.pageOrderOverride, overridesByKey: overridesByKey
        )
        let adjustedBook = MangaBook(
            id: rawBook.id,
            title: rawBook.title,
            sourceURL: rawBook.sourceURL,
            pages: adjustedPages,
            sourceLayoutHint: rawBook.sourceLayoutHint
        )
        return (adjustedBook, .unaffected, settings, overridesByKey)
    }

    /// pageOrderOverride(2.3節)による並べ替えと、除外(excluded、2.2節)の除去を適用する。
    /// - 並べ替え: pageOrderOverrideに含まれるpageKeyの順に並べ、保存後に増えたページ
    ///   (未知のpageKeyを持つページ)は元の並び順のまま末尾に追加する。pageOrderOverrideに
    ///   含まれるが現在のpagesに存在しないpageKey(ファイルが削除された等)は単純に無視する。
    /// - 除外: pageKeyがoverridesByKeyで.excludedになっているページを取り除く。
    private static func applyLayoutData(
        to pages: [PageRef], pageOrderOverride: [String]?, overridesByKey: [String: PageLayoutState]
    ) -> [PageRef] {
        var ordered = pages
        if let pageOrderOverride {
            var pageByKey: [String: PageRef] = [:]
            for page in pages { pageByKey[page.sortKey] = page }
            var seenKeys: Set<String> = []
            var reordered: [PageRef] = []
            for key in pageOrderOverride {
                if let page = pageByKey[key] {
                    reordered.append(page)
                    seenKeys.insert(key)
                }
            }
            for page in pages where !seenKeys.contains(page.sortKey) {
                reordered.append(page)
            }
            ordered = reordered
        }
        return ordered.filter { overridesByKey[$0.sortKey] != .excluded }
    }

    /// 差し替え検知(2.5節)の確認ダイアログへの回答を反映する。
    /// - applyExisting: true(「そのまま適用する」。ページ数が一致している場合のみ選べる)の
    ///   ときは、記録済みの指紋を今回の内容で更新し(LayoutStore.acceptCurrentContent)、
    ///   ページ単位/本全体の設定を読み直す。ページ順補正・除外ページの除去も含め、
    ///   reloadLayoutData側でその場でbook.pagesへ反映される(詳細はreloadLayoutData参照。
    ///   以前は本を開き直すまで反映されない制約があったが、ユーザー要望を受けて解消した)。
    /// - applyExisting: false(「破棄する」)のときは、この本のレイアウトデータを削除する
    ///   (LayoutStore.discardLayoutData)。
    ///
    /// 「エクスポートしてから破棄する」という3択目(2.5節)は、JSONエクスポート機能の実装後に
    /// 追加する予定(現時点では「破棄する」のみ)。
    func resolveLayoutReplacement(applyExisting: Bool) {
        guard pendingLayoutReplacementStatus != nil else { return }
        if applyExisting {
            layoutStore.acceptCurrentContent(book: book)
        } else {
            layoutStore.discardLayoutData(forBookID: book.id)
        }
        pendingLayoutReplacementStatus = nil
        reloadLayoutData()
    }

    /// この本のBookLayoutSettings/PageLayoutOverrideを読み直す。layoutDataChangeObserver
    /// (他ウインドウでの変更)、resolveLayoutReplacement(差し替え確認の解決)、setPageLayout/
    /// clearPageLayout/autoLayoutFromCurrentView(3.2節・3.1節の個別ページ操作)のすべてから呼ぶ。
    ///
    /// 読み方向・見開き強制の上書き、および個々のページの単一/見開き左右の状態(pairing判定・
    /// ロック判定)は、book.pagesの構造を変えずに反映できるため常に即座に反映される。
    ///
    /// ページ順補正(pageOrderOverride)・除外ページ(excluded)は、book.pages自体の構造(並び順・
    /// 含まれるページ)に関わるため、以前はこの本を開き直すまで反映されない制約があった。
    /// コンテキストメニュー/Layoutメニューで除外したページが画像ビューアの表示へ即座に反映
    /// されず不便、というユーザー要望を受け、rawPages(除外・並べ替え適用前の生のページ一覧)
    /// から都度applyLayoutDataで再構築し直し、book.pagesを丸ごと差し替えることで解消した。
    /// book.pages自体を書き換える(要素を挿入・削除する)のではなく新しい配列を作って丸ごと
    /// 差し替えているのは、pageLoader(actor)側の内部状態(readers/キャッシュ等)を巻き込まずに
    /// 済む、単純で副作用の少ない方法のため。
    ///
    /// - Parameter focusPageKey: コンテキストメニュー・Layoutメニュー(このウインドウ自身での
    ///   操作)、または「ブックマーク・レイアウトの編集」ウインドウ(他ウインドウでの操作。
    ///   layoutDataChangeObserverがnotification.userInfoの"focusPageKey"から受け取って渡す)で
    ///   ユーザーが直接操作したページのsortKey。指定があれば、以前どのページを表示していたかに
    ///   関わらず、更新後の表示にこのページを含めるよう表示位置を移動する(ユーザー要望:
    ///   「更新後のビューア画面は、直接操作されたページを表示に含める」)。そのページ自身が
    ///   除外されて消えていた場合は、fallbackIndexで元々あった位置に一番近い現存ページへ
    ///   自動的にフォールバックする。nil(既定値)の場合は、以前どおり現在表示中のページを
    ///   維持しようとする(読み方向の上書きなど、対象となる特定のページが無い変更向け)。
    private func reloadLayoutData(focusPageKey: String? = nil) {
        bookLayoutSettings = layoutStore.bookLayoutSettings(forBookID: book.id)
        var overridesByKey: [String: PageLayoutState] = [:]
        for override in layoutStore.pageOverrides(forBookID: book.id) {
            overridesByKey[override.pageKey] = override.state
        }
        pageLayoutStates = overridesByKey

        let rebuiltPages = Self.applyLayoutData(
            to: rawPages, pageOrderOverride: bookLayoutSettings?.pageOrderOverride, overridesByKey: overridesByKey
        )
        let oldPages = book.pages
        let pagesChanged = rebuiltPages.map(\.sortKey) != oldPages.map(\.sortKey)

        var updatedBook: MangaBook?
        if pagesChanged {
            var newBook = book
            newBook.pages = rebuiltPages
            book = newBook
            updatedBook = newBook
        }
        // pagesChangedならbook.pagesは既にrebuiltPagesに差し替え済み、そうでなければ従来どおり
        // oldPagesのまま(参照の便宜上、以後はbook.pagesを直接使う)。
        let newPages = book.pages

        // 表示の移動先を決める基準ページのsortKey。focusPageKeyが指定されていれば常にそれを
        // 優先する。指定が無ければ、以前どおり現在表示中のページを維持しようとする。
        let anchorPageKey = focusPageKey ?? (oldPages.indices.contains(currentIndex) ? oldPages[currentIndex].sortKey : nil)

        let restoredIndex: Int
        if let anchorPageKey, let newIndex = newPages.firstIndex(where: { $0.sortKey == anchorPageKey }) {
            restoredIndex = newIndex
        } else if let anchorPageKey, let oldIndex = oldPages.firstIndex(where: { $0.sortKey == anchorPageKey }) {
            // 基準ページ自身が除外されて消えていた場合、元々あった位置(oldIndex)を基準に
            // 一番近い現存ページへフォールバックする(fallbackIndex参照)。
            restoredIndex = Self.fallbackIndex(oldPages: oldPages, currentIndex: oldIndex, newPages: newPages)
        } else {
            restoredIndex = Self.fallbackIndex(oldPages: oldPages, currentIndex: currentIndex, newPages: newPages)
        }
        let clampedIndex = newPages.isEmpty ? 0 : min(max(restoredIndex, 0), newPages.count - 1)
        // 見開き右ページ単独に着地してしまわないよう、他の着地経路(jump等)と同じく補正する
        // (normalizedAnchorIndexのコメント参照。この時点でbook.pagesは既に最新のnewPagesに
        // 揃っているため、安全に呼べる)。
        currentIndex = normalizedAnchorIndex(clampedIndex)

        if let updatedBook {
            Task { [weak self] in
                guard let self else { return }
                // pageLoader(actor)側のindex基準の参照も、新しいbook.pagesの並びに揃える。
                // 表示の再計算(loadCurrentSpread)より前に必ず終えておく必要があるため、
                // 同じTask内で順番に行う。
                await self.pageLoader.updateBook(updatedBook)
                await self.loadCurrentSpread()
            }
        } else {
            // 読み方向・見開き強制のロック状態や、focusPageKeyによる表示移動が変わった可能性が
            // あるため、現在の表示を再計算する。
            Task { [weak self] in
                await self?.loadCurrentSpread()
            }
        }
    }

    /// この本のBookLayoutSettings/PageLayoutOverrideが、コンテキストメニュー・Layoutメニュー・
    /// 「ブックマーク・レイアウトの編集」ウインドウのいずれから変更された場合でも、この本を
    /// 開いている他のウインドウ/タブ(自分自身を含む)へ「どのページを直接操作したか」を伝える
    /// ための通知を投げる。layoutStore.setPageLayoutState等が既に投げているbookIDのみの通知
    /// (focusPageKeyを含まない)と共存し、この通知は「ユーザーが直接操作したページを更新後の
    /// 表示に含める」(ユーザー要望)ための追加の合図として使う。
    private func postLayoutFocusChange(pageKey: String) {
        NotificationCenter.default.post(
            name: .layoutDataDidChange, object: nil, userInfo: ["bookID": book.id, "focusPageKey": pageKey]
        )
    }

    /// reloadLayoutDataで、除外(非表示)に設定されたことで直前まで表示していたページ自体が
    /// 新しいbook.pagesから消えてしまった場合に、代わりに表示すべきページのインデックスを
    /// 決める。元の並び順で現在位置以降(=直後)にある、まだ存在するページを優先し、
    /// それも見つからなければ以前(=直前)のページを探す。1ページも残っていなければ0を返す。
    private static func fallbackIndex(oldPages: [PageRef], currentIndex: Int, newPages: [PageRef]) -> Int {
        guard !newPages.isEmpty else { return 0 }
        guard oldPages.indices.contains(currentIndex) else { return 0 }
        for oldPage in oldPages[currentIndex...] {
            if let index = newPages.firstIndex(where: { $0.sortKey == oldPage.sortKey }) {
                return index
            }
        }
        for oldPage in oldPages[..<currentIndex].reversed() {
            if let index = newPages.firstIndex(where: { $0.sortKey == oldPage.sortKey }) {
                return index
            }
        }
        return 0
    }

    // MARK: - レイアウト操作(3節)

    /// 現在表示中のページの並び(pageKey)。単一表示、または見開き表示中でも実際には
    /// 相手が見つからず1枚だけ表示されている場合は1件、見開きで2ページとも表示されている
    /// 場合は2件(読み順)。3.1節「自動でレイアウトする」の起点(anchor)、および3.2節の
    /// 個別ページ操作の対象特定に使う。
    private var currentAnchorPageKeys: [String] {
        guard book.pages.indices.contains(currentIndex) else { return [] }
        var keys = [book.pages[currentIndex].sortKey]
        let partnerIndex = currentIndex + 1
        if currentImages.count > 1, book.pages.indices.contains(partnerIndex) {
            keys.append(book.pages[partnerIndex].sortKey)
        }
        return keys
    }

    /// ソースファイル自身(EPUB/PDF)由来の権威的なレイアウト指定がある本かどうか。3.1節
    /// 「このアクション自体を無効化する」の判定、および呼び出し元(Layoutメニュー等)のUI
    /// 無効化に使う。EPUBは常にtrue(BookLoader.loadEpubが必ずsourceLayoutHintを持たせるため)。
    /// PDFは、Document Catalogに/ViewerPreferences/Directionまたは/PageLayoutの明示的な指定が
    /// あるときのみtrue(PDFStructureResolver.resolveLayoutHint参照。多くのPDFはどちらも
    /// 持たないため、通常のPDFはfalseのままレイアウト編集が可能)。
    var hasAuthoritativeSourceLayout: Bool {
        book.sourceLayoutHint != nil
    }

    /// orderedPageKeysの各ページについて、横長画像(見開き表示中でも単ページ扱いにすべき)
    /// かどうかを判定する。PageLoader.pageSize(at:)(ピクセルデコードを伴わない、フォーマットの
    /// ヘッダー部分だけを読む取得)を使い、アスペクト比の判定にフル解像度のデコードは必要ない
    /// ため、体感速度を優先する。
    ///
    /// 自動レイアウト計算(3.1節)・伝播範囲を伴う個別ページ操作(3.2節・3.3節)は本全体を
    /// 対象にしうるが、ヘッダー読み取りのみのため、以前のサムネイルデコード方式に比べて
    /// 数百ページ規模の本でもかなり短時間で終わる(実装検討ドキュメント9章のリスク参照。
    /// なお万一のフォーマット非対応等でヘッダーが読めなかった場合に備え、プログレス表示・
    /// キャンセルは今後の改善課題として残している)。
    private func wideImageAspectRatios(for orderedPageKeys: [String]) async -> [String: Bool] {
        let keySet = Set(orderedPageKeys)
        var result: [String: Bool] = [:]
        for (index, page) in book.pages.enumerated() where keySet.contains(page.sortKey) {
            guard let size = await pageLoader.pageSize(at: index) else { continue }
            // isWideImage(pageIndex:)にindexを渡し、この計算のついでにwideImageCacheへも
            // 記録しておく(自動レイアウト計算(3.1節)は本全体を対象にしうるため、これを
            // きっかけに一気に多くのページの判定結果がキャッシュされ、backward/forwardStepSize
            // (通常のページ送り)の同期判定の精度向上にも波及する。wideImageCacheのコメント参照)。
            result[page.sortKey] = isWideImage(width: size.width, height: size.height, pageIndex: index)
        }
        return result
    }

    /// 3.2節の操作で選んだstateから、LayoutAutoCalculatorへ渡すべきAnchor(伝播計算の起点)を
    /// 組み立てる。
    ///
    /// 「見開き右」「見開き左」は、実際の画面上の右/左と常に一致させる(ユーザー報告:
    /// 右開きの本で自動レイアウトすると、画面右のページが「見開き左」、画面左のページが
    /// 「見開き右」として編集ウインドウに表示され、実際の表示とズレていた)。読み方向
    /// (readingDirection)によって「最初に読むページ(ファイル順で早い方)」が画面のどちら側に
    /// 表示されるかが変わる(右開き=右、左開き=左。orderedCurrentImages参照)ため、
    /// どちらのページと組むか(前のページ/次のページ)の判定も読み方向で入れ替える。
    /// - 右開き(readingDirection == .rightToLeft): 「見開き右」は最初に読むページ=次の
    ///   ページと組む(自身が見開きの起点)。「見開き左」は2番目に読むページ=直前のページと組む。
    /// - 左開き: 「見開き右」は直前のページと組む(従来通り)。「見開き左」は次のページと組む。
    private func anchor(forPageAtIndex index: Int, explicitState: PageLayoutState) -> LayoutAutoCalculator.Anchor {
        let pageKey = book.pages[index].sortKey
        let pairsWithNextPage: Bool
        switch explicitState {
        case .spreadRight:
            pairsWithNextPage = readingDirection == .rightToLeft
        case .spreadLeft:
            pairsWithNextPage = readingDirection != .rightToLeft
        case .single, .excluded:
            return .init(pageKeys: [pageKey])
        }
        if pairsWithNextPage {
            guard index + 1 < book.pages.count else { return .init(pageKeys: [pageKey]) }
            return .init(pageKeys: [pageKey, book.pages[index + 1].sortKey])
        } else {
            guard index - 1 >= 0 else { return .init(pageKeys: [pageKey]) }
            return .init(pageKeys: [book.pages[index - 1].sortKey, pageKey])
        }
    }

    /// anchorの示すページ(1件または2件)へ、明示的な状態を書き込む。anchor.pageKeysは常に
    /// [先に読むページ, 2番目に読むページ]の順(anchor(forPageAtIndex:explicitState:)参照)。
    /// どちらに「見開き右」「見開き左」を割り当てるかは読み方向による(同コメント参照)。
    private func writeAnchorPin(_ anchor: LayoutAutoCalculator.Anchor, explicitState: PageLayoutState) {
        if anchor.pageKeys.count >= 2, let earlier = anchor.pageKeys.first, let later = anchor.pageKeys.dropFirst().first {
            let isRTL = readingDirection == .rightToLeft
            let earlierState: PageLayoutState = isRTL ? .spreadRight : .spreadLeft
            let laterState: PageLayoutState = isRTL ? .spreadLeft : .spreadRight
            layoutStore.setPageLayoutState(for: book, pageKey: earlier, state: earlierState)
            layoutStore.setPageLayoutState(for: book, pageKey: later, state: laterState)
        } else if let only = anchor.pageKeys.first {
            layoutStore.setPageLayoutState(for: book, pageKey: only, state: explicitState)
        }
    }

    /// 3.2節: 指定したページ(単一表示なら現在のページ、見開き表示なら左右いずれか)を、
    /// 指定した状態に設定する。scopeが.thisPageOnly以外の場合、3.3節の伝播範囲選択に従って
    /// 周辺ページのレイアウトも横長ヒューリスティック+パリティ計算で再計算する。
    ///
    /// 画像のアスペクト比判定(サムネイル読み込み)が必要なため非同期。呼び出し中はViewerView側で
    /// 適宜ビジー表示を出すことを想定する(このメソッド自体はビジー状態を公開しない。
    /// 今後の改善課題)。
    ///
    /// 既知の制約: 除外(.excluded)に設定した場合、既存の除外ページを伝播範囲内で「解除する」
    /// 選択肢(2.3節・3.3節で触れられている「既存の除外設定を保持しますか、それとも解除しますか」)
    /// は未実装で、常に「保持する」(既存の除外ページには触れない)として動作する。
    func setPageLayout(atIndex index: Int, to state: PageLayoutState, scope: LayoutPropagationScope) async {
        guard book.pages.indices.contains(index) else { return }
        // 呼び出し元(コンテキストメニュー/Layoutメニュー)が直接操作したページ。writeAnchorPin/
        // 伝播計算より前、book.pagesがまだ書き換わっていない時点で控えておく(ユーザー要望:
        // 更新後のビューア画面にこのページを表示に含める。reloadLayoutData(focusPageKey:)参照)。
        let targetPageKey = book.pages[index].sortKey

        guard scope != .thisPageOnly else {
            // 「このページだけ」は、ユーザーが直接操作したページ自身の行だけを書き換える。
            // 以前はここでもwriteAnchorPin(見開き左/右の相方ページへの書き込みを含む)を
            // 呼んでいたが、「ページ2を見開き左に設定すると、指示していないページ3まで
            // 見開き右に変わる」というユーザー報告により、相方ページへは触れない仕様に変更した。
            // 見開き左/右は、相方ページに明示的な設定が無くても表示時に自動でペアと判定される
            // (shouldPairWithNextPage/layoutHint参照: 隣接する2ページのどちらか一方でも
            // 明示指定があれば、もう一方がcenter/left(または center/right)相当でない限りペア
            // 表示になる)ため、相方ページの行を書き換える必要は無い。
            layoutStore.setPageLayoutState(for: book, pageKey: targetPageKey, state: state)
            reloadLayoutData(focusPageKey: targetPageKey)
            postLayoutFocusChange(pageKey: targetPageKey)
            return
        }

        let pageAnchor = anchor(forPageAtIndex: index, explicitState: state)

        // 除外に設定した場合、このページ自身はパリティ計算の対象から外す(2.2節・3.3節: 除外
        // ページは計算から除外する)。それ以外の既存の除外ページは、そもそもbook.pagesに
        // 含まれていない(prepareBook時点で除去済み)ため、自然に計算対象から外れている。
        var orderedKeys = book.pages.map(\.sortKey)
        if state == .excluded {
            orderedKeys.removeAll { $0 == book.pages[index].sortKey }
        }

        let wideness = await wideImageAspectRatios(for: orderedKeys)
        let planned = LayoutAutoCalculator.recalculate(
            orderedPageKeys: orderedKeys, anchor: pageAnchor, scope: scope,
            isWideImage: { wideness[$0] ?? false }, isRightToLeft: readingDirection == .rightToLeft
        )
        // 1件ずつではなく、まとめて1回のトランザクションとして書き込む
        // (LayoutStore.setPageLayoutStatesのコメント参照)。
        layoutStore.setPageLayoutStates(for: book, planned)
        // writeAnchorPinは、ここで操作したページ自身の状態(state)を最終確定させるための
        // 書き込みとして、plannedの適用より後に呼ぶ(以前はplannedより前に呼んでいたため、
        // 直後にplannedで上書きされてしまうケースがあった。下のコメント参照)。
        //
        // 経緯(ユーザー報告): 本の先頭ページを「見開き左」に設定しても、実際には「単一
        // ページ」に置き換わってしまう不具合があった。原因は書き込み順序にあった:
        // writeAnchorPinを先に呼ぶと、いったんは正しくspreadLeftが書き込まれるが、
        // scope==.wholeBookの場合、直後にLayoutAutoCalculator.recalculateが内部で
        // anchorPin(起点の組み合わせをそのまま固定する処理。本来はautoLayoutFromCurrentView()
        // 向けに「現在表示されている組み合わせ」から起点の状態を再構成するための関数で、
        // ユーザーが直接指定したstateそのものは知らない)を再計算し、plannedに含めてしまう。
        // 先頭ページは相方(1つ前のページ)が存在しないためAnchorが1件だけになり、この場合
        // anchorPinの実装は常に.singleを返す(2ページ揃った通常のケースでは「見開き左/右」を
        // 返すため、この不具合は表面化しなかった)。この.singleが後から
        // layoutStore.setPageLayoutStates(planned)で書き込まれ、直前にwriteAnchorPinが
        // 書いた正しいspreadLeftを上書きしてしまっていた。writeAnchorPinをplannedの適用
        // より後に呼ぶことで、ユーザーが直接指定したstateが常に最終的な書き込みとして
        // 勝つようにする(2ページ揃った通常のケースでは、planned側のanchorPinと
        // writeAnchorPinが同じ値を書くため、順序を変えても結果は変わらない)。
        writeAnchorPin(pageAnchor, explicitState: state)
        reloadLayoutData(focusPageKey: targetPageKey)
        postLayoutFocusChange(pageKey: targetPageKey)
    }

    /// 3.2節: 指定したページのレイアウト情報を削除する(「レイアウトなし」に戻す)。
    /// 伝播範囲の選択(3.3節)は行わない(このページ自体を未設定に戻すだけの操作のため)。
    func clearPageLayout(atIndex index: Int) {
        guard book.pages.indices.contains(index) else { return }
        let targetPageKey = book.pages[index].sortKey
        layoutStore.setPageLayoutState(for: book, pageKey: targetPageKey, state: nil)
        reloadLayoutData(focusPageKey: targetPageKey)
        postLayoutFocusChange(pageKey: targetPageKey)
    }

    /// 現在表示中のページ(単一表示なら1ページ、見開き表示なら2ページ)に、既にDB由来の
    /// レイアウト情報が設定されているかどうか。Layoutメニュー/コンテキストメニューで
    /// 「レイアウト情報を削除する」項目を表示するかどうかの判定に使う(3.2節: 「既に設定が
    /// ある場合のみ表示」)。
    func hasPageLayoutOverride(atIndex index: Int) -> Bool {
        guard book.pages.indices.contains(index) else { return false }
        return pageLayoutStates[book.pages[index].sortKey] != nil
    }

    /// 3.1節: 「現在の表示を基準に自動でレイアウトする」。今表示している組み合わせを起点として、
    /// 本全体のレイアウトを自動で再計算・上書きする。
    ///
    /// ソースファイル自身(EPUB/PDF)由来の権威的なレイアウト指定がある本では、呼び出し元
    /// (Layoutメニュー等)がこのアクション自体を無効化する想定(hasAuthoritativeSourceLayout
    /// 参照)だが、念のためここでも早期リターンする。
    func autoLayoutFromCurrentView() async {
        guard !book.pages.isEmpty, !hasAuthoritativeSourceLayout else { return }
        let anchorKeys = currentAnchorPageKeys
        guard !anchorKeys.isEmpty else { return }
        let pageAnchor = LayoutAutoCalculator.Anchor(pageKeys: anchorKeys)
        let orderedKeys = book.pages.map(\.sortKey)
        let wideness = await wideImageAspectRatios(for: orderedKeys)
        let planned = LayoutAutoCalculator.recalculate(
            orderedPageKeys: orderedKeys, anchor: pageAnchor, scope: .wholeBook,
            isWideImage: { wideness[$0] ?? false }, isRightToLeft: readingDirection == .rightToLeft
        )
        layoutStore.setPageLayoutStates(for: book, planned)
        reloadLayoutData()
    }
}
