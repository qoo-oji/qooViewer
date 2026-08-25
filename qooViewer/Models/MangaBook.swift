import Foundation

/// 本のソースファイル自身が持つ、本全体に関わる表示上のヒント。
/// EPUB(package documentのspine)、およびPDF(Document Catalogの`/ViewerPreferences/Direction`・
/// `/PageLayout`)の両方から読み取る(詳細はEpubStructureResolver.resolve/
/// PDFStructureResolver.resolveLayoutHint参照)。
///
/// 値が存在する項目は、その本を**初めて開いたときに1回だけ**DB(BookLayoutSettings /
/// PageLayoutOverride)へ取り込まれ、以降はDB側が優先される
/// (LayoutStore.importSourceLayoutIfNeeded(for:)参照)。ユーザーは読み方向・見開き・ページ単位の
/// レイアウトを、EPUB/PDFでも他の形式と同じように自由に変更できる。
/// 以前はここの値を常に最優先で適用し、対応する切り替え操作自体を無効化(グレーアウト)して
/// いたが、ユーザー要望によりその扱いは廃止した。
/// フォルダ・cbz/cbr/cb7ではMangaBook.sourceLayoutHint自体がnilになる。EPUBは常に非nil
/// (中の2項目自体は未指定ならnilになりうる。「EPUBである」という判定にsourceLayoutHint != nilを
/// 使っている箇所があるため、BookLoader.loadEpubは値の有無に関わらず必ずこの構造体を作る)。
/// PDFは、カタログにどちらの項目も見つからなければ構造体自体がnilになる(EPUBと異なり、
/// PDFであること自体はsourceLayoutHintの有無で判定しない。ViewerViewModelの自動インポート
/// 判定はisEpubFile/isPDFFileで直接ファイル形式を見る)。
struct SourceLayoutHint: Equatable {
    /// EPUB: spine要素の`page-progression-direction`属性。PDF: Document Catalogの
    /// `/ViewerPreferences/Direction`(`L2R`/`R2L`)。どちらも未指定/未対応の値ならnil
    /// (その場合は強制せず、これまで通りユーザー設定/既定値に従う)。
    var pageProgressionDirection: ReadingDirection?
    /// EPUB: package documentの`rendition:spread`メタデータ。`none`は.single、`both`は.spread
    /// に対応する。`landscape`/`portrait`/`auto`/未指定は、macOSのウインドウ表示には向きの概念が
    /// 無いため強制しない(nil)。
    /// PDF: Document Catalogの`/PageLayout`。`TwoPageLeft`/`TwoPageRight`のときのみ.spreadとして
    /// 扱う(詳細はPDFStructureResolver.forcedDisplayModeのコメント参照。`SinglePage`等を
    /// .singleとして強制しないのは、多くのPDF生成ツールがこの項目自体を意図せず省略しており、
    /// EPUBのrendition:spread=noneほどの信頼度が無いため)。
    var forcedDisplayMode: DisplayMode?
}

/// この本が「どこから来たか」。アプリ側の記録(DB・ディスクキャッシュ・履歴)を残してよい本か
/// どうかを決める、永続化まわりの前提そのもの。
///
/// ■ .fileSystem 側の前提
/// このアプリのDB(SwiftData)は、BookReadingState / BookLayoutSettings / PageLayoutOverride /
/// Bookmark / FavoriteBook / BookMetadata のすべてが`MangaBook.id`(=フォルダ/ファイルのフルパス)を
/// キーにしている。さらにAppState.openは本を開くたびに、そのパスのiノード番号を手がかりに
/// 「移動・リネームされた本」を追従させる(reconcileBookIDIfMoved)。
/// つまり**idが実在パスであることは、単なる慣習ではなくDB全体の不変条件**になっている。
///
/// ■ .imageFiles を「その場限りの本」にしている理由
/// 1. **複数枚のとき、その「1冊」に対応する実在パスが存在しない。** 不変条件を破ったまま従来の
///    経路へ流すと、iノードが一致してしまった**既存のお気に入り/レイアウト/ブックマークのbookIDが、
///    その場限りのIDへ恒久的に書き換えられる**(LayoutStoreはPageLayoutOverride.compositeKeyまで
///    書き換えるため復旧不能)。「画像Aを単体で開いてお気に入り登録 → 後でA+Bをドロップ」だけで
///    再現する。またBookReadingStateが際限なく増え、LibraryDataPrunerが**実在する本の読書位置を
///    消す**。
/// 2. **1枚のときは実在パスをidに使えるが、それでも記録しない**(ユーザー要望)。画像を直接開く
///    のは「ちょっと見る」操作であり、枚数によって記録される/されないが変わるほうが分かりにくい。
///    1枚でも複数枚でも「渡した画像がそのまま本になり、閉じれば何も残らない」で統一する。
///
/// 扱いはシークレットウインドウで開いた本とまったく同じ。何を書かないかの全体像は
/// AppState.isPrivateWindowのコメントを正典とし、ここはその一方の入口。
/// 新しい永続化経路を足すときは、必ず両方を確認すること。
///
/// ■ .imageFiles のidに課す制約(守らないと実害が出る)
/// 1枚のときは実在パスをそのまま使う(ウインドウタイトルの拡張子表示や「Finderで表示」が
/// 自然に動くため)。**複数枚のときだけ**、対応する実在パスが無いので次の制約がかかる:
/// - **毎回ランダム**にする(安定した内容ハッシュ等にしてはいけない)。BookPageListCacheのキーは
///   SHA256(bookID)だけで指紋を含まず、ThumbnailDiskCacheの指紋もbookIDと**先頭画像**の
///   更新日時/サイズしか見ない(2枚目以降を見ない)。安定IDにすると「先頭画像は同じ・残りが違う
///   選択」でページ一覧とサムネイルが混線する。ランダムにすればこの衝突が構造的に起こらない
/// - **空文字列にしない**。多数の箇所が`URL(fileURLWithPath: bookID)`を無防備に呼んでおり、
///   空文字列はNSInvalidArgumentExceptionでハードクラッシュする
/// - **ドットを含めない**。FormatBadgeViewとplainTextTitleが`pathExtension`をそのまま読むため、
///   ドットがあると無意味な拡張子バッジが出る
///
/// nonisolated: MangaBookはBookLoader(Task.detached)が組み立ててMainActorへ渡るため
/// (PageSource/PageRefと同じ理由。ArchiveReading.swift冒頭のコメント参照)。
nonisolated enum BookOrigin: Hashable {
    /// 画像フォルダ、zip/rar/7z アーカイブ、PDF、EPUB。
    /// idはディスク上に実在するパスで、DBの全機能がそのまま使える。
    case fileSystem
    /// ユーザーが直接渡した画像ファイル(1枚でも、Finderで複数選択された複数枚でも)。
    /// アプリ側の記録は一切残さない(上のコメント参照)。
    ///
    /// 1枚のときも「同じフォルダの他の画像」へは展開しない。渡されたものがそのまま本になる、
    /// という一貫したルールにしてある(サンドボックス上、画像1枚のドロップで得られる権限は
    /// その1枚だけで、フォルダへ展開すると毎回アクセス許可パネルを挟むことになるため。
    /// フォルダ全体を開きたい場合はフォルダ自体をドロップする導線が既にある)。
    case imageFiles
}

