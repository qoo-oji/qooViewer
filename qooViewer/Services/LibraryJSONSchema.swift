import Foundation

/// JSON入出力(設計コンセプト6節)のファイル形式。お気に入り・ブックマーク・ページレイアウト設定を
/// 1つのファイルにまとめて書き出し/読み込みする。3つのトップレベルキーはすべてOptionalで、
/// エクスポート時にチェックを外した種類は書き出さない(キー自体が無い)。インポート側はキーが
/// 存在する種類だけを「このファイルに含まれている」として扱い、含まれていない種類の設定は
/// 一切変更しない。
///
/// ComicInfo.xmlとの相互運用は対象外(設計コンセプト6節)。あくまでqooViewer自身が書き出し、
/// qooViewer自身が読み込むための独自形式。
struct QooLibraryExportFile: Codable {
    /// 将来フォーマットを変更する場合の目印。formatVersion 1は辞書形式(bookID文字列をキーとする
    /// [String: ...])だったが、formatVersion 2でファイルノード識別子(iノード番号)を含められる
    /// よう配列形式に変更した(ユーザー要望。後方互換性は必須ではないため、1のファイルを
    /// 読み込む処理は用意していない)。
    ///
    /// formatVersion 3で、書誌メタデータ(metadata)と、メタデータ推測用のフォーマット定義
    /// (metadataFormats)を追加した。どちらもOptionalのため、2で書き出したファイルもそのまま
    /// 読める(該当キーが無い=そのカテゴリは含まれていない、という既存の扱いがそのまま働く)。
    ///
    /// formatVersion 4で、コレクション(libraries)を追加した(改善要望5)。これもOptionalなので、
    /// 2・3で書き出したファイルは`libraries == nil`= 「このファイルにコレクションは含まれて
    /// いない」として今までどおり読める。
    ///
    /// formatVersion 5(2026-09-21)で、ファイル名からメタデータを作る処理を qooMeta へ置き換えた。
    /// - メタデータの行に qooMeta の欄(著者の並び・ジャンル・イベント・原作・情報・並べ替え用の巻数)を足した
    ///   (どれも Optional。4 以前のファイルと qooMeta の書き出し(formatVersion 4 の形)はそのまま読める)。
    /// - 規則は `metadataRules`(qooMeta の rules-bundle)で書く。`metadataFormats`(以前の 3 種の正規表現)は
    ///   **読むだけ**: ファイル名フォーマットを利用者のルールセット「qooViewer(以前の設定)」として取り込む。
    var formatVersion: Int = 5
    var favorites: ExportedFavorites?
    var bookmarks: [ExportedBookmarkEntry]?
    var layouts: [ExportedBookLayoutEntry]?
    /// 本ごとに登録された書誌メタデータ(著者・タイトル・シリーズ・巻数)。
    var metadata: [ExportedBookMetadataEntry]?
    /// メタデータをファイル名から推測するためのフォーマット定義(本ごとではなくアプリ全体の設定)。
    /// ユーザー選択により、別のマシンへ移行する際に自分で育てたフォーマットも一緒に運べるよう、
    /// レコードとは別のカテゴリとしてこのファイルに含められるようにしてある。
    ///
    /// 2026-09-21 から書かない(formatVersion 5 の説明)。以前のファイルを読むためだけに残してある。
    var metadataFormats: ExportedMetadataFormats?
    /// ファイル名からメタデータを作る規則(qooMeta の rules-bundle。同梱の既定値との差分)を、JSON の文字列のまま持つ。
    /// 規則を既定から変えていなければ書かない(アプリ全体の設定。`metadataFormats` の後継)。
    var metadataRules: String?
    /// ライブラリ → コレクション → 本(改善要望5)。カバー画像は含めない
    /// (取り込んだ先で抽出し直す。CollectionCoverExtractor.refill参照)。
    var libraries: [ExportedLibrary]?
}

// MARK: - コレクション

