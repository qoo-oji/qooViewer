import Foundation

/// `ComicInfo.xml`(CBZ/CBRの中に置かれる、事実上の標準となっているコミック用メタデータ)の
/// 内容を表す値型。
///
/// 出自と準拠先:
/// - 元はComicRack(開発終了)が生成していた独自形式で、現在はコミュニティ(The Anansi Project)が
///   スキーマを引き継いで公開している。
/// - **XSDとして公開されている最新版はv2.0**(v2.1は草案で、ドキュメントのみでXSDファイルは
///   存在しない)。そのため、このアプリが書き出すのはv2.0に準拠した内容とし、プロパティも
///   v2.0のXSDの`<xs:sequence>`と**同じ順序**で並べてある(ComicInfoXML.makeDocumentは
///   この順序でそのまま書き出す。要素順を守らない実装も多いが、XSD検証を通す以上は
///   順序を守っておくほうが安全側)。
/// - v2.1草案で追加された`Translator` / `Tags` / `StoryArcNumber` / `GTIN`は、対応する情報を
///   qooViewerが持たないため扱わない。将来DBに項目が増えたら、v2.0の各要素の後ろに
///   草案が定める位置(Editorの後 / Genreの後 / StoryArcの後 / 末尾)で足せばよい。
///
/// 各文字列プロパティは「書かれていなければ空文字」、数値は「書かれていなければnil」で統一する
/// (SourceBookMetadataと同じ方針)。書き出し側は空文字/nilの要素そのものを出力しない
/// — XSDは全要素をminOccurs="0"にしており、空要素を並べるより省略するほうが読み手に優しい
/// (Komgaは空文字を「値がある」と解釈してシリーズ名を空にしてしまうことがある)。
///
/// nonisolated: ComicInfoXML(生成・解析)とCbzExporter(どちらもメインアクター外)から使うため
/// (詳細はServices/ArchiveReading.swift冒頭のコメント参照)。
nonisolated struct ComicInfo: Equatable, Sendable {
    // MARK: - 書誌(v2.0 XSDの順序)

    /// その巻/号自身のタイトル。シリーズ名はSeriesのほうに入れる。
    var title: String = ""
    var series: String = ""
    /// シリーズ内での位置。**xs:stringのため数値である必要は無い**
    /// (EPUBのgroup-positionが数値必須なのとは異なり、「上」「下」もそのまま書ける)。
    /// Komgaはこれを「シリーズ内の巻/号の位置」として素直に扱う。
    var number: String = ""
    /// シリーズの総巻数/総号数。
    var count: Int?
    /// **巻数ではない。** ComicRack/Komgaの語彙では「同じシリーズ名の何度目の刊行か」を表す
    /// 番号または年(例: `Batman (2016)`)で、Komgaはこれをシリーズ名へ`<Series> (<Volume>)`の形で
    /// 連結する。一方Kavitaは「巻」として扱うため、日本の単行本の巻数をここに書くかどうかは
    /// 利用者が使うサーバーによって正解が変わる(CBZ出力ウインドウの「Volumeにも書き出す」
    /// オプション参照)。
    var volume: Int?
    var alternateSeries: String = ""
    var alternateNumber: String = ""
    var alternateCount: Int?
    var summary: String = ""
    var notes: String = ""
    var year: Int?
    var month: Int?
    var day: Int?

    // MARK: - クレジット(いずれもカンマ区切りで複数人を書ける)

    var writer: String = ""
    var penciller: String = ""
    var inker: String = ""
    var colorist: String = ""
    var letterer: String = ""
    var coverArtist: String = ""
    var editor: String = ""

    // MARK: - 出版・分類

    var publisher: String = ""
    var imprint: String = ""
    /// カンマ区切り。Komgaはこれを分割してシリーズのジャンルにする。
    var genre: String = ""
    /// **スペース区切り**(カンマではない)。URLに空白が含まれる場合はパーセントエンコードする。
    var web: String = ""
    var pageCount: Int?
    /// BCP 47の言語タグ("ja" / "en" など)。
    var languageISO: String = ""
    /// 判型・提供形態("TBP" / "HC" / "Digital" など)。
    /// Kavitaは特定の値("TPB" / "Omnibus" / "One Shot"など)を「Special」扱いのトリガーに
    /// するため、意味が確実でない限り書かないほうが安全。
    var format: String = ""
    var blackAndWhite: ComicInfoYesNo?
    /// 右開き(日本式)を表せる唯一の項目。`YesAndRightToLeft`でKomgaが右開き表示に切り替える。
    var manga: ComicInfoManga?

    // MARK: - 内容

    var characters: String = ""
    var teams: String = ""
    var locations: String = ""
    var scanInformation: String = ""
    var storyArc: String = ""
    var seriesGroup: String = ""
    /// XSDでは15種類の列挙値に制限されるが、他アプリが書いた値をそのまま保つ用途があるため
    /// 文字列で保持する(qooViewer自身がこの項目を生成することは無い)。
    var ageRating: String = ""
    var pages: [ComicInfoPage] = []
    /// 0.0〜5.0(小数第2位まで)。
    var communityRating: Double?
    var mainCharacterOrTeam: String = ""
    var review: String = ""

    /// 意味のある内容が1つも無いかどうか。書き出し側は、これがtrueならComicInfo.xml自体を
    /// 同梱しない(空の`<ComicInfo/>`を入れても読み手を混乱させるだけのため)。
    var isEmpty: Bool {
        self == ComicInfo()
    }
}

