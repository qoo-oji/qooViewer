import SwiftUI
import Foundation

/// 環境設定ウインドウの「一般」タブ。表示言語・起動時の挙動・ウインドウ/タブの扱い・
/// ライブラリデータ・ウェルカム画面など、アプリ全体に関わる基本設定をまとめる。
///
/// ラベルは短い名詞句/動詞句に統一し、条件や副作用の説明は caption に降ろしてある
/// (SettingsControls.swift の設計方針を参照)。
struct GeneralSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsTabContainer {
            Section {
                SettingsPicker("Display Language", selection: $preferences.displayLanguage)
            } header: {
                Text("Language")
            }

            Section {
                SettingsToggle(
                    "Open the Last Book",
                    isOn: $preferences.launchOpensLastBook,
                    caption: "Reopens the book you were reading when qooViewer last quit."
                )
                SettingsToggle("Start in Full Screen", isOn: $preferences.launchFullScreen)
            } header: {
                Text("On Launch")
            }

            Section {
                SettingsToggle(
                    "Quit When the Last Window Closes",
                    isOn: $preferences.quitWhenLastWindowClosed
                )
                SettingsToggle(
                    "Confirm Before Closing",
                    isOn: $preferences.confirmBeforeClosingMultipleTabsWindow,
                    caption: "Asks for confirmation when closing a window that has more than one tab."
                )
            } header: {
                Text("Windows & Tabs")
            }

            Section {
                SettingsSlider(
                    "Books to Keep Data For",
                    value: $preferences.maxTrackedBooksCount,
                    in: 50...2000,
                    step: 50,
                    caption: "Reading positions, layouts, and bookmarks are kept for this many books. The least recently opened are discarded first."
                ) { value in
                    "\(Int(value))"
                }
            } header: {
                Text("Library Data")
            }

            // 要望7: ウェルカム画面の「最近開いたファイル」「最近お気に入りに追加したファイル」の
            // 一覧表示は、それぞれ個別にON/OFFできるようにする(既定はON)。
            Section {
                SettingsToggle("Show Recent Files", isOn: $preferences.showRecentFilesOnWelcome)
                SettingsToggle("Show Recent Favorites", isOn: $preferences.showRecentFavoritesOnWelcome)
            } header: {
                Text("Welcome Screen")
            }

            Section {
                SettingsToggle(
                    "Enable Side Panel",
                    isOn: $preferences.sidePanelFeatureEnabled,
                    caption: "Shows a panel for browsing folders and the current book's contents. When off, the panel and its View menu options are unavailable."
                )
                SettingsToggle(
                    "Require Double-Click to Open or Navigate",
                    isOn: $preferences.sidePanelUsesDoubleClick,
                    caption: "Applies to opening files and moving into folders in the side panel. Navigation buttons are unaffected."
                )
                SettingsPicker("Sort Order", selection: $preferences.sidePanelSortOrder)
            } header: {
                Text("Side Panel")
            }
        }
    }
}