/// 1つのライブラリと、その中のコレクション。お気に入り(ExportedFavorites)と違って階層が
/// 2段で固定なので、フラットな配列 + 親idではなく素直な入れ子で持つ。
struct ExportedLibrary: Codable {
    var name: String
    /// カバーの縦横比(CoverAspectRatio.rawValue)。この2つはどちらもOptionalで、
    /// 無ければ取り込み側の既定(2:3 / 中央)のまま ―― これらを足す前に書き出したJSONも
    /// そのまま読めるようにしてある(formatVersionは据え置き)。
    var coverAspectRatio: String?
    /// 比が合わないときに残す位置(CoverCropAnchor.rawValue)。
    var coverCropAnchor: String?
    /// 常に先頭に表示するコレクションの**名前**(ユーザー要望 2026-09-10)。指定なしならnil。
    ///
    /// **idではなく名前で書き出す。** 取り込み側ではコレクションを作り直すのでidは一致せず、
    /// 同じライブラリの中で名前は重複しない(CollectionStore.hasCollectionNamed)ので、
    /// 名前が唯一の手がかりになる。名前を頼りに引けなかったときは指定なしのまま。
    ///
    /// Optionalなので、これを足す前に書き出したJSONもそのまま読める(formatVersionは据え置き。
    /// coverAspectRatioと同じ扱い)。
    var pinnedFirstCollection: String?
    /// 常に末尾に表示するコレクションの名前(同上)。
    var pinnedLastCollection: String?
    var collections: [ExportedCollection]
}

struct ExportedCollection: Codable {
    var name: String
    var createdAt: Date
    /// 自動登録フォルダのパス(BookCollection.autoFolderPath。ユーザー要望 2026-09-09)。
    ///
    /// **パスだけを書き出す。** セキュリティスコープ付きブックマークは書き出した端末でしか
    /// 意味を持たない(ExportedCollectionBookと同じ理由)し、そもそもこのアプリでフォルダの
    /// 権限を持っているのはFolderAccessStoreだけで、コレクションはパスしか持っていない。
    ///
    /// 取り込み側では、そのパスに**実際にフォルダがあるときだけ**設定する。無い場所を指した
    /// 設定が残っていても、設定の面にありもしないパスが出るだけで何も起きないため。
    /// フォルダがあっても権限は別途要る(「アクセスを許可」。CollectionAutoFolderRow参照)。
    ///
    /// Optionalなので、これを足す前に書き出したJSONもそのまま読める(formatVersionは据え置き。
    /// ExportedLibrary.coverAspectRatioと同じ扱い)。
    var autoFolderPath: String?
    var books: [ExportedCollectionBook]
}

/// コレクションに入っている本1冊。他のカテゴリと同じく、取り込み時の主たる照合手段は
/// inodeNumber/volumeDeviceNumberで、bookIDは参考情報かつ最終手段
/// (ExportedFavoriteBookのコメント参照)。
///
/// セキュリティスコープ付きブックマーク(bookmarkData)は**含めない**。お気に入りの書き出しも
/// 含めていない ―― ブックマークは書き出した端末の中でしか意味を持たないため、取り込み側で
/// 実体を探して作り直す。
struct ExportedCollectionBook: Codable {
    var bookID: String
    var inodeNumber: Int64?
    var volumeDeviceNumber: Int64?
    /// FileNodeIdentifier.volumeUUID相当。マウント順で変わるデバイス番号と違い、ボリュームを
    /// マウントを跨いで同定できる(FileNodeIdentifierの型コメント参照)。
    ///
    /// Optionalなので、これを足す前に書き出したJSONもそのまま読める(formatVersionは据え置き。
    /// ExportedLibrary.coverAspectRatioと同じ扱い)。取り込み側は、UUIDが無ければ従来どおり
    /// デバイス番号で照合する。
    var volumeUUID: String?
    var title: String
    var addedAt: Date

    var fileNodeIdentifier: FileNodeIdentifier? {
        guard let inodeNumber, let volumeDeviceNumber else { return nil }
        return FileNodeIdentifier(
            inodeNumber: inodeNumber, volumeDeviceNumber: volumeDeviceNumber, volumeUUID: volumeUUID
        )
    }
}

// MARK: - 書誌メタデータ

