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
/// (環境設定「一般」タブのSidePanelSortOrder。上段・下段の共通設定)のままで、ここには
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
