import SwiftUI

/// ブックマーク一覧画面。追加/ジャンプ/名前変更/削除ができる。
struct BookmarkListView: View {
    @ObservedObject var viewModel: ViewerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var renamingBookmark: Bookmark?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                if viewModel.bookmarks.isEmpty {
                    Text("No bookmarks yet").foregroundStyle(.secondary)
                }
                ForEach(viewModel.bookmarks) { bookmark in
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
