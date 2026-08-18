import SwiftUI
import SwiftData
import AppKit

/// 環境設定ウインドウの「リセット」画面。
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
/// - 実行はこの専用画面からのみ行える(他のどの画面にもボタンを置いていない)
/// - 実行前に内容を明記した確認アラートを必ず挟む(「間違ってクリックした場合に備えて」)
/// - 実行後は完了を知らせるアラートを挟んだ上でアプリを終了する(開いている本の
///   ViewerViewModelが、削除済みのBookReadingState/Bookmarkを参照し続けたまま動作してしまう
///   ことを避けるため。SwiftDataでは削除済みのモデルオブジェクトへの書き込みは未定義動作に
///   なりうる。次回起動時にはまっさらな状態から始まる)
/// という3点を徹底している。
///
/// レイアウト自体は他の画面と同じ `SettingsPaneContainer` に載せてあり、余白・文字サイズは
/// 環境設定ウインドウ全体で揃う(SettingsControls.swift参照)。ただし内容は意図的に
/// この画面だけ「説明 → 破壊的ボタン → 警告footer」という重い構成のままにしてある。
///
/// 以前はperformReset()がModelContext経由で各モデル(FavoriteFolder/FavoriteBook/Bookmark/
/// BookLayoutSettings/PageLayoutOverride/BookReadingState)を個別にdelete()していたが、これだと
/// 「ストア自体のスキーマやリレーションが壊れている状態」を想定していない。実際に、Bundle
/// Identifierが同じ古いビルド(異なるSwiftDataモデル定義を持つ)が同じストアファイルを誤って
/// 開いてしまい、お気に入りの親子関係(FavoriteFolder.parent/children、FavoriteBook.folder)が
/// 壊れたと見られる事例が報告された。行が壊れている・リレーションが繋がらない状態では、
/// ModelContext.fetch()やdelete(model:)自体が意図通りに全件を捉えられるとは限らず、
/// 「壊れているデータだけ消し残る」おそれがある。
///
/// そのため、ここではQooViewerApp.deleteStoreFiles(at:)と同じ方法で、SwiftDataストアの
/// 実ファイル(sqlite本体 + 補助ファイルの-wal/-shm)をFileManagerで直接削除する方式に変更した。
/// ストアの中身がどれだけ壊れていても、ファイルそのものを消してしまえば次回起動時に
/// QooViewerApp.modelContainerが完全にまっさらな状態のストアを新規作成するため、
/// 「壊れているデータも正常なデータも一切合切消える」ことが保証できる。
struct ResetDataSettingsView: View {
    @State private var isShowingConfirmation = false
    @State private var isShowingCompletion = false

    var body: some View {
        SettingsPaneContainer {
            Section {
                // 以前はここが一文だった:
                // 「お気に入り・ブックマーク・レイアウト設定・読書履歴が破損したり読み込めなく
                //   なったりした場合(アプリの更新後など)、これを使ってすべてを完全に削除し、
                //   まっさらな状態からやり直せます。」
                // 中黒で並列要素をつないだ長文は、どこまでが列挙でどこからが述語なのかを
                // 読み手が毎回組み立て直す必要があり、走査しづらい(ユーザーからの指摘)。
                // 「いつ使うのか」を短い1文にし、「何が消えるのか」は列挙として縦に割った。
                // 消えるものが具体的に見えることは、誤操作を防ぐうえでも意味がある。
                // ■ この画面だけ本文を残し、かつ他より強く描く
                // 環境設定の他の画面からは、常時表示の説明文をすべて無くした(認知コストを
                // 下げるため。SettingsControls.swift の方針を参照)。この画面だけは例外で、
                // 「取り消せない削除である」と「何が消えるのか」は読まれないと困る。
                //
                // ところが他の画面と同じ .subheadline + .secondary で書いていたため、
                // **いちばん重要な文が、いちばん薄く小さい**という逆転が起きていた
                // (ユーザーからの指摘)。補足文の見た目のまま重要な文を置いていたのが誤りで、
                // ここは本文サイズ・地の文の濃さで書く。
                VStack(alignment: .leading, spacing: 12) {
                    Text("Use this only when your saved data is damaged and will not load — for example, after an app update. It deletes everything and starts over from a clean state.")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("What gets deleted")
                            .fontWeight(.semibold)

                        SettingsBulletList([
                            "Favorites, including favorite folders",
                            "Bookmarks",
                            "Page layout settings",
                            "Reading history — the last page and display settings for every book",
                        ])
                    }
                }
                .padding(.vertical, 4)

                Button(role: .destructive) {
                    isShowingConfirmation = true
                } label: {
                    Label("Reset All Favorites, Bookmarks, Layouts & Reading History…", systemImage: "trash")
                }
            } header: {
                // 「危険な操作」という文字だけでは、他の画面のSectionヘッダと同じ重さで流し読み
                // されてしまう。赤い警告記号を先頭に付けて、この見出しだけ性質が違うことを示す
                // (ユーザーからの要望)。文字色は他のヘッダと揃えたままにして、記号だけを赤にする。
                Label {
                    Text("Danger Zone")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } footer: {
                // 「元に戻せない」はこの画面でいちばん重要な一文なので、
                // 補足文の見た目(小さい・薄い)ではなく、警告として描く。
                // ヘッダの赤い警告記号と色をそろえてあり、画面の上端と下端の2箇所で
                // 同じ赤が目に入る形になる。
                Label {
                    Text("This cannot be undone. qooViewer will quit immediately afterward.")
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .padding(.top, 2)
            }
        }
        // 「間違ってクリックした場合に備えて」の確認アラート。既存の「Delete Folder?」等と
        // 同じ、ごく普通のCancel/Delete形式(要望どおり、文字入力による二重確認などは行わない)。
        .alert(
            "Reset All Favorites, Bookmarks, Layouts & Reading History?",
            isPresented: $isShowingConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                performReset()
            }
        } message: {
            Text(
                "This permanently deletes every favorite, favorite folder, bookmark, page layout setting, and saved reading position (last page, display settings) for every book. This cannot be undone, and qooViewer will quit immediately afterward."
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
            Text("All favorites, bookmarks, layout settings, and reading history have been deleted. qooViewer will now quit — please reopen it.")
        }
    }

    private func performReset() {
        // ModelContext経由の個別delete()ではなく、ストアの実ファイルを直接削除する
        // (このView自体のコメント参照。壊れているデータも含めて確実に一切合切消すため)。
        // 現在生きているfavoritesStore/bookmarkStore/layoutStore/開いている本のViewerViewModelは
        // このあとすぐアプリを終了させる(下のisShowingCompletionアラート「Quit Now」)ため、
        // 削除後もそれらが古いModelContextを参照し続けることについては考慮不要。
        QooViewerApp.deleteStoreFiles(at: QooViewerApp.modelConfiguration.url)
        isShowingCompletion = true
    }
}