/// 1冊分の書誌メタデータ。他のカテゴリと同じく、インポート時の主たる照合手段は
/// inodeNumber/volumeDeviceNumberで、bookIDは参考情報かつ最終手段
/// (ExportedFavoriteBookのコメント参照)。
///
/// ブックマーク(pageIndex→pageKey変換が要る)やレイアウトと違い、メタデータは本の中身に
/// 依存しない情報のため、書き出し・読み込みのどちらでも実ファイルを開く必要が無い。
struct ExportedBookMetadataEntry: Codable {
    var bookID: String
    var inodeNumber: Int64?
    var volumeDeviceNumber: Int64?
    /// FileNodeIdentifier.volumeUUID相当。マウント順で変わるデバイス番号と違い、ボリュームを
    /// マウントを跨いで同定できる(FileNodeIdentifierの型コメント参照)。
    ///
    /// Optionalなので、これを足す前に書き出したJSONもそのまま読める(formatVersionは据え置き。
    /// ExportedLibrary.coverAspectRatioと同じ扱い)。取り込み側は、UUIDが無ければ従来どおり
    /// デバイス番号で照合する。
    var volumeUUID: String?
    /// 先頭の著者(2026-09-21 までは著者はこの 1 人だけだった。先頭だけを読む古い版・qooMeta の書き出しと同じ形)。
    var author: String
    var title: String
    var series: String
    var seriesIndex: String
    /// 著者の並び(先頭は `author` と同じ)。1 人以下なら書かない。以下の欄はどれも formatVersion 5 で足した
    /// Optional(無ければ空)。
    var authors: [String]?
    var genre: String?
    var event: String?
    var source: String?
    var info: String?
    /// 巻数の並べ替え用の数(qooMeta の `volumeSort`)。
    var volumeSort: Double?
    /// 欄の版(`BookMetadata.fieldsVersion`)。2026-09-22 に足した(formatVersion は据え置き。Optional なので前のファイルも読める)。
    ///
    /// 足す前は取り込み側が「qooMeta の欄を 1 つでも書いてあるか」で版を推していたが、空の欄は書かないので、題と著者 1 人だけの
    /// (よくある)今の版の行が往復で版 0 に落ち、メタデータの編集ウインドウが「以前の版の欄で登録した」と尋ね直した ――
    /// そこで「ロックを外して解析し直す」を選ぶと、登録した値が捨てられる(監査で指摘)。無いときだけ推す(`importedFieldsVersion`)。
    var fieldsVersion: Int?

    var fileNodeIdentifier: FileNodeIdentifier? {
        guard let inodeNumber, let volumeDeviceNumber else { return nil }
        return FileNodeIdentifier(
            inodeNumber: inodeNumber, volumeDeviceNumber: volumeDeviceNumber, volumeUUID: volumeUUID
        )
    }

    /// qooMeta の欄を 1 つでも書いてある行か(formatVersion 5 で書いた行)。
    var hasQooMetaFields: Bool {
        authors != nil || genre != nil || event != nil || source != nil || info != nil || volumeSort != nil
    }

    /// 取り込んだ行の欄の版。書いてあればそれ、無ければ(2026-09-22 より前の書き出し・qooMeta の書き出し)qooMeta の欄が
    /// あるかで推す。
    var importedFieldsVersion: Int {
        if let fieldsVersion { return max(0, fieldsVersion) }
        return hasQooMetaFields ? BookMetadata.currentFieldsVersion : 0
    }

    /// 行の値(空の欄は空)。
    var values: BookMetadataValues {
        let allAuthors = (authors?.isEmpty == false ? authors! : [author]).filter { !$0.isEmpty }
        return BookMetadataValues(title: title, authors: allAuthors, genre: genre ?? "", event: event ?? "",
                                  source: source ?? "", info: info ?? "", series: series, volume: seriesIndex,
                                  volumeSort: volumeSort)
    }
}

extension ExportedBookMetadataEntry {
    /// DB の行から書き出す形を作る。空の欄は書かない(ファイルを読みやすく、古い版と同じ形に保つ)。
    init(_ metadata: BookMetadata) {
        let values = metadata.values
        func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
        self.init(
            bookID: metadata.bookID, inodeNumber: metadata.inodeNumber,
            volumeDeviceNumber: metadata.volumeDeviceNumber, volumeUUID: metadata.volumeUUID,
            author: values.author, title: values.title, series: values.series, seriesIndex: values.volume,
            authors: values.authors.count > 1 ? values.authors : nil,
            genre: nonEmpty(values.genre), event: nonEmpty(values.event), source: nonEmpty(values.source),
            info: nonEmpty(values.info), volumeSort: values.volumeSort, fieldsVersion: metadata.fieldsVersion
        )
    }
}

