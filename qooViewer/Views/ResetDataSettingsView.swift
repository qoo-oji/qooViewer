import SwiftUI
import SwiftData
import AppKit

/// 環境設定ウインドウの「リセット」タブ。
///
/// お気に入り(FavoriteFolder/FavoriteBook)・ブックマーク(Bookmark)・読書履歴
/// (BookReadingState、本ごとの最後に読んだページ・表示設定)は、すべて同じ1つのSwiftData
/// ストアに保存されている。将来、アプリのバージョンアップ等でこのストアのスキーマが互換性を
/// 失った場合(実際に一度、FavoriteBook/FavoriteFolderへupdatedAtを追加した際、この種の
/// 移行エラーでアプリごと起動できなくなったことがある。QooViewerApp.modelContainerの
/// コメント参照)、通常の削除操作(お気に入り/ブックマークの個別削除ボタンなど)にはそもそも
/// 到達できない。そうした事態に備え、ここから手動ですべてのお気に入り・ブックマーク・
/// 読書履歴を強制的に削除し、まっさらな状態からやり直せるようにする(ユーザーからの要望)。
///
/// 非常に強力な(元に戻せない)操作のため、
/// - 実行はこの専用タブからのみ行える(他のどの画面にもボタンを置いていない)
/// - 実行前に内容を明記した確認アラートを必ず挟む(「間違ってクリックした場合に備えて」)
/// - 実行後は完了を知らせるアラートを挟んだ上でアプリを終了する(開いている本の
///   ViewerViewModelが、削除済みのBookReadingState/Bookmarkを参照し続けたまま動作してしまう
///   ことを避けるため。SwiftDataでは削除済みのモデルオブジェクトへの書き込みは未定義動作に
///   なりうる。次回起動時にはまっさらな状態から始まる)
/// という3点を徹底している。
struct ResetDataSettingsView: View {
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @Environment(\.modelContext) private var modelContext

    @State private var isShowingConfirmation = false
    @State private var isShowingCompletion = false

    var body: some View {
        Form {
            Section {
                Text(
                    "If your favorites, bookmarks, or reading history ever become corrupted or fail to load (for example, after an app update), use this to permanently delete all of it and start fresh."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    isShowingConfirmation = true
                } label: {
                    Label("Reset All Favorites, Bookmarks & Reading History…", systemImage: "trash")
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("This cannot be undone. qooViewer will quit immediately afterward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        // 「間違ってクリックした場合に備えて」の確認アラート。既存の「Delete Folder?」等と
        // 同じ、ごく普通のCancel/Delete形式(要望どおり、文字入力による二重確認などは行わない)。
        .alert(
            "Reset All Favorites, Bookmarks & Reading History?",
            isPresented: $isShowingConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                performReset()
            }
        } message: {
            Text(
                "This permanently deletes every favorite, favorite folder, bookmark, and saved reading position (last page, display settings) for every book. This cannot be undone, and qooViewer will quit immediately afterward."
            )
        }
        // 削除はすでに完了しているため、ここでの選択肢は「Quit Now」の1つだけにしてある
        // (「キャンセルして使い続ける」という選択肢を出すと、削除済みのモデルを参照したままの
        // 状態でアプリを使い続けられるかのように誤解させてしまうため)。
        .alert("Reset Complete", isPresented: $isShowingCompletion) {
            Button("Quit Now") {
                NSApp.terminate(nil)
            }
        } message: {
            Text("All favorites, bookmarks, and reading history have been deleted. qooViewer will now quit — please reopen it.")
        }
    }

    private func performReset() {
        favoritesStore.deleteAllFavorites()
        bookmarkStore.deleteAllBookmarks()
        // 読書履歴(BookReadingState)専用のストアクラスは無いため、ここで直接操作する。
        try? modelContext.delete(model: BookReadingState.self)
        try? modelContext.save()
        isShowingCompletion = true
    }
}
