import SwiftUI
import Foundation

/// 環境設定ウインドウの「一般」タブ。表示言語・起動時の挙動・ウインドウ/タブの扱い・
/// ライブラリデータ・ウェルカム画面など、アプリ全体に関わる基本設定をまとめる。
/// 画像の描画・表示に関する設定は「描画」タブ(RenderingSettingsView.swift)へ、
/// ページ送り・スライドショー・カーソル自動非表示など閲覧中の挙動に関する設定は「閲覧」タブ
/// (ReadingSettingsView.swift)へ、本を開き直す/Finderやお気に入りから開く際の挙動と
/// 見開き表示中のブックマーク追加先に関する設定は「開く」タブ(OpeningSettingsView.swift)へ、
/// それぞれ分離した(以前はすべてこのタブに含まれていたが、項目が増えて長くなったため
/// 独立させた)。
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