/// メタデータ推測用の3種類のフォーマット定義(2026-09-21 まで)。アプリ全体で1組の設定のため、本ごとの配列では
/// なく単一のオブジェクトとして持つ。**今は読むだけ**(`QooLibraryExportFile.metadataFormats`)。
///
/// 各ルールの`id`(UUID)は書き出さない。IDはアプリ内で行を識別するためだけのもので、
/// 取り込み側では新しく振り直せばよく、JSONに残すとファイルが無駄に読みにくくなるため
/// (パターン文字列と、巻数フォーマットの種別だけが意味を持つ情報)。
struct ExportedMetadataFormats: Codable {
    var filenameFormats: [String]
    /// 巻数を取り出すフォーマット(VolumeFormatRuleKind.volumeNumber)。
    var volumeNumberPatterns: [String]
    /// シリーズ名の分離だけを行うフォーマット(VolumeFormatRuleKind.seriesSeparatorOnly)。
    var seriesSeparatorPatterns: [String]
    var exclusionPatterns: [String]
}

// MARK: - お気に入り

/// お気に入りのフォルダ階層・登録した本の一覧。folders/booksどちらもフラットな配列として持ち、
/// 親子関係はparentId/folderId(このファイル内だけで通用する一時的なID文字列)で表す
/// (SwiftDataのUUIDをそのまま流用しているが、インポート時に新しいUUIDへ作り直すため、
/// 「このファイル内での識別子」以上の意味は持たない)。
struct ExportedFavorites: Codable {
    var folders: [ExportedFavoriteFolder]
    var books: [ExportedFavoriteBook]
}

struct ExportedFavoriteFolder: Codable {
    var id: String
    var name: String
    /// ルート直下のフォルダの場合はnil。
    var parentId: String?
}

struct ExportedFavoriteBook: Codable {
    /// MangaBook.id(フォルダ/アーカイブファイルのパス)と同じ形式の文字列。
    ///
    /// ユーザー要望: iノード番号による管理に変更したい。ここのbookIDは、あくまで参考情報
    /// (人が見て分かるように、また下のinodeNumber/volumeDeviceNumberによる照合が失敗した
    /// 場合の最終手段として)残しているだけで、インポート時の主たる照合手段は下の
    /// inodeNumber/volumeDeviceNumberにする(LibraryImportExportService参照)。
    var bookID: String
    /// FileNodeIdentifier.inodeNumber相当。エクスポート時点で取得できていた場合のみ値を持つ。
    var inodeNumber: Int64?
    /// FileNodeIdentifier.volumeDeviceNumber相当。エクスポート時点で取得できていた場合のみ値を持つ。
    var volumeDeviceNumber: Int64?
    /// FileNodeIdentifier.volumeUUID相当。マウント順で変わるデバイス番号と違い、ボリュームを
    /// マウントを跨いで同定できる(FileNodeIdentifierの型コメント参照)。
    ///
    /// Optionalなので、これを足す前に書き出したJSONもそのまま読める(formatVersionは据え置き。
    /// ExportedLibrary.coverAspectRatioと同じ扱い)。取り込み側は、UUIDが無ければ従来どおり
    /// デバイス番号で照合する。
    var volumeUUID: String?
    var title: String
    /// ルート直下(フォルダに属さない)の場合はnil。
    var folderId: String?

    /// inodeNumber/volumeDeviceNumberが両方揃っている場合のみFileNodeIdentifierとして返す。
    var fileNodeIdentifier: FileNodeIdentifier? {
        guard let inodeNumber, let volumeDeviceNumber else { return nil }
        return FileNodeIdentifier(
            inodeNumber: inodeNumber, volumeDeviceNumber: volumeDeviceNumber, volumeUUID: volumeUUID
        )
    }
}

// MARK: - ブックマーク

/// 1件のブックマーク。pageはBookmark.pageIndex(実際の読書順インデックス)ではなく、
/// pageKey(PageRef.sortKey相当、ファイル名/アーカイブ内エントリパス)で表す。
/// アーカイブの中身が差し替わっても対応関係が壊れにくくするための設計(設計コンセプト6.1節)。
struct ExportedBookmark: Codable {
    var page: String
    var name: String
}

/// 1冊分のブックマーク一式。以前は`[String: [ExportedBookmark]]`(キー: bookID)だったが、
/// ユーザー要望によりファイルノード識別子(iノード番号)も持たせられるよう、bookIDを含む
/// 配列要素の形に変更した(ExportedFavoriteBookと同じ考え方)。
struct ExportedBookmarkEntry: Codable {
    /// 参考情報。インポート時の主たる照合手段はinodeNumber/volumeDeviceNumber
    /// (LibraryImportExportService参照)。
    var bookID: String
    var inodeNumber: Int64?
    var volumeDeviceNumber: Int64?
    /// FileNodeIdentifier.volumeUUID相当。マウント順で変わるデバイス番号と違い、ボリュームを
    /// マウントを跨いで同定できる(FileNodeIdentifierの型コメント参照)。
    ///
    /// Optionalなので、これを足す前に書き出したJSONもそのまま読める(formatVersionは据え置き。
    /// ExportedLibrary.coverAspectRatioと同じ扱い)。取り込み側は、UUIDが無ければ従来どおり
    /// デバイス番号で照合する。
    var volumeUUID: String?
    var bookmarks: [ExportedBookmark]