/// XSDの`YesNo`型。
nonisolated enum ComicInfoYesNo: String, Equatable, Sendable, CaseIterable {
    case unknown = "Unknown"
    case no = "No"
    case yes = "Yes"
}

/// XSDの`Manga`型。`yesAndRightToLeft`だけが読み方向(右開き)まで表す。
///
/// 読み取り時に`yes`を「左開き」と解釈してはいけない。ComicRackの語彙では`Yes`は
/// 「漫画である」という意味しか持たず、方向は未指定だからである
/// (ComicInfoResolverは`yesAndRightToLeft`のときだけ読み方向を確定させる)。
nonisolated enum ComicInfoManga: String, Equatable, Sendable, CaseIterable {
    case unknown = "Unknown"
    case no = "No"
    case yes = "Yes"
    case yesAndRightToLeft = "YesAndRightToLeft"
}

/// XSDの`ComicPageInfo`型(`<Pages>`の中の`<Page>`1件)。すべて属性として書かれる。
///
/// Komga/Kavitaはこの要素をほぼ見ない(KomgaはType="FrontCover"/"Deleted"にも未対応)が、
/// ComicRack・YACReaderでは目次(Bookmark)・カバー指定(Type)として実際に機能する。
nonisolated struct ComicInfoPage: Equatable, Sendable {
    /// **0始まり**のページ番号。XSDは`use="required"`とだけ定めていて基点を明記していないが、
    /// ComicRackの出力および実装(ComicTaggerのdisplay_index)はいずれも0始まりで、
    /// アーカイブ内の画像を名前順に並べたときの位置と一致する。
    var image: Int
    /// `FrontCover` / `Story` / `Deleted` など。既定値は`Story`のため、通常ページでは省略する。
    var type: ComicInfoPageType?
    /// **「1枚の画像に見開き2ページ分が入っている」という意味**であり、「見開き表示する2枚」の
    /// ことではない。qooViewerの「単一ページ」指定(見開き表示中でも単独で表示するページ=
    /// 実質的に横長の合成画像)がこれに最も近いため、そこから変換する
    /// (CbzExporterのcomicInfoPagesのコメント参照)。
    var doublePage: Bool?
    /// バイト数。
    var imageSize: Int64?
    var key: String?
    /// **xs:string**(真偽値ではない)。ComicRackはここに入った文字列をしおりの名前として扱う。
    /// qooViewerのブックマーク名をそのまま往復させられる。
    var bookmark: String?
    var imageWidth: Int?
    var imageHeight: Int?
}

/// XSDの`ComicPageType`型。qooViewerが書き出すのは`frontCover`のみだが、他アプリが書いた
/// 値を読み取って保つために全種類を持つ。
nonisolated enum ComicInfoPageType: String, Equatable, Sendable, CaseIterable {
    case frontCover = "FrontCover"
    case innerCover = "InnerCover"
    case roundup = "Roundup"
    case story = "Story"
    case advertisement = "Advertisement"
    case editorial = "Editorial"
    case letters = "Letters"
    case preview = "Preview"
    case backCover = "BackCover"
    case other = "Other"
    case deleted = "Deleted"
}
