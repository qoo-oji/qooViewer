import SwiftUI
import UniformTypeIdentifiers

/// 「お気に入りの整理」ウインドウ(要望3)。左側にフォルダツリー、右側に選択中のフォルダの
/// 中身(サブフォルダ + お気に入り)を表示する2ペイン構成。
///
/// - フォルダの作成・リネーム・削除
/// - お気に入りの削除
/// - ドラッグ&ドロップによる、お気に入り/フォルダの別フォルダへの移動
/// - 実体ファイルが見つからないお気に入りのグレー表示
///
/// をここでまとめて行う(メニューバー・ツールバーの一覧では、開く/新しいウインドウで開く/
/// 新しいタブで開くのみに絞っているため、整理系の操作はすべてこのウインドウの役割になる)。
struct FavoritesOrganizerView: View {
    @ObservedObject var favoritesStore: FavoritesStore

    /// nilは「お気に入りの一番上の階層(ルート直下)」を表す。
    @State private var selectedFolder: FavoriteFolder?

    @State private var isShowingNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var newFolderErrorMessage: String?

    @State private var renamingFolder: FavoriteFolder?
    @State private var renameText = ""

    @State private var folderPendingDeletion: FavoriteFolder?
    @State private var bookPendingDeletion: FavoriteBook?

    @State private var isRootTargeted = false

