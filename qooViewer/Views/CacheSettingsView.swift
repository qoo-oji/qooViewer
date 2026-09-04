import SwiftUI

/// 環境設定ウインドウの「キャッシュ」画面。
///
/// qooViewerがメモリとディスクに**溜め込む**もの(読書中のページ画像、ページサムネイル)の
/// 扱いを、ここ1箇所にまとめてある。
///
/// ■ なぜ独立した画面なのか
/// ユーザー報告: 数日使っただけでキャッシュフォルダが数百MBに膨れていて驚いた。
/// サムネイルのディスクキャッシュは、それまで黙って作られ続けていた(ON/OFFの手段も、
/// 上限を知る手段も、いま何MB使っているのかを見る手段も無かった)。
/// 「速くなる代わりにディスクを使う」という取引は、ユーザーが見て決められないと成立しない。
///
/// 「詳細」グループに置いてあるのは、普段は触らなくてよい設定であり、かつ触ると
/// 保存済みのキャッシュがその場で消えるという点で、隣の「フォルダのアクセス権」
/// 「リセット」と性質が揃っているため(`SettingsPane` 参照)。
///
/// ■ 消えるのはキャッシュだけ
/// この画面のどの操作も、お気に入り・ブックマーク・読書履歴には一切触れない。
/// 消えるのは再生成できるサムネイルだけで、失われるのは「次に同じ本を開いたときの速さ」だけ。
/// そのため「リセット」画面のような重い確認は挟まない(あちらは取り消せない**データ**の削除)。
struct CacheSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    /// 環境設定ウインドウが前面にあるか。使用量を測り直すきっかけの1つとして見ている
    /// (usageTaskID参照)。
    @Environment(\.controlActiveState) private var controlActiveState

    /// いまキャッシュが使っているディスク容量。計測が終わるまではnil。
    @State private var usedBytes: Int?
    /// 「今すぐ削除」の実行中(ボタンの二度押しを防ぐ)。
    @State private var isDeleting = false
    /// ページ一覧のキャッシュ(BookPageListCache)の使用量と削除中フラグ(サムネイルと同じ扱い)。
    @State private var pageListBytes: Int?
    @State private var isDeletingPageLists = false
    /// 使用量を測り直させるための合図。削除の直後など、値が変わったはずのタイミングで
    /// 進めると`.task(id:)`が走り直す。
    @State private var usageRefreshToken = 0

    var body: some View {
        SettingsPaneContainer {
            // 読書中のページ画像をメモリに残しておく量。本のウインドウ/タブ1つごとに
            // この上限を持つ(PageLoader.imageCache)。
            Section {
                SettingsSlider(
                    "Page Images Kept in Memory",
                    value: $preferences.pageImageCacheLimitMB,
                    in: AppPreferences.pageImageCacheLimitRangeMB,
                    step: 50,
                    help: "Decoded pages near the one you are reading stay in memory so that turning back is instant. This is the limit per open book. Larger values turn pages faster after going back; smaller values use less memory."
                ) { value in
                    "\(Int(value)) MB"
                }
                // 入れ子の書庫(書庫の中の書庫)を開いたときの置き場。ページ画像と違って
                // 「本を開く速さ」ではなく「章をまたぐときの速さ」に効く設定なので、
                // 同じメモリの話として並べつつ、吹き出しで役割の違いを言い切っておく。
                SettingsSlider(
                    "Nested Archives Kept in Memory",
                    value: $preferences.nestedArchiveMemoryLimitMB,
                    in: AppPreferences.nestedArchiveMemoryLimitRangeMB,
                    step: 32,
                    help: "When a book has other archives inside it, each one is opened only when you reach it, and the most recently used ones are kept here. Larger values move between chapters faster; smaller values use less memory. An archive larger than this is written to a temporary file instead, and how much of that is kept follows this setting too. At 0, a temporary file is always used."
                ) { value in
                    "\(Int(value)) MB"
                }
            } header: {
                Text("Memory")
            }

            // 先読み。どちらも「速くするためにメモリを前もって使う」設定で、上の上限の中に
            // 収まる量を決めるものなので、同じ画面に並べる(ユーザー要望: メモリの使用量に
            // 直結する設定はここに集める)。移す前は「画像の表示」と「外観」にそれぞれあった。
            Section {
                SettingsSlider(
                    "Pages to Preload on Each Side",
                    value: $preferences.prefetchPageCount,
                    in: 0...10,
                    step: 1,
                    help: "Higher values turn pages faster but use more memory."
                ) { value in
                    "\(Int(value))"
                }
                SettingsToggle(
                    "Preload Previews for Visible Thumbnails",
                    isOn: $preferences.preloadThumbnailGridPreviews,
                    help: "In the page list, decodes the preview image of every thumbnail on screen in advance so it appears immediately. Uses more memory and CPU. Has no effect while previews are turned off in Appearance ▸ Page List."
                )
                // プレビューを出さない設定のときは、先読みしても何も起きない(その設定は
                // 「外観」に残っている。理由は吹き出しに書いてある)。
                .disabled(!preferences.showThumbnailHoverPreview)
            } header: {
                Text("Preloading")
            }

            Section {
                SettingsToggle(
                    "Cache Page Thumbnails on Disk",
                    isOn: $preferences.thumbnailDiskCacheEnabled,
                    help: "Reopening a book you have already viewed becomes much faster, especially from an external drive or a network volume. In exchange, qooViewer keeps thumbnail files on your startup disk. Turning this off deletes them right away."
                )
                SettingsSlider(
                    "Maximum Size",
                    value: $preferences.thumbnailDiskCacheLimitMB,
                    in: AppPreferences.thumbnailDiskCacheLimitRangeMB,
                    step: 50,
                    help: "When the cache would grow past this size, the thumbnails you looked at longest ago are deleted first."
                ) { value in
                    "\(Int(value)) MB"
                }
                // OFFのあいだはキャッシュそのものが存在しないので、上限を決めても効き目が無い。
                // 触れるままにしておくと「設定したのに何も起きない」に見えるため、灰色にする
                // (「一般」の“前回の本を開く”をシークレット起動中に無効化するのと同じ扱い)。
                .disabled(!preferences.thumbnailDiskCacheEnabled)
            } header: {
                Text("Page Thumbnails")
            }

            Section {
                // この画面を作った理由そのものが「気づかないうちに数百MB」だったので、
                // 現在の使用量は設定項目より前に置きたいくらい重要な情報。実際の数字を出す。
                // ディスクを使うキャッシュは2つ(サムネイル、ページ一覧)で、どちらも同じ形の1行
                // 「項目名 / 使用量 + 削除ボタン」にする(書き出し先の「フォルダ」行と同じ、
                // 値の右にボタンを置く形。BookExportFormatSettingsView.fixedFolderRow参照)。
                // 説明は常時表示せず、ⓘの吹き出しに置く(SettingsControls.swift冒頭の方針)。
                SettingRow(
                    "Thumbnail cache",
                    help: "Page thumbnails saved on disk, against the maximum size above. Deleting them does not affect your favorites, bookmarks, or reading history; pages are simply decoded again the next time you need them."
                ) {
                    HStack(spacing: 8) {
                        Text(usedBytesDescription)
                            .monospacedDigit()
                        Button("Delete", role: .destructive) {
                            deleteNow()
                        }
                        // 空のときに押せても何も起きない。計測中(nil)は押させない。
                        .disabled(isDeleting || (usedBytes ?? 0) == 0)
                    }
                }
                // ページ一覧・構造・ページ寸法のキャッシュ(BookPageListCache)。サムネイルと違って
                // ON/OFFは無い(上限50MB固定で、古いものから自動で削る)が、ユーザーが自分で消せる
                // 手段と使用量の表示は要る(ユーザー要望: 知らないところでディスクが増えないこと)。
                // 吹き出しの「50 MB」はBookPageListCache.maxTotalBytesと揃えること。
                SettingRow(
                    "Page list cache",
                    help: "The order, names and image sizes of the pages of books you have opened, so that a book opens without scanning its archive again. Kept under 50 MB, oldest first. Deleting it only means the next open of a book scans it again. Nothing is written for books opened in a private window."
                ) {
                    HStack(spacing: 8) {
                        Text(pageListBytesDescription)
                            .monospacedDigit()
                        Button("Delete", role: .destructive) {
                            deletePageListsNow()
                        }
                        .disabled(isDeletingPageLists || (pageListBytes ?? 0) == 0)
                    }
                }
            } header: {
                Text("Disk Usage")
            }

            SettingsResetSection(
                help: "Restores every setting on this page, which turns the thumbnail disk cache off and deletes it. Other pages, and your favorites, bookmarks and reading history, are not affected."
            ) {
                preferences.resetToDefaults(.cache)
            }
        }
        // 画面を開いたとき、設定を変えたとき、削除したときに測り直す。
        .task(id: usageTaskID) {
            await refreshUsage()
        }
    }

    /// 使用量を測り直す条件。
    ///
    /// 設定の変更(トグル・上限)はどちらもキャッシュの中身を変えうる。加えて、この画面を
    /// 開いたままビューアへ戻って本を読み、また戻ってきたときにも測り直したい ―― そのあいだに
    /// 増えているのが普通で、開いた瞬間の数字が貼りついたままだと、この画面が答えるはずの
    /// 「いまどれだけ使っているのか」に答えられなくなる。ウインドウが前面に戻ったことは
    /// controlActiveStateの変化として届く。
    private var usageTaskID: String {
        let settings = "\(preferences.thumbnailDiskCacheEnabled)|\(Int(preferences.thumbnailDiskCacheLimitMB))"
        return "\(settings)|\(controlActiveState)|\(usageRefreshToken)"
    }

    private var usedBytesDescription: String {
        guard let usedBytes else {
            // 測っている最中。空("0 バイト")と紛らわしくならない表示にしておく。
            return "—"
        }
        return Int64(usedBytes).formatted(
            .byteCount(style: .file).locale(preferences.effectiveLocale)
        )
    }

    private var pageListBytesDescription: String {
        guard let pageListBytes else { return "—" }
        return Int64(pageListBytes).formatted(
            .byteCount(style: .file).locale(preferences.effectiveLocale)
        )
    }

    private func refreshUsage() async {
        pageListBytes = await BookPageListCache.shared.totalBytes()
        usedBytes = await ThumbnailDiskCache.shared.totalBytes()
        // トグルや上限の変更による削除・刈り込みは、環境設定とは別のタスクで進んでいる
        // (AppPreferences.applyThumbnailDiskCacheSettings → ThumbnailDiskCache.configure)。
        // どちらが先に終わるかは決まっていないので、一拍おいてもう一度だけ読み直し、
        // 古い数字が画面に残ったままにならないようにする。
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        usedBytes = await ThumbnailDiskCache.shared.totalBytes()
    }

    private func deletePageListsNow() {
        isDeletingPageLists = true
        Task {
            await BookPageListCache.shared.removeAll()
            isDeletingPageLists = false
            usageRefreshToken += 1
        }
    }

    private func deleteNow() {
        isDeleting = true
        Task {
            // removeAll()の完了を待ってから測り直すので、こちらは上のような読み直しは要らない。
            await ThumbnailDiskCache.shared.removeAll()
            isDeleting = false
            usageRefreshToken += 1
        }
    }
}
