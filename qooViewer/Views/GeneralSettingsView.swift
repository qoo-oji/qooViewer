import SwiftUI
import Foundation

/// 環境設定ウインドウの「一般」画面。表示言語・起動時の挙動・ウインドウ/タブの扱い・
/// ライブラリデータ・ウェルカム画面など、アプリ全体に関わる基本設定をまとめる。
///
/// ラベルは短い名詞句/動詞句に統一し、条件や副作用の説明は caption に降ろしてある
/// (SettingsControls.swift の設計方針を参照)。
struct GeneralSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsPaneContainer {
            Section {
                SettingsPicker("Display Language", selection: $preferences.displayLanguage)
            } header: {
                Text("Language")
            }

            Section {
                // 「前回の本を開く」+「前回終了したときに読んでいた本を開き直します」と
                // 二度言っていたのを、ラベル1行に畳んだ(SettingsControls.swift の方針を参照)。
                SettingsToggle(
                    "Reopen the Book You Were Last Reading",
                    isOn: $preferences.launchOpensLastBook
                )
                // シークレットで起動する設定では、そもそも「前回読んでいた本」が記録されず、
                // 記録済みのものも意図的に無視する(ContentView.performLaunchActionsIfNeeded
                // 参照)。効かない設定を触れるままにしておくと「壊れている」と受け取られるため、
                // ここでグレーアウトして理由を吹き出しに置く。
                .disabled(preferences.launchInPrivateMode)
                SettingsToggle("Start in Full Screen", isOn: $preferences.launchFullScreen)
                // ユーザー要望: アプリの通常起動・Finderからのダブルクリック・Dockアイコンへの
                // ドラッグ&ドロップなど、すべての経路で既定でシークレットウインドウとして
                // 開くモードが欲しい。
                SettingsToggle(
                    "Start in Private Mode",
                    isOn: $preferences.launchInPrivateMode,
                    help: "Every book opens in a private window — nothing is recorded: no reading position, bookmarks, favorites, layouts, or history. Use File ▸ New Normal Window when you do want a book to be remembered."
                )
            } header: {
                Text("On Launch")
            }

            Section {
                SettingsToggle(
                    "Quit When the Last Window Closes",
                    isOn: $preferences.quitWhenLastWindowClosed
                )
                SettingsToggle(
                    "Confirm Before Closing a Window with Several Tabs",
                    isOn: $preferences.confirmBeforeClosingMultipleTabsWindow
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
                    // 「データ」が何を指すのかと、あふれたときにどれから消えるのかは
                    // ラベルに入れると長すぎるので、ホバーの吹き出しへ。
                    help: "Reading positions, layouts, and bookmarks are kept for this many books. The least recently opened are discarded first."
                ) { value in
                    "\(Int(value))"
                }
            } header: {
                Text("Library Data")
            }

            // 要望7: ウェルカム画面の「最近開いたファイル」「最近お気に入りに追加したファイル」の
            // 一覧表示は、それぞれ個別にON/OFFできるようにする(既定はON)。
            Section {
                SettingsSlider(
                    "Recent Files to Keep",
                    value: $preferences.recentFilesLimit,
                    in: AppPreferences.recentFilesLimitRange,
                    step: 5,
                    // 「履歴を何件保持するか」はラベルが言っているので落とし、
                    // ラベルからは分からない「どこに出るのか」だけを残す。
                    help: "Shown in the File menu's Open Recent and in the side panel's History mode."
                ) { value in
                    "\(Int(value))"
                }
            } header: {
                Text("History")
            }

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
                    help: "Shows a panel for browsing folders and the current book's contents. When off, the panel and its View menu options are unavailable."
                )
                SettingsPicker("Panel Position", selection: $preferences.sidePanelPosition)
                // 「サイドパネルの」はSectionヘッダが言っているので落とし、
                // 何がダブルクリックになるのかをラベルへ引き上げた。例外だけ吹き出しに残す。
                SettingsToggle(
                    "Require a Double-Click to Open or Move Into Folders",
                    isOn: $preferences.sidePanelUsesDoubleClick,
                    help: "Navigation buttons such as Back, Forward, and Up are unaffected."
                )
                SettingsPicker("Sort Order", selection: $preferences.sidePanelSortOrder)
            } header: {
                Text("Side Panel")
            }

            // 説明文がこの画面だけ長いのは、対象外にしている2つがあるため
            // (AppPreferences.keys(for:)の「対象外にしている設定」参照)。下げると保存済みの
            // データがその場で消える設定なので、「設定を戻す」操作では触らない。
            SettingsResetSection(
                help: "Restores every setting on this page, except Books to Keep Data For and Recent Files to Keep — lowering those would discard data you have already saved. Other pages, and your favorites, bookmarks and reading history, are not affected."
            ) {
                preferences.resetToDefaults(.general)
            }
        }
    }
}
