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

            // ユーザー報告: Finderの表示順と本のページ順が食い違う名前のパターンがある
            // (先頭のアンダースコア、"-"と"_"の混在、大文字小文字の混在)。既定をFinderと
            // 同じ照合に変え、従来の並びに慣れている場合のためにOFFを残した
            // (AppPreferences.usesFinderSortOrder / comparePageOrder参照)。
            // 切り替えても、レイアウトを設定した本は当時の並びのまま残る(見開きの組み合わせを
            // 守るため。LayoutStore.pinPageOrderIfNeeded参照)。以前はここに「まとめて新しい
            // 並びに合わせるか」を尋ねる確認ダイアログがあったが、削除した ―― 合わせても
            // 見開きの組み合わせが崩れて自動レイアウトのやり直しになるだけで、正解が
            // 「そのまま」に決まっている質問だったうえ、対象の列挙も原理的に不完全だった
            // (一度も開いていない本のピン留めは初回オープン時に行われるため、切り替えの
            // 時点では見つけられない)。合わせたい本は、編集ウインドウの「ページ順を
            // 初期化する」で1冊ずつ合わせられる(ヘルプ文言で案内している)。
            Section {
                SettingsToggle(
                    "Match Finder's Sort Order",
                    isOn: $preferences.usesFinderSortOrder,
                    help: "Sorts by name the way Finder does: digits compare as numbers, and letter case and symbols follow the system's collation. When off — the default — names are compared by character code instead, as in earlier versions, so every name starting with an uppercase letter comes before every name starting with a lowercase one. Open books and lists reorder right away. Books you have given a layout keep the order that layout was made for, because which pages pair into a spread depends on it; to make such a book follow the new order, use Reset Page Order in the Bookmarks & Layout window."
                )
            } header: {
                Text("Page Order")
            }

            Section {
                SettingsToggle(
                    "Enable Side Panel",
                    isOn: $preferences.sidePanelFeatureEnabled,
                    help: "Shows a panel for browsing folders and the current book's contents. When off, the panel and its View menu options are unavailable."
                )
                // サイドパネル機能がOFFの間、以下はどれも効かない設定になる。
                // 「前回読んでいた本を開き直す」をシークレット起動時にグレーアウトするのと
                // 同じ理由(効かない設定を触れるままにすると「壊れている」と受け取られる)で、
                // まとめて無効にする。**この欄へ設定を足すときは、この Group の中へ入れること。**
                Group {
                    SettingsPicker("Panel Position", selection: $preferences.sidePanelPosition)
                    // 「サイドパネルの」はSectionヘッダが言っているので落とし、
                    // 何がダブルクリックになるのかをラベルへ引き上げた。例外だけ吹き出しに残す。
                    SettingsToggle(
                        "Require a Double-Click to Open or Move Into Folders",
                        isOn: $preferences.sidePanelUsesDoubleClick,
                        help: "Navigation buttons such as Back, Forward, and Up are unaffected."
                    )
                    SettingsPicker("Sort Order", selection: $preferences.sidePanelSortOrder)
                    // ユーザー要望: 次/前の本へ移動する順番を、フォルダブラウザの並べ替えに
                    // 合わせたい。並べ替えの基準・向きを変える手段がパネル上部のメニューしか
                    // 無いため、この設定はサイドパネル欄の一部として置き、パネル機能がOFFの
                    // 間は上の3項目ともども無効になる(AppPreferences.siblingBookOrder参照)。
                    SettingsToggle(
                        "Move Between Books in the Browser's Sort Order",
                        isOn: $preferences.siblingNavigationFollowsBrowserSort,
                        help: "Applies to Go to Next/Previous Book and to File ▸ Open File in Same Folder. Folder books and file books are then visited in the order shown in the panel, instead of separately. When off, books follow name order."
                    )
                }
                .disabled(!preferences.sidePanelFeatureEnabled)
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
