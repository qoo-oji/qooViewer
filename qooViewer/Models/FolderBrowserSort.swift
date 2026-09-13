import SwiftUI

/// サイドパネル上段(フォルダブラウザ)の並べ替えの「基準」(ユーザー要望)。パネル上部の
/// 並べ替えメニュー(SidePanelView.folderSection)から選び、
/// AppPreferences.folderBrowserSortKeyとしてUserDefaultsへ保存する(次回起動時も引き継ぐ)。
///
/// 対象は上段のフォルダブラウザだけで、下段(本の中身ブラウザ)には効かない。下段が並べるのは
/// 書庫の中のエントリで、サイズ・作成日・変更日を形式によっては素早く揃えて取れない
/// (BookInternalBrowsing参照)ため、対象をファイルシステムを直接見ている上段に限っている。
///
/// フォルダとファイルをグループ分けするかどうかは、この基準とは独立した別の設定
/// (環境設定「一般」タブのSidePanelSortOrder。こちらも上段専用)のままで、ここには
/// 含めない。FolderBrowserSortがその2つを束ねる。
///
/// nonisolated: 実際に並べ替えを行うDirectoryBrowserがnonisolated enum(メインスレッド外の
/// Task.detachedから使う)のため、そこから読める必要がある。プロジェクト既定の
/// 「Default Actor Isolation = MainActor」の対象外にする理由はArchiveReading.swift冒頭の
/// コメント参照。
nonisolated enum FolderBrowserSortKey: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 一覧に表示している名前(Entry.displayName)。従来からの既定。
    case name
    /// ファイルサイズ。フォルダはサイズを持たない扱い(Entry.fileSize参照)。
    case size
    /// Finderの「種類」(Entry.typeDescription)。
    case kind
    case creationDate
    case modificationDate

    var id: String { rawValue }

    /// 並べ替えメニューに出す項目名。「名前」「サイズ」「種類」はページの「情報を見る」
    /// (PageInfoPanelView)と同じ文言をそのまま流用する。日付の2つだけは、Finderの
    /// 並べ替えメニューに合わせて"Date Created"/"Date Modified"という別のキーにしてある
    /// (日本語はどちらも「作成日」「変更日」で同じ)。
    /// AppKitのメニュー項目用(`String(localized:language:)`で引く)。`titleKey`と同じ文字列。
    var titleValue: String.LocalizationValue {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .kind: "Kind"
        case .creationDate: "Date Created"
        case .modificationDate: "Date Modified"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .kind: return "Kind"
        case .creationDate: return "Date Created"
        case .modificationDate: return "Date Modified"
        }
    }
}

/// 並べ替えの向き(昇順/降順)。基準(FolderBrowserSortKey)とは別の設定として持ち、
/// 並べ替えメニューでも区切り線で分けて見せる(Finderの「並べ替え」と同じ構成)。
nonisolated enum FolderBrowserSortDirection: String, CaseIterable, Identifiable, Codable, Hashable {
    case ascending
    case descending

    var id: String { rawValue }

    /// AppKitのメニュー項目用。`titleKey`と同じ文字列。
    var titleValue: String.LocalizationValue {
        switch self {
        case .ascending: "Ascending"
        case .descending: "Descending"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .ascending: return "Ascending"
        case .descending: return "Descending"
        }
    }
}

/// 上段フォルダブラウザの並べ替え設定一式。DirectoryBrowserへ渡す値であると同時に、
/// SwiftUI側が`.onChange(of:)`でこの1つを見るだけで3つの設定の変更をまとめて拾えるように
/// するための束ね(AppPreferences.folderBrowserSort参照)。
nonisolated struct FolderBrowserSort: Equatable, Hashable {
    /// フォルダをまとめて上に置くかどうか(環境設定「一般」タブの「並び順」)。上段・下段の
    /// 共通設定であり、この並べ替えメニューからは変更しない。並べ替えの基準・向きより先に
    /// 効く(降順にしてもフォルダは上のまま。Finderの「フォルダを常に上部に表示」と同じ)。
    var grouping: SidePanelSortOrder
    var key: FolderBrowserSortKey
    var direction: FolderBrowserSortDirection

    /// AppPreferencesをまだ受け取れていない場合に使う既定値。この機能を入れる前の並び
    /// (フォルダが先、名前の昇順)と完全に同じになるようにしてある。
    static let `default` = FolderBrowserSort(grouping: .foldersFirst, key: .name, direction: .ascending)
}

