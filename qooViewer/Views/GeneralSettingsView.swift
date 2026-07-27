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
        }
        .formStyle(.grouped)
        .padding()
    }
}
