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
/// 2026-09-04から、この操作の対象は「フォルダのアクセス権を除く、このアプリがディスクに保存した
/// すべて」になった(ユーザーの指示)。上のストアに加え、2つのディスクキャッシュと
/// UserDefaults(環境設定・割り当て・履歴・ウインドウの位置)も消える。以前はストア・キャッシュ・
/// 履歴だけで、環境設定が残る中途半端な範囲だった(QooViewerApp.pendingFullResetDefaultsKey参照)。
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
    @Environment(\.openWindow) private var openWindow
    /// ボタン幅の実測に使う表示言語。環境設定で切り替わるので、OSのロケールではなくこれを見る
    /// (メタデータの編集ウインドウ・3つの編集ダイアログのフッターと同じ理由・同じ書き方)。
    @Environment(\.locale) private var locale
    /// 「最近開いたファイル」の履歴。この画面では、履歴が空のときに「開いたファイルの履歴の
    /// 削除…」を無効にするためと、performReset()で明示的に消すために参照する。
    /// SwiftDataではなくUserDefaultsに保存されているため、下の「すべて削除」が行う
    /// ストアファイルの削除では**消えない**。
    @EnvironmentObject private var recentFiles: RecentFilesStore
    @State private var isShowingConfirmation = false
    @State private var isShowingCompletion = false

    var body: some View {
        SettingsPaneContainer {
            // ユーザー要望: 検証用に開いただけの本など、DBに残ったままの不要なデータが煩わしい
            // ので、任意の本だけを選んで削除できるようにしたい。あわせて、同じことを履歴に
            // ついてもできるようにしたい(ユーザー要望)。
            //
            // 下の「すべて削除」が、データが壊れて起動すらできない状況のための最後の手段
            // (ストアの実ファイルごと消す)なのに対して、こちらは日常的な掃除。性質が異なるため、
            // 同じ「危険な操作」セクションには入れず、その手前に置く(この操作自体は取り消せない
            // が、対象は選んだぶんだけで、アプリの再起動も伴わない)。
            //
            // 2つは同じ種類の操作なので**1つのセクションにまとめ、文言の形も揃える**
            // (ユーザー指摘: 似た機能なのに名前に統一感が無かった)。どちらも一覧のウインドウを
            // 開くだけで、この画面では何も消えない。
            //
            // 以前は履歴側に「『最近開いたファイル』の履歴を消去…」(全消去)も並べていたが、
            // 新しいウインドウで「すべて選択」→「選択した項目を削除」をすれば同じことができる。
            // 本の側(ウインドウを開くボタン1つだけ)と非対称になるうえ、削除ボタンが2つ並んで
            // 押し間違えやすくなるため、ユーザーの判断で廃止した。全消去そのものは、
            // サイドパネル「履歴」モードのゴミ箱ボタンと、ファイルメニューの
            // 「メニューを消去」に残っている。
            Section {
                // 2つのボタンは幅を揃える(ユーザー指摘: 似た操作が隣り合っているのに、
                // 文言の長さのぶんだけ幅が違って見えていた)。長いほうの文言が省略されずに
                // 収まる幅を実測して両方に与える ―― 3つの編集ダイアログのフッターで
                // 「初期化」「閉じる」の幅を揃えているのと同じ部品・同じやり方。
                Button {
                    openWindow(id: "libraryCleanup")
                } label: {
                    Label("Delete Saved Data…", systemImage: "trash.slash")
                        .frame(width: cleanUpButtonWidth, alignment: .leading)
                }

                Button {
                    openWindow(id: "historyCleanup")
                } label: {
                    Label("Delete History…", systemImage: "clock.arrow.circlepath")
                        .frame(width: cleanUpButtonWidth, alignment: .leading)
                }
                .disabled(recentFiles.entries.isEmpty)
            } header: {
                Text("Clean Up")
            } footer: {
                Text("Each opens a window listing what qooViewer has saved, so you can pick what you no longer need and delete it. The files themselves are never touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                // 何が消えるかは「アクセス権を除くすべて」の1文で言い切る(ユーザーの指示)。
                // 以前は消えるものを箇条書きで列挙していたが、対象が「保存したすべて」になった以上、
                // 列挙は残るものを言うより長くて分かりにくい。残るのはフォルダのアクセス権だけ
                // (QooViewerApp.pendingFullResetDefaultsKeyのコメント参照)。
                Text("Use this only when your saved data is damaged and will not load — for example, after an app update. It deletes all data qooViewer has saved, except folder access permissions.")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)

                Button(role: .destructive) {
                    isShowingConfirmation = true
                } label: {
                    Label("Delete All Data…", systemImage: "trash")
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
        .alert("Delete All Data?", isPresented: $isShowingConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                performReset()
            }
        } message: {
            Text(
                "This deletes all data qooViewer has saved, except folder access permissions. This cannot be undone, and qooViewer will quit immediately afterward."
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
            Text("All data has been deleted. qooViewer will now quit — please reopen it.")
        }
    }

    /// 「整理」セクションの2つのボタンの共通幅。`.frame`を当てるのはボタンではなくラベル
    /// (Labelそのもの)なので、ボタン自身の左右の余白は足さず、アイコンとテキストの間隔ぶん
    /// だけを上乗せする。
    private var cleanUpButtonWidth: CGFloat {
        MetadataButtonWidthEstimator.equalWidth(
            for: [
                String(localized: "Delete Saved Data…", language: locale),
                String(localized: "Delete History…", language: locale)
            ],
            minWidth: 0,
            chrome: Self.labelIconChrome
        )
    }

    /// Labelの先頭に付くSFシンボルと、その右の間隔ぶんの幅。実機のスクリーンショットを
    /// 実測して合わせた値(MetadataButtonWidthEstimator.smallChromeと同じ決め方)。
    /// 小さすぎると、長いほうの文言が「保存データの…」と省略される。
    private static let labelIconChrome: CGFloat = 40

    private func performReset() {
        // ModelContext経由の個別delete()ではなく、ストアの実ファイルを直接削除する
        // (このView自体のコメント参照。壊れているデータも含めて確実に一切合切消すため)。
        //
        // ただし**その場では消さず、終了時に消す**(QooViewerApp.scheduleStoreReset参照。
        // 監査で指摘)。以前はここで即座にファイルを消していたが、ModelContainerはまだ
        // 開いたままで、「Quit Now」を押すまでの間に他のウインドウの読書位置の保存
        // (ViewerViewModel.persistStateの400msデバウンス)や各ストアが同じ接続へ書き込める。
        // 消した直後の書き込みはSQLiteが`-wal`を作り直すため、次回起動時に本体の無い
        // WALだけが残る、という中途半端な状態を作りうる。終了時(applicationWillTerminate)
        // まで遅らせれば、書き込みが起こりうる時間そのものが無くなる。
        // 万一終了前に落ちても、次回起動時にModelContainerを作る前に同じ削除を行う。
        // 対象は「フォルダのアクセス権を除く、このアプリが保存したすべて」: ストアに加えて
        // 2つのディスクキャッシュとUserDefaults(環境設定・割り当て・履歴・ウインドウの位置)。
        // UserDefaultsはストアと同じ理由で終了時に消す(QooViewerApp.pendingFullResetDefaultsKey参照)。
        QooViewerApp.scheduleFullReset()
        // ページサムネイル(ThumbnailDiskCache)とページ一覧(BookPageListCache)の永続
        // キャッシュはその場でも捨てる(終了時にもう一度消える)。完了は待たない(このあと
        // ユーザーが「Quit Now」を押すまでの間に終わればよい)。
        Task { await ThumbnailDiskCache.shared.removeAll() }
        Task { await BookPageListCache.shared.removeAll() }
        // 履歴と「前回開いていた本」は終了時のUserDefaultsの削除で消えるが、その場でも消しておく
        // (「Quit Now」までの間に画面に残っていると、消えていないように見えるため)。
        recentFiles.removeAll()
        LastActiveBookStore.clear()
        isShowingCompletion = true
    }
}