    var body: some View {
        NavigationSplitView {
            List {
                Button {
                    selectedFolder = nil
                } label: {
                    Label("Favorites (Top Level)", systemImage: "star")
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    (selectedFolder == nil || isRootTargeted) ? Color.accentColor.opacity(0.15) : Color.clear
                )
                .onDrop(of: [.text], isTargeted: $isRootTargeted) { providers in
                    handleDrop(providers: providers, targetFolder: nil)
                }

                ForEach(favoritesStore.rootFolders, id: \.id) { folder in
                    OrganizerFolderRow(
                        folder: folder,
                        favoritesStore: favoritesStore,
                        selectedFolder: $selectedFolder,
                        onRename: { folder in
                            renameText = folder.name
                            renamingFolder = folder
                        },
                        onDelete: { folder in folderPendingDeletion = folder },
                        onDrop: { providers, target in handleDrop(providers: providers, targetFolder: target) }
                    )
                }
            }
            .listStyle(.sidebar)
            // サイドバーの空白部分を右クリックしたときにも「新規フォルダ」を作成できるようにする
            // (ユーザーからの指摘: ツールバーのボタンだけでは新規フォルダの作成方法が
            // 分かりづらいため)。SwiftUIではListの各行にcontextMenuが付いていても、行の無い
            // 空白部分をクリックした場合はList自身に付けたcontextMenuが呼ばれる。
            .contextMenu {
                Button("New Folder") {
                    newFolderName = ""
                    isShowingNewFolderPrompt = true
                }
                .disabled(!favoritesStore.canCreateSubfolder(in: selectedFolder))
            }
            // 「新規フォルダ」ボタンをツールバーのアイコンだけに頼らず、サイドバー下部に文字付きの
            // ボタンとして常時表示する(Finderのサイドバーや「メモ」アプリのフォルダ一覧と同様の
            // 見せ方。ツールバーのアイコンのみのボタンだと、何のボタンか分かりづらいという
            // ユーザーからの指摘への対応)。
            .safeAreaInset(edge: .bottom) {
                Button {
                    newFolderName = ""
                    isShowingNewFolderPrompt = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(!favoritesStore.canCreateSubfolder(in: selectedFolder))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Favorites")
            // 以前はここにツールバーの「新規フォルダ」ボタン(ToolbarItem)を置いていたが、
            // .labelStyle(.titleAndIcon)で文字付きにした結果ツールバーに収まりきらず、
            // macOSが自動的に「>>」という隠れた項目を表示するための折りたたみボタンを
            // 追加してしまっていた。サイドバー下部のボタン・空白部分の右クリックメニューで
            // 「新規フォルダ」は既に分かりやすく提供できているため、ツールバーのボタン自体を
            // 削除して「>>」も出ないようにした。
        } detail: {
            List {
                ForEach(favoritesStore.subfolders(of: selectedFolder), id: \.id) { folder in
                    let itemCount = favoritesStore.subfolders(of: folder).count + favoritesStore.books(in: folder).count
                    HStack {
                        Image(systemName: "folder")
                        Text(folder.name)
                        Spacer()
                        Text("\(itemCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { selectedFolder = folder }
                    .contextMenu {
                        Button("Rename") {
                            renameText = folder.name
                            renamingFolder = folder
                        }
                        Button("Delete", role: .destructive) {
                            folderPendingDeletion = folder
                        }
                    }
                    .onDrag { NSItemProvider(object: "favoriteFolder:\(folder.id.uuidString)" as NSString) }
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        handleDrop(providers: providers, targetFolder: folder)
                    }
                }

                ForEach(favoritesStore.books(in: selectedFolder), id: \.id) { favorite in
                    // 実体ファイルが見つからない項目はグレー表示で区別する
                    // (要望3の追加要件。fileExistsはその都度security-scoped resourceへ
                    // 一時的にアクセスして確認するため、件数が多い場合は表示に多少時間が
                    // かかる可能性がある。フォルダを開いたときだけ表示対象を評価するため、
                    // 通常は許容範囲のはず)。
                    let exists = favoritesStore.fileExists(for: favorite)
                    HStack {
                        Image(systemName: "book.closed")
                        Text(favorite.title)
                        if !exists {
                            Spacer()
                            Text("Not Found")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(exists ? .primary : .secondary)
                    .opacity(exists ? 1 : 0.6)
                    .contextMenu {
                        Button("Remove from Favorites", role: .destructive) {
                            bookPendingDeletion = favorite
                        }
                    }
                    .onDrag { NSItemProvider(object: "favoriteBook:\(favorite.id.uuidString)" as NSString) }
                }
            }
            // 詳細ペインの空白部分を右クリックした場合も、現在選択中のフォルダの直下に
            // 新規フォルダを作成できるようにする(サイドバー側の同様のcontextMenuと同じ理由)。
            .contextMenu {
                Button("New Folder") {
                    newFolderName = ""
                    isShowingNewFolderPrompt = true
                }
                .disabled(!favoritesStore.canCreateSubfolder(in: selectedFolder))
            }
            .navigationTitle(selectedFolder?.breadcrumb ?? String(localized: "Favorites (Top Level)"))
        }
        .frame(minWidth: 640, minHeight: 420)
        .alert("New Folder", isPresented: $isShowingNewFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Cannot Create Folder",
            isPresented: Binding(
                get: { newFolderErrorMessage != nil },
                set: { isPresented in if !isPresented { newFolderErrorMessage = nil } }
            )
        ) {
            Button("OK") { newFolderErrorMessage = nil }
        } message: {
            Text(newFolderErrorMessage ?? "")
        }
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { renamingFolder != nil },
                set: { isPresented in if !isPresented { renamingFolder = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let folder = renamingFolder {
                    favoritesStore.rename(folder, to: renameText)
                }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
        .alert(
            "Delete Folder?",
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { isPresented in if !isPresented { folderPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { folderPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let folder = folderPendingDeletion {
                    if selectedFolder?.id == folder.id {
                        selectedFolder = folder.parent
                    }
                    favoritesStore.delete(folder)
                }
                folderPendingDeletion = nil
            }
        } message: {
            Text("This also deletes any subfolders and favorites inside it.")
        }
        .alert(
            "Remove from Favorites?",
            isPresented: Binding(
                get: { bookPendingDeletion != nil },
                set: { isPresented in if !isPresented { bookPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { bookPendingDeletion = nil }
            Button("Remove", role: .destructive) {
                if let favorite = bookPendingDeletion {
                    favoritesStore.delete(favorite)
                }
                bookPendingDeletion = nil
            }
        }
    }

    private func createFolder() {
        switch favoritesStore.createFolder(name: newFolderName, parent: selectedFolder) {
        case .success:
            break
        case .failure(let error):
            newFolderErrorMessage = error.errorDescription
        }
    }

    /// サイドバーのフォルダ行・「お気に入り(ルート直下)」行の両方から呼ぶ、共通のドロップ処理。
    /// ドラッグ側は"favoriteBook:<uuid>"または"favoriteFolder:<uuid>"というプレーンテキストとして
    /// 識別子を渡す(Transferableプロトコルを使った型安全な実装の方が本来望ましいが、
    /// お気に入り/フォルダという2種類のドラッグ元を単純な文字列プレフィックスで区別する
    /// 手軽な方法として、ここではNSItemProvider + テキストで実装している)。
    private func handleDrop(providers: [NSItemProvider], targetFolder: FavoriteFolder?) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let string = reading as? String else { return }
            Task { @MainActor in
                if string.hasPrefix("favoriteBook:"),
                   let uuid = UUID(uuidString: String(string.dropFirst("favoriteBook:".count))),
                   let favorite = favoritesStore.book(withID: uuid) {
                    favoritesStore.move(favorite, to: targetFolder)
                } else if string.hasPrefix("favoriteFolder:"),
                          let uuid = UUID(uuidString: String(string.dropFirst("favoriteFolder:".count))),
                          let folder = favoritesStore.folder(withID: uuid) {
                    _ = favoritesStore.move(folder, to: targetFolder)
                }
            }
        }
        return true
    }
}

/// サイドバーのフォルダ1件分の折りたたみ行。SwiftUIでは`some View`を返す関数は自分自身を
/// 再帰呼び出しできないため、専用のView構造体として実装する(他のファイルの同様の行と同じ理由)。
/// onRename/onDeleteはfolderを引数に取る形にしてあり、再帰的に同じクロージャをそのまま
/// 子階層へ渡しても、それぞれの行が自分自身のfolderを渡して呼び出すため正しく動作する。
private struct OrganizerFolderRow: View {
    let folder: FavoriteFolder
    @ObservedObject var favoritesStore: FavoritesStore
    @Binding var selectedFolder: FavoriteFolder?
    let onRename: (FavoriteFolder) -> Void
    let onDelete: (FavoriteFolder) -> Void
    let onDrop: ([NSItemProvider], FavoriteFolder?) -> Bool

    @State private var isTargeted = false

    var body: some View {
        DisclosureGroup {
            ForEach(favoritesStore.subfolders(of: folder), id: \.id) { child in
                OrganizerFolderRow(
                    folder: child,
                    favoritesStore: favoritesStore,
                    selectedFolder: $selectedFolder,
                    onRename: onRename,
                    onDelete: onDelete,
                    onDrop: onDrop
                )
            }
        } label: {
            Button {
                selectedFolder = folder
            } label: {
                Label(folder.name, systemImage: "folder")
            }
            .buttonStyle(.plain)
            // 右クリックメニューはラベル(このフォルダ自身の行)だけに限定する。以前は
            // DisclosureGroup全体(展開中の子フォルダの表示領域も含む)にcontextMenuを
            // 付けていたため、階層化したフォルダで子フォルダの行を右クリックしても、SwiftUIの
            // ヒットテストの都合で親フォルダ側のcontextMenuが表示されてしまい、「削除」を選ぶと
            // 右クリックした子ではなく親(選択中だったフォルダ)が削除されてしまう不具合があった。
            // ラベル部分だけに絞ることで、子フォルダの行は子フォルダ自身のOrganizerFolderRowが
            // 持つcontextMenu(このコードと同じ構造)が優先されるようになる。
            .contextMenu {
                Button("Rename") { onRename(folder) }
                Button("Delete", role: .destructive) { onDelete(folder) }
            }
        }
        .listRowBackground(
            (selectedFolder?.id == folder.id || isTargeted) ? Color.accentColor.opacity(0.15) : Color.clear
        )
        .onDrag { NSItemProvider(object: "favoriteFolder:\(folder.id.uuidString)" as NSString) }
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            onDrop(providers, folder)
        }
    }
}