/// `FolderBrowserSort`で並べられる一覧の行。サイドパネルのフォルダブラウザ(DirectoryBrowser.Entry)と
/// ウェルカム画面のファイルブラウザ(FileBrowserEntry)が**同じ比較**で並ぶようにするための口
/// (改善要望7 段階3、2026-09-13)。比較の本体を2つに書き分けると、同じフォルダを2つの画面で
/// 見たときに並びが食い違う。
nonisolated protocol FolderBrowserSortable {
    /// 「フォルダを上に」でフォルダの側へ寄せるか。パッケージ(`.app`など)はFinderと同じく
    /// ファイルの側に置くので、`isDirectory`とは限らない。
    var sortsAsFolder: Bool { get }
    var displayName: String { get }
    var fileSize: Int64? { get }
    var typeDescription: String? { get }
    var creationDate: Date? { get }
    var modificationDate: Date? { get }
    var url: URL { get }
}

nonisolated extension FolderBrowserSort {
    /// 一覧を並べ替える。値はすべて行が持っているので、ディスクには一切触らない。
    func sorted<Row: FolderBrowserSortable>(_ rows: [Row]) -> [Row] {
        rows.sorted { lhs, rhs in
            // グループ分け(フォルダを先に)は基準・向きより先に効かせる。降順にしても
            // フォルダは上のまま ― Finderの「フォルダを常に上部に表示」と同じ挙動。
            if grouping == .foldersFirst, lhs.sortsAsFolder != rhs.sortsAsFolder {
                return lhs.sortsAsFolder
            }
            switch Self.compare(lhs, rhs, key: key) {
            case .orderedAscending: return direction == .ascending
            case .orderedDescending: return direction == .descending
            // compareは必ず名前・パスまで見て決着させるため、ここへは来ない(同じ一覧に
            // 同じパスの項目は現れない)。来た場合も並びが揺れないようfalseで固定する。
            case .orderedSame: return false
            }
        }
    }

    /// 2件の前後関係を、選ばれている基準で決める。値を持たない項目(フォルダのサイズなど)や
    /// 同じ値だった項目は名前で、それも同じなら最後はパスで決着させる。
    ///
    /// 常に全順序(どの2件を比べても必ず前後が決まる)になるようにしてあるため、降順は昇順の
    /// 完全な逆順になり、同じフォルダを開き直しても並びが揺れない。
    private static func compare<Row: FolderBrowserSortable>(
        _ lhs: Row, _ rhs: Row, key: FolderBrowserSortKey
    ) -> ComparisonResult {
        let primary: ComparisonResult
        switch key {
        case .name:
            // 名前そのものが下のタイブレークなので、ここでは何もしない。
            primary = .orderedSame
        case .size:
            primary = compareOptional(lhs.fileSize, rhs.fileSize)
        case .kind:
            primary = compareOptional(lhs.typeDescription, rhs.typeDescription) { $0.localizedStandardCompare($1) }
        case .creationDate:
            primary = compareOptional(lhs.creationDate, rhs.creationDate)
        case .modificationDate:
            primary = compareOptional(lhs.modificationDate, rhs.modificationDate)
        }
        if primary != .orderedSame { return primary }
        // Finderと同じ並び(localizedStandardCompare: 数字は数値として比べ、大文字小文字・
        // 全角半角は区別せず、ロケールの照合順序に従う)。お気に入り・ブックマーク・
        // メタデータ編集など、このアプリの他の「人に見せる一覧」もこの比較で揃えてある
        // (FavoritesStore.sortedBooks等)。
        //
        // この機能を入れる前は`compare(_:options: .numeric)`だった(ロケールを見ず、
        // 大文字始まりの名前がすべて小文字始まりより先に来る)。下段(本の中身ブラウザ、
        // BookInternalBrowsing)と本のページ順(BookLoaderのsortKey)も、後から同じ照合へ
        // 揃えた(compareCanonicalPageOrder参照)。あちらの並びは互いに一致していなければならない。
        let byName = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if byName != .orderedSame { return byName }
        // 表示名が同じことは起こり得る(拡張子を隠す設定、別ボリュームで同じ名前など)。
        // 最後にパスで決着させ、全順序を保証する。
        return lhs.url.path.compare(rhs.url.path)
    }

    /// 値を持たない(nil)側を「小さい」扱いにして比べる。サイズを持たないフォルダや、
    /// 属性を読み取れなかった項目が、昇順では先頭側にまとまる(そのうえで名前順に並ぶ)。
    private static func compareOptional<Value>(
        _ lhs: Value?, _ rhs: Value?, by compare: (Value, Value) -> ComparisonResult
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return compare(lhs, rhs)
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        }
    }

    private static func compareOptional<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult {
        compareOptional(lhs, rhs) { lhs, rhs in
            if lhs < rhs { return .orderedAscending }
            if rhs < lhs { return .orderedDescending }
            return .orderedSame
        }
    }
}
