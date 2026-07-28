import SwiftUI

/// メニューバーの「お気に入り」メニュー、およびツールバーの「お気に入り一覧」メニューの両方から
/// 共通で使う、階層サブメニューのコンテンツ。
///
/// フォルダはそのままネストしたMenu(サブメニュー)として、お気に入り登録された本はクリックで
/// 開くだけの単純な項目として表示する(要望4。ドラッグ&ドロップ・右クリックでの操作はここでは
/// 行わない。フォルダの作成・削除・移動・並べ替えは「お気に入りの編集」ウインドウ
/// (FavoritesOrganizerView)側の役割)。
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
        if favoritesStore.rootFolders.isEmpty && favoritesStore.rootBooks.isEmpty {
            Text("(No Favorites)")
        } else {
            ForEach(favoritesStore.rootFolders, id: \.id) { folder in
                FavoriteFolderMenu(
                    folder: folder,
                    favoritesStore: favoritesStore,
                    onOpen: onOpen
                )
            }
            ForEach(favoritesStore.rootBooks, id: \.id) { favorite in
                FavoriteBookMenuItem(favorite: favorite, onOpen: onOpen)
            }
        }
    }
}

private struct FavoriteFolderMenu: View {
    let folder: FavoriteFolder
    @ObservedObject var favoritesStore: FavoritesStore
    let onOpen: (FavoriteBook) -> Void

    var body: some View {
        Menu(folder.name) {
            let subfolders = favoritesStore.subfolders(of: folder)
            let books = favoritesStore.books(in: folder)

            if subfolders.isEmpty && books.isEmpty {
                Text("(Empty)")
            }

            ForEach(subfolders, id: \.id) { child in
                FavoriteFolderMenu(
                    folder: child,
                    favoritesStore: favoritesStore,
                    onOpen: onOpen
                )
            }
            ForEach(books, id: \.id) { favorite in
                FavoriteBookMenuItem(favorite: favorite, onOpen: onOpen)
            }
        }
    }
}

private struct FavoriteBookMenuItem: View {
    let favorite: FavoriteBook
    let onOpen: (FavoriteBook) -> Void

    var body: some View {
        Button(favorite.title) { onOpen(favorite) }
    }
}
