import SwiftUI

/// メニューバーの「お気に入り」メニュー、およびツールバーの「お気に入り一覧」メニューの両方から
/// 共通で使う、階層サブメニューのコンテンツ。
///
/// フォルダはそのままネストしたMenu(サブメニュー)として、お気に入り登録された本はクリックで
/// 開くだけの単純な項目として表示する(要望4。ドラッグ&ドロップ・右クリックでの操作はここでは
/// 行わない。フォルダの作成・削除・移動・並べ替えは「お気に入りの編集」ウインドウ
/// (FavoritesOrganizerView)側の役割)。
///
/// 表示順はFavoritesStore.entries(in:)がまとめて決めるので、ここでは結果をそのままswitchして
/// 描画するだけでよい(フォルダ/お気に入りをどちらを先に表示するか・名前や追加日時のどちらで
/// 並べるかは、すべてFavoritesStore側の設定(sortOption/foldersAlwaysOnTop)に従う)。
///
/// 開く際に「そのまま開く/新しいウインドウ/新しいタブ」のどれにするかは、以前はお気に入りごとに
/// サブメニューから毎回選ぶ形式だったが、Finderから開いたときの環境設定(finderOpenBehavior)と
/// 同じ考え方で、環境設定「お気に入りを開くとき」(favoriteOpenBehavior)1箇所に統一した。
/// そのため呼び出し側(onOpen)は1つのクロージャだけを渡せばよく、実際にどう開くかの判定は
/// 呼び出し元(QooViewerApp.swift/ViewerView.swiftのopenFavoriteAccordingToPreference)で行う。
///
/// SwiftUIでは`some View`を返す関数は自分自身を再帰呼び出しできないため、フォルダの階層表示は
/// 専用のView構造体(FavoriteFolderMenu)として実装している(FavoriteFolderPickerView.swiftの
/// FolderTreeRowと同じ理由・同じ回避策)。
struct FavoritesMenuContent: View {
    @ObservedObject var favoritesStore: FavoritesStore
    let onOpen: (FavoriteBook) -> Void

    var body: some View {
        let entries = favoritesStore.entries(in: nil)
        if entries.isEmpty {
            Text("(No Favorites)")
        } else {
            ForEach(entries) { entry in
                FavoriteEntryMenuItem(entry: entry, favoritesStore: favoritesStore, onOpen: onOpen)
            }
        }
    }
}

/// FavoriteListEntry1件分の表示を、フォルダ/お気に入りそれぞれに応じて出し分ける。
private struct FavoriteEntryMenuItem: View {
    let entry: FavoriteListEntry
    @ObservedObject var favoritesStore: FavoritesStore
    let onOpen: (FavoriteBook) -> Void

    var body: some View {
        switch entry {
        case .folder(let folder):
            FavoriteFolderMenu(folder: folder, favoritesStore: favoritesStore, onOpen: onOpen)
        case .book(let favorite):
            FavoriteBookMenuItem(favorite: favorite, onOpen: onOpen)
        }
    }
}

private struct FavoriteFolderMenu: View {
    let folder: FavoriteFolder
    @ObservedObject var favoritesStore: FavoritesStore
    let onOpen: (FavoriteBook) -> Void

    var body: some View {
        Menu(folder.name) {
            let entries = favoritesStore.entries(in: folder)
            if entries.isEmpty {
                Text("(Empty)")
            }
            ForEach(entries) { entry in
                FavoriteEntryMenuItem(entry: entry, favoritesStore: favoritesStore, onOpen: onOpen)
            }
        }
    }
}

private struct FavoriteBookMenuItem: View {
    let favorite: FavoriteBook
    let onOpen: (FavoriteBook) -> Void

    var body: some View {
        // ネイティブのNSMenuItemに変換されるため、FormatBadgeView(カスタムView)は表示できない。
        // 代わりにプレーンテキストの括弧書きで拡張子を示す(同名のcbz/epubが並んだときの
        // 見分けがつかない不具合への対応。FormatBadgeView.plainTextSuffix参照)。
        Button(favorite.title + FormatBadgeView.plainTextSuffix(forBookID: favorite.bookID)) {
            onOpen(favorite)
        }
    }
}