    var fileNodeIdentifier: FileNodeIdentifier? {
        guard let inodeNumber, let volumeDeviceNumber else { return nil }
        return FileNodeIdentifier(
            inodeNumber: inodeNumber, volumeDeviceNumber: volumeDeviceNumber, volumeUUID: volumeUUID
        )
    }
}

// MARK: - ページレイアウト設定

/// 1冊分のレイアウト設定(本全体の設定 + ページ単位の設定)。
struct ExportedBookLayout: Codable {
    /// ReadingDirection.stableID相当の安定した識別子("rightToLeft"/"leftToRight")。未設定ならnil。
    var readingDirection: String?
    /// DisplayMode.stableID相当の安定した識別子("spread"/"single")。未設定ならnil。
    var forcedDisplayMode: String?
    /// ページ順序の補正(pageKeyの並び)。未設定ならnil。
    var pageOrder: [String]?
    /// キー: pageKey。
    var pages: [String: ExportedPageState]?
}

/// 1冊分のレイアウト設定 + bookID。以前は`[String: ExportedBookLayout]`(キー: bookID)だったが、
/// ExportedBookmarkEntryと同じ理由でbookIDを含む配列要素の形に変更した。
struct ExportedBookLayoutEntry: Codable {
    /// 参考情報。インポート時の主たる照合手段はinodeNumber/volumeDeviceNumber
    /// (LibraryImportExportService参照)。
    var bookID: String
    var inodeNumber: Int64?
    var volumeDeviceNumber: Int64?
    /// FileNodeIdentifier.volumeUUID相当。マウント順で変わるデバイス番号と違い、ボリュームを
    /// マウントを跨いで同定できる(FileNodeIdentifierの型コメント参照)。
    ///
    /// Optionalなので、これを足す前に書き出したJSONもそのまま読める(formatVersionは据え置き。
    /// ExportedLibrary.coverAspectRatioと同じ扱い)。取り込み側は、UUIDが無ければ従来どおり
    /// デバイス番号で照合する。
    var volumeUUID: String?
    var layout: ExportedBookLayout

    var fileNodeIdentifier: FileNodeIdentifier? {
        guard let inodeNumber, let volumeDeviceNumber else { return nil }
        return FileNodeIdentifier(
            inodeNumber: inodeNumber, volumeDeviceNumber: volumeDeviceNumber, volumeUUID: volumeUUID
        )
    }
}

struct ExportedPageState: Codable {
    /// PageLayoutState.rawValue("single"/"spreadRight"/"spreadLeft"/"excluded")をそのまま使う
    /// (このenumは明示的なraw値を指定していないため、rawValueは元からcase名そのものであり、
    /// 表示用文字列の変更に影響されない安定した識別子として使える)。
    var state: String
}

// MARK: - 安定した識別子への変換

/// ReadingDirection.rawValueは"Right-to-Left"のような表示用文字列であり、将来UIの表示文言を
/// 変えた場合にJSONの互換性が壊れてしまう。そのため、JSONへの書き出し/読み込みでは
/// rawValueを直接使わず、この安定した識別子を介す。
extension ReadingDirection {
    var stableID: String {
        switch self {
        case .rightToLeft: return "rightToLeft"
        case .leftToRight: return "leftToRight"
        }
    }

    init?(stableID: String) {
        switch stableID {
        case "rightToLeft": self = .rightToLeft
        case "leftToRight": self = .leftToRight
        default: return nil
        }
    }
}

/// DisplayMode.rawValueも同様に表示用文字列("単ページ"/"見開き")のため、専用の識別子を介す。
extension DisplayMode {
    var stableID: String {
        switch self {
        case .single: return "single"
        case .spread: return "spread"
        }
    }

    init?(stableID: String) {
        switch stableID {
        case "single": self = .single
        case "spread": self = .spread
        default: return nil
        }
    }
}
