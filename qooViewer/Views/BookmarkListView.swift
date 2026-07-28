import SwiftUI

/// ブックマーク一覧画面。追加/ジャンプ/名前変更/削除ができる。
struct BookmarkListView: View {
    @ObservedObject var viewModel: ViewerViewModel
    @ObservedObject var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var renamingBookmark: Bookmark?
    @State private var renameText = ""

    /// 一覧表示用に並べ替えたブックマーク。viewModel.bookmarks自体はページ番号順を保ったまま
    /// にしてある(ViewerViewModel.jumpToNextBookmark/jumpToPreviousBookmarkが、この配列の
    /// 並びがページ番号順であることに依存しているため。ここで並べ替えるのはあくまで
    /// この一覧画面の見た目だけで、ジャンプ操作の挙動には影響しない)。
    ///
    /// 名前・追加日時(name〜/dateAdded〜)のtitleKeyは、お気に入りの編集画面
    /// (FavoritesOrganizerView)の「Sort By」メニューと完全に同じ文字列にしてある
    /// (BookmarkSortOption参照)。
    private var sortedBookmarks: [Bookmark] {
        switch preferences.bookmarkSortOption {
        case .pageNumberAscending:
            return viewModel.bookmarks.sorted { $0.pageIndex < $1.pageIndex }
        case .pageNumberDescending:
            return viewModel.bookmarks.sorted { $0.pageIndex > $1.pageIndex }
        case .nameAscending:
            return viewModel.bookmarks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return viewModel.bookmarks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .dateAddedAscending:
            return viewModel.bookmarks.sorted { $0.createdAt < $1.createdAt }
        case .dateAddedDescending:
            return viewModel.bookmarks.sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.bookmarks.isEmpty {
                    Text("No bookmarks yet").foregroundStyle(.secondary)
                }
                ForEach(sortedBookmarks) { bookmark in
                    Button {
                        viewModel.jump(to: bookmark)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.name)
                                (Text("Page ") + Text("\(bookmark.pageIndex + 1)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                viewModel.removeBookmark(bookmark)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename") {
                            renameText = bookmark.name
                            renamingBookmark = bookmark
                        }
                        Button("Delete", role: .destructive) {
                            viewModel.removeBookmark(bookmark)
                        }
                    }
                }
            }
            // 並べ替え基準を切り替えるコントロール。お気に入りの整理画面(FavoritesOrganizerView)の
            // 「Sort By」メニューと同じ見た目・同じ文言にしてある(ツールバーへ足すとスペースが
            // 厳しく折りたたみが発生しやすいため、同じくsafeAreaInsetでリスト上部に常時表示する)。
            .safeAreaInset(edge: .top) {
                HStack {
                    Spacer()
                    Picker(selection: $preferences.bookmarkSortOption) {
                        ForEach(BookmarkSortOption.allCases) { option in
                            Label {
                                Text(option.titleKey)
                            } icon: {
                                Image(systemName: option.systemImage)
                            }
                            .tag(option)
                        }
                    } label: {
                        Label("Sort By", systemImage: "arrow.up.arrow.down")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .navigationTitle("Bookmarks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.addBookmark()
                    } label: {
                        Label("Add Current Page", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 340, minHeight: 380)
        .alert(
            "Rename Bookmark",
            isPresented: Binding(
                get: { renamingBookmark != nil },
                set: { isPresented in if !isPresented { renamingBookmark = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let bookmark = renamingBookmark {
                    viewModel.renameBookmark(bookmark, to: renameText)
                }
                renamingBookmark = nil
            }
            Button("Cancel", role: .cancel) {
                renamingBookmark = nil
            }
        }
    }
}
