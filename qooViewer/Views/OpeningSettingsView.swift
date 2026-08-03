import SwiftUI
import Foundation

/// 環境設定ウインドウの「開く」タブ。本を開き直すとき・Finderからブックを開くとき・
/// お気に入りからブックを開くとき、それぞれ既にブックが開いている場合にどう振る舞うかの設定と、
/// 見開き表示中にブックマークを追加したときの対象ページの決め方をまとめる。
/// 以前は「一般」タブに含まれていたが、項目が増えて長くなったため、「開く」動作に関する設定
/// として独立させた(RenderingSettingsView・ReadingSettingsViewの分離と同じ考え方)。
struct OpeningSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Reopening a Book") {
                Picker("When Reopening a Previously Read Book", selection: $preferences.reopenBehavior) {
                    ForEach(ReopenBehavior.allCases) { behavior in
                        Text(behavior.titleKey).tag(behavior)
                    }
                }
            }

            Section("Opening from Finder") {
                Picker(
                    "When qooViewer Already Has a Book Open",
                    selection: $preferences.finderOpenBehavior
                ) {
                    ForEach(FinderOpenBehavior.allCases) { behavior in
                        Text(behavior.titleKey).tag(behavior)
                    }
                }
            }

            // お気に入りを開くときの挙動(開く/新しいタブ/新しいウインドウ)を、以前はお気に入りを
            // 開くたびにサブメニューから毎回選ぶ形式にしていたが、Finderから開いたときと同じ考え方で
            // ここ1箇所の設定に統一した(FavoriteOpenBehavior自体はFinderOpenBehaviorを再利用)。
            Section("Opening a Favorite") {
                Picker(
                    "When qooViewer Already Has a Book Open",
                    selection: $preferences.favoriteOpenBehavior
                ) {
                    ForEach(FinderOpenBehavior.allCases) { behavior in
                        Text(behavior.titleKey).tag(behavior)
                    }
                }
            }

            // ユーザー報告: 見開き表示中にツールバー/お気に入りメニュー/キーボードショートカットから
            // ブックマークを追加すると、クリック位置の情報が無いため常に既定側のページが対象に
            // なる(見開き右、左開きなら見開き左)。この既定側固定と、追加のたびに左右どちらかを
            // 尋ねるダイアログ表示のどちらかを選べるようにした(SpreadBookmarkTargetBehavior参照)。
            Section("Adding Bookmarks in Spread View") {
                Picker(
                    "When Adding a Bookmark from the Toolbar or Favorites Menu",
                    selection: $preferences.spreadBookmarkTargetBehavior
                ) {
                    ForEach(SpreadBookmarkTargetBehavior.allCases) { behavior in
                        Text(behavior.titleKey).tag(behavior)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
