import Foundation
import SwiftData

/// 本ごとの書誌メタデータ(著者・タイトル・シリーズ・巻数)。SwiftDataで永続化する。
/// bookID には MangaBook.id (フォルダ/アーカイブファイルのパス) を使う。
///
/// ユーザー要望: ファイル名から機械的に推測した著者・タイトル・シリーズ・巻数を、
/// 「メタデータの編集」ウインドウで確認・修正したうえでDBに登録できるようにしたい。
/// 登録後は、ファイル名フォーマット・除外文字列・巻数フォーマットをあとから変更しても
/// この行の内容は影響を受けない(機械的な推測結果は、あくまで未登録の本の初期表示にすぎない)。
///
/// この行が存在すること自体が「登録済み」を意味する。個々の欄が空文字であること
/// (例: タイトルだけ登録し著者は空のまま)は許容し、その欄については「登録されていない」
/// ものとして扱う(ツールバーのファイル名表示は、タイトルのみ登録なら「タイトル」、
/// 著者も登録済みなら「[著者] タイトル」を表示する。ViewerViewModel.displayTitle参照)。
///
/// `BookReadingState`と異なり`LibraryDataPruner`による自動削除の対象外とし、無制限に保持する
/// (Bookmark/BookLayoutSettingsと同じ扱い。設計コンセプト10.3節「手間をかけて登録した情報が
/// アプリの都合で勝手に消えることを避ける」という方針に従う)。
///
/// `@Attribute(.unique)`は付けない。Bookmark.id / PageLayoutOverride.compositeKey /
/// BookLayoutSettings.bookIDと同じ理由(詳細はBookmark.swiftのコメント参照): 同じ
/// ModelContextに対して短時間に複数回、一意制約を持つ同じエンティティ型の行を
/// insert()+save()すると、既存の無関係な行が消えることがあるというSwiftData側の不具合が
/// 疑われるため。この機能は「一覧の行を上から順に登録ボタンで登録していく」「JSONインポートで
/// 複数件を1件ずつ取り込む」という、まさにそのパターンに該当する経路を持つ。
/// 一意性自体はBookMetadataStoreがinsertの前に必ず既存行の有無を確認しているためアプリ側で
/// 保証されており、SwiftData側の一意制約に頼る必要が無い。
@Model
final class BookMetadata {
    var bookID: String

    /// 著者名。未登録の欄は空文字(nilではなく空文字で統一する。SwiftDataの
    /// ライトウェイトマイグレーションで扱いやすく、比較・ソートの分岐も減るため)。
    var author: String = ""
    var title: String = ""
    /// シリーズ名(巻数を取り除いたタイトル)。
    var series: String = ""
    /// 巻数。数値ではなく文字列で保持する。Calibreのseries_indexが"10.5"のような小数を
    /// 許容すること、ユーザーが「上」「下」のような非数値を手入力する余地を残したいこと、
    /// および入力途中の状態(空文字)をそのまま持てることが理由
    /// (EPUB/PDFへ書き出す際にのみ、numericSeriesIndexで数値へ変換を試みる)。
    var seriesIndex: String = ""

    /// この本を指すセキュリティスコープ付きブックマーク(Bookmark.bookmarkDataと同じもの)。
    /// 「メタデータの編集」ウインドウ、およびEPUB/PDF出力が、今開いていない本の実ファイルへ
    /// アクセスする必要がある場合に使う。取得できなかった場合はnil。
    var bookmarkData: Data?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// ファイルパスだけでなくファイルノード(iノード番号)でも識別し、同一ボリューム内での
    /// 移動・リネームを引き継げるようにするためのもの(Bookmark/BookLayoutSettingsと同じ仕組み。
    /// BookMetadataStore.reconcileBookIDIfMoved(book:)が本を開き直したときに照合する)。
    var inodeNumber: Int64?
    var volumeDeviceNumber: Int64?

