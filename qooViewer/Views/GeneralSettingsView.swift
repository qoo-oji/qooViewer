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
                // ウインドウの中身は選んだ瞬間に切り替わるが、メニューバーとOSが出すダイアログは
                // 次回の起動から(AppLanguage.applyAppleLanguagesOverride参照)。それを吹き出しで言う。
                SettingsPicker(
                    "Display Language",
                    selection: $preferences.displayLanguage,
                    help: "Windows switch right away. The menu bar and system dialogs switch the next time qooViewer starts."
                )
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
                Text("Saved Data")
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
                // 並びは帯の左からと同じ: ファイルブラウザ・スマートライブラリ・ライブラリ(2026-09-22、利用者の指示)。
                // ユーザー要望 2026-09-21。3 つとも OFF にすると、ホームは本棚を足す前のウェルカム画面に戻る
                // (AppPreferences.fileBrowserFeatureEnabled)。
                SettingsToggle(
                    "Enable File Browser",
                    isOn: $preferences.fileBrowserFeatureEnabled,
                    help: "Shows the file browser on the Home screen. When off, the file browser and its items — including Show in File Browser — disappear from Home, the menus and context menus, and the background work that exists only for it stops: Auto Rename and making video thumbnails ahead of time. The top bar shows Open Book… and Open from History in its place. Your favorite locations, Auto Rename rules and thumbnail cache are kept. With Smart Library and Libraries also off, Home shows the original welcome screen: an Open button and your recent books."
                )
                // 2026-09-22、利用者の要望。スマートライブラリの本は自分の対象フォルダの中だけなので、ほかの 2 つとは別に切り替える
                // (AppPreferences.smartLibraryFeatureEnabled)。
                SettingsToggle(
                    "Enable Smart Library",
                    isOn: $preferences.smartLibraryFeatureEnabled,
                    help: "Shows the smart library on the Home screen: the books in the folders you choose, gathered by conditions and grouped by series or author. When off, it disappears from Home and the Home menu, and Edit Metadata no longer looks through its target folders. Your target folders and smart collections are kept."
                )
                // ユーザー要望 2026-09-21。サイドパネルのON/OFF(下の欄)と同じ位置づけ ―― ファイルビューアとしてだけ使う人が、
                // 本棚とそのための裏の仕事を丸ごと止められる。保存データは消さない(AppPreferences.libraryFeatureEnabled)。
                SettingsToggle(
                    "Enable Libraries",
                    isOn: $preferences.libraryFeatureEnabled,
                    help: "Shows the bookshelf — libraries and collections — on the Home screen. When off, Home shows only the other features you have on (or, with all of them off, the original welcome screen), the library and collection items disappear from the menus, context menus and the side panel, and the background work that exists only for libraries stops: checking that registered books are still there, making covers, and watching auto-add folders. Your libraries and collections are kept and come back when you turn this on again."
                )
                // ユーザー要望 2026-09-10。勝手に消す設定ではなく「起動時に一覧を出して尋ねる」
                // 設定なので、ラベルも Offer(尋ねる)にしてある。何を対象にするか
                // (外付けを外しているだけの本は対象外)は吹き出しへ。
                // ライブラリ機能がOFFの間は効かない設定なので無効にする(サイドパネルの欄と同じ理由)。
                SettingsToggle(
                    "Offer to Remove Books That Are No Longer There",
                    isOn: $preferences.offersRemovingMissingCollectionBooks,
                    help: "At launch, lists the books in your collections whose file is gone even though the volume it was on is connected, and asks whether to remove them. Books on a volume you have disconnected are never listed, and nothing is removed until you choose Remove. A collection whose every book is gone is removed along with them."
                )
                .disabled(!preferences.libraryFeatureEnabled)
                // 改善要望5でお気に入りを無効化したため、この設定は出さない(FavoritesFeature参照)。
                // 設定値(showRecentFavoritesOnWelcome)自体は残してあるので、復活させれば
                // 以前のON/OFFがそのまま戻る。
                if FavoritesFeature.isEnabled {
                    SettingsToggle("Show Recent Favorites", isOn: $preferences.showRecentFavoritesOnWelcome)
                }
            } header: {
                Text("Home")
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
                    // 上段のフォルダブラウザ専用。下段の本の中身の一覧は常に本のページ順
                    // (理由はAppPreferences.sidePanelSortOrderのコメント参照)。
                    SettingsPicker(
                        "Sort Order",
                        selection: $preferences.sidePanelSortOrder,
                        help: "Applies to the folder browser at the top of the side panel. The book contents list below it always follows the book's page order."
                    )
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
