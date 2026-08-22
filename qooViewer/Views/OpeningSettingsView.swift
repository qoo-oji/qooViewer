import SwiftUI
import Foundation

/// 環境設定ウインドウの「本を開く」画面。
///
/// ■ 情報の並べ方を3層に決め直した
/// 以前はSectionヘッダとPickerのラベルが同じことを二度言っていた
/// (「Finderから開いたとき」/「qooViewerが既に本を表示している場合」)。
/// 二重になっているぶん1行あたりの文字数が増え、それがラベルの折り返しを招いていたので、
/// 役割を次のように分けた。
///
///   1. Sectionヘッダ … **いつの話か**(場面)     例:「Finder・お気に入りから開く」
///   2. 行のラベル     … **何を決めるのか**(短い名詞句) 例:「Finderから」
///   3. caption/footer … **補足**(条件・結果の説明)  例: 選択中の項目の説明
///
/// ■ Finderとお気に入りを1つのSectionに統合した
/// この2つは「既に本を開いている状態で別の本を開くとき、どこに開くか」という
/// まったく同じ問いで、選択肢(FinderOpenBehavior)も共有している。
/// Sectionを分けると同じ説明文を2回書くことになるうえ、
/// 「この2つは揃えるものだ」という関係も見えない。1つにまとめて2行並べると、
/// 片方だけ違う設定にしていることが一目で分かる。
struct OpeningSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsPaneContainer {
            // 以前開いた本を再度開いたときに、どのページから表示するか。
            Section {
                SettingsPicker("Start Page", selection: $preferences.reopenBehavior)
            } header: {
                Text("Reopening a Book")
            }

            // Finderからの起動とお気に入りからの起動は同じ問い・同じ選択肢なので1つにまとめる。
            // お気に入りの挙動は以前「開くたびにサブメニューから毎回選ぶ」形式だったが、
            // Finderから開いたときと同じ考え方でここ1箇所の設定に統一した
            // (FavoriteOpenBehavior自体はFinderOpenBehaviorを再利用)。
            Section {
                SettingsPicker(
                    "From Finder",
                    selection: $preferences.finderOpenBehavior,
                    help: "Applies only when qooViewer already has a book open. From the welcome screen, a book always opens in the current window."
                )
                SettingsPicker(
                    "From Favorites",
                    selection: $preferences.favoriteOpenBehavior,
                    help: "Applies only when qooViewer already has a book open. From the welcome screen, a book always opens in the current window."
                )
            } header: {
                Text("Opening Another Book")
            }

            // ユーザー報告: 見開き表示中にツールバー/お気に入りメニュー/キーボードショートカットから
            // ブックマークを追加すると、クリック位置の情報が無いため常に既定側のページが対象に
            // なる(見開き右、左開きなら見開き左)。この既定側固定と、追加のたびに左右どちらかを
            // 尋ねるダイアログ表示のどちらかを選べるようにした(SpreadBookmarkTargetBehavior参照)。
            Section {
                SettingsPicker(
                    "Target Page",
                    selection: $preferences.spreadBookmarkTargetBehavior,
                    help: "Right-clicking a page always bookmarks the page you clicked, regardless of this setting."
                )
            } header: {
                Text("Bookmarks in Spread View")
            }

            SettingsResetSection(
                help: "Restores every setting on this page. Other pages, and your favorites, bookmarks and reading history, are not affected."
            ) {
                preferences.resetToDefaults(.opening)
            }
        }
    }
}
