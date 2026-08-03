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
    /// 将来フォーマットを変更する場合の目印。現状は読み込み側でのバージョン分岐は行っていない。
    var formatVersion: Int = 1
    var favorites: ExportedFavorites?
    /// キー: bookID(MangaBook.id、フォルダ/アーカイブファイルのパス)。
    var bookmarks: [String: [ExportedBookmark]]?
    /// キー: bookID。
    var layouts: [String: ExportedBookLayout]?
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
    var bookID: String
    var title: String
    /// ルート直下(フォルダに属さない)の場合はnil。
    var folderId: String?
}

// MARK: - ブックマーク

/// 1件のブックマーク。pageはBookmark.pageIndex(実際の読書順インデックス)ではなく、
/// pageKey(PageRef.sortKey相当、ファイル名/アーカイブ内エントリパス)で表す。
/// アーカイブの中身が差し替わっても対応関係が壊れにくくするための設計(設計コンセプト6.1節)。
struct ExportedBookmark: Codable {
    var page: String
    var name: String
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
