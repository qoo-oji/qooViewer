import SwiftUI
import Foundation

/// 環境設定ウインドウの「一般」タブ。アプリ全体の起動・終了・ファイルを開く挙動に関する設定を
/// まとめる。画像の描画・表示に関する設定は「描画」タブ(RenderingSettingsView.swift)へ、
/// ページ送り・スライドショー・カーソル自動非表示など閲覧中の挙動に関する設定は「閲覧」タブ
/// (ReadingSettingsView.swift)へ、それぞれ分離した(以前はすべてこのタブに含まれていたが、
/// 項目が増えて長くなったため独立させた)。
struct GeneralSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Language") {
                Picker("Display Language", selection: $preferences.displayLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.titleKey).tag(language)
                    }
                }
            }

            Section("Startup") {
                Toggle("Automatically open the last book on launch", isOn: $preferences.launchOpensLastBook)
                Toggle("Start in full screen", isOn: $preferences.launchFullScreen)
            }

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

            Section("Quit") {
                Toggle("Quit qooViewer when all windows are closed", isOn: $preferences.quitWhenLastWindowClosed)
            }

            Section("Tabs") {
                Toggle(
                    "Ask Before Closing a Window with Multiple Tabs",
                    isOn: $preferences.confirmBeforeClosingMultipleTabsWindow
                )
            }

            Section("Library Data") {
                VStack(alignment: .leading) {
                    Text("Number of Books to Keep Data For: ") + Text("\(Int(preferences.maxTrackedBooksCount))")
                    Slider(value: $preferences.maxTrackedBooksCount, in: 50...2000, step: 50)
                }
            }

            // 要望7: ウェルカム画面の「最近開いたファイル」「最近お気に入りに追加したファイル」の
            // 一覧表示は、それぞれ個別にON/OFFできるようにする(既定はON)。
            Section("Welcome Screen") {
                Toggle("Show Recent Files", isOn: $preferences.showRecentFilesOnWelcome)
                Toggle("Show Recent Favorites", isOn: $preferences.showRecentFavoritesOnWelcome)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