/// 開いている1冊の漫画(画像フォルダ、zip/rar/7z アーカイブ、PDF、EPUB、画像ファイル)
struct MangaBook: Identifiable, Hashable {
    /// 一意なID。フォルダ/アーカイブのファイルパスをそのまま使う
    /// (originが.imageSelectionのときだけ例外。BookOriginのコメント参照)
    let id: String
    /// ビューワーに表示するタイトル
    let title: String
    /// 元になったフォルダ、またはアーカイブファイルの場所
    let sourceURL: URL
    /// 自然順(数字を考慮した順序)に並んだページ一覧。
    /// varなのは、ViewerViewModelが除外(非表示)・並べ替えの変更を画像ビューアの表示へ
    /// 即座に反映できるよう、本を開き直さずにこの配列を丸ごと差し替え直すことがあるため
    /// (詳細はViewerViewModel.reloadLayoutDataのコメント参照)。
    var pages: [PageRef]
    /// 本のソースファイル自身が持つ、本全体の表示ヒント。詳細はSourceLayoutHint参照。
    var sourceLayoutHint: SourceLayoutHint? = nil
    /// この本がどこから来たか。既定値付きなので、従来のBookLoaderの生成箇所は変更不要。
    /// 詳細はBookOrigin参照。
    var origin: BookOrigin = .fileSystem
    /// この本を閉じた後にアプリ側の記録が一切残ってはいけないかどうか。
    /// シークレットウインドウ(AppState.isPrivateWindow)と並ぶ、もう一方の「書かない」条件。
    /// 実際のガードは、この値とisPrivateWindowをORした
    /// ViewerViewModel.skipsPersistence / AppState.open内のローカル変数が担う。
    var isTransient: Bool { origin == .imageFiles }

    /// `sourceURL`がこの本そのものを指しているかどうか。
    ///
    /// 複数枚の画像をまとめた本だけfalseになる。あの本のsourceURLは「先頭1ページの画像」で
    /// あって本そのものではないため、これを本の同一性の判定に使うと、後から**同じ画像1枚**を
    /// Finderで開いたときに複数枚を表示中のウインドウが「同じ本」として前面に出てきてしまう
    /// (LaunchCoordinator.openAppState(forBookAt:)参照)。
    /// 画像1枚の本は、たとえDBへ書かない本であってもsourceURLが本そのものなのでtrue。
    var isIdentifiedBySourceURL: Bool { !(origin == .imageFiles && pages.count > 1) }

    static func == (lhs: MangaBook, rhs: MangaBook) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension MangaBook {
    /// 画面(ウインドウ/タブのタイトル、ツールバーのファイル名表示)に出すこの本の名前。
    ///
    /// 1冊=1ファイル/フォルダの本、および画像1枚の本は`title`そのまま。複数枚の画像をまとめた
    /// 本だけは、`title`が**先頭1枚のファイル名**でしかなく画像1枚を開いた本と見分けがつかない
    /// ため、枚数を添える。
    ///
    /// ローカライズをBookLoader側ではなくここで行い、呼び出し側からLocaleを受け取るのは、
    /// BookLoaderがnonisolatedでAppPreferencesを持たず、あちらで`String(localized:)`すると
    /// **アプリ内の表示言語設定(AppPreferences.displayLanguage)ではなくOSのロケール**が
    /// 使われてしまうため(同じ制約がBookLoaderError.errorDescriptionのコメントに記録されている)。
    /// 表示層は`preferences.effectiveLocale`を持っているので、そこから渡してもらう。
    ///
    /// 複数形の変化を持つ文字列にしていないのは、この分岐へ来る時点でページ数が必ず2以上のため。
    /// String Catalog側で単数形の亜種を用意する必要が無い。
    func displayName(locale: Locale) -> String {
        guard origin == .imageFiles, pages.count > 1 else { return title }
        return String(localized: "\(title) (\(pages.count) images)", locale: locale)
    }
}