    init(
        bookID: String,
        author: String = "",
        title: String = "",
        series: String = "",
        seriesIndex: String = "",
        bookmarkData: Data? = nil,
        fileNodeIdentifier: FileNodeIdentifier? = nil
    ) {
        self.bookID = bookID
        self.author = author
        self.title = title
        self.series = series
        self.seriesIndex = seriesIndex
        self.bookmarkData = bookmarkData
        self.inodeNumber = fileNodeIdentifier?.inodeNumber
        self.volumeDeviceNumber = fileNodeIdentifier?.volumeDeviceNumber
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }

    /// inodeNumber/volumeDeviceNumberが両方揃っている場合のみFileNodeIdentifierとして返す。
    var fileNodeIdentifier: FileNodeIdentifier? {
        guard let inodeNumber, let volumeDeviceNumber else { return nil }
        return FileNodeIdentifier(inodeNumber: inodeNumber, volumeDeviceNumber: volumeDeviceNumber)
    }

    /// 4つの欄がすべて空かどうか。「登録はされているが中身が何も無い」行を作らないための
    /// 判定に使う(BookMetadataStore.upsertは、すべて空の内容で登録しようとした場合は
    /// 行そのものを削除する)。
    var isEmpty: Bool {
        author.isEmpty && title.isEmpty && series.isEmpty && seriesIndex.isEmpty
    }

    /// EPUBのgroup-position / calibre:series_index、PDFのkeywordsへ書き出すための数値表現。
    /// 数値として解釈できない場合はnil(その場合、書き出し側はseries_indexを省略する)。
    ///
    /// NaN・無限大を弾いているのは、Double(_: String)が"nan"/"inf"という綴りを受け付けるため
    /// (seriesIndexはユーザーが自由に入力できる欄なので、実際に書かれうる)。
    var numericSeriesIndex: Double? {
        let trimmed = seriesIndex.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // 小数点はロケールに依らず"."のみを受け付ける(Calibre/EPUBの仕様に合わせるため、
        // ユーザーのロケールで","が小数点になっている環境でも解釈を変えない)。
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// EPUB/PDFへ実際に書き出す巻数の文字列。数値として解釈できない場合はnil。
    ///
    /// バグ修正: 以前は書き出し側がseriesIndexを生のまま埋めていた。seriesIndexは「上」「下」
    /// のような非数値の手入力を許す欄(上のコメント参照)なので、次の2つの問題が起きていた。
    /// - EPUB3のgroup-positionは数値でなければならず、非数値を書くとepubcheckが弾く
    ///   (dc:languageを"und"で出していてKindle Previewerに弾かれたのと同じ種類の問題)。
    /// - PDFのKeywordsへ`series_index:上`と書いても、読み戻す
    ///   PDFStructureResolver.parseSeriesKeywordsは数字しか受け付けないため往復できない。
    ///
    /// 整数で表せる値は整数の文字列にする(Calibreが書き出す"3.0"を"3"として読み込む
    /// EpubStructureResolver.normalizedSeriesIndexと表記を合わせるため)。
    var exportableSeriesIndex: String? {
        guard let value = numericSeriesIndex else { return nil }
        // Intへ変換して安全な範囲かどうか。1e15を超える巻数は現実に存在しないため、
        // ここに来る時点で入力が壊れているとみなし、書き出さない側に倒す。
        guard abs(value) < 1e15 else { return nil }
        if value == value.rounded() { return String(Int(value)) }
        return String(value)
    }
}

/// 書誌メタデータの追加・変更・削除が、変更した側(BookMetadataStore、または今開いている
/// ViewerViewModel)以外にも通知されるようにするための共通の通知名。
/// Notification.Name.bookmarksDidChange / .layoutDataDidChangeと同じ考え方・同じ理由
/// (「メタデータの編集」ウインドウ・EPUB/PDF出力ウインドウ・今開いている本のビューアが、
/// 同じSwiftDataのモデルを同時に参照しうるため)。
///
/// userInfoの"bookID"(String)には、変更があった本のbookIDを入れる。全件リセットの場合は
/// userInfoを付けずに投げる。
extension Notification.Name {
    static let bookMetadataDidChange = Notification.Name("qooViewer.bookMetadataDidChange")
}
