import SwiftUI

/// 環境設定ウインドウの「ファイルブラウザ」画面(改善要望7 段階3、2026-09-13)。
///
/// 段階3で並べるのは**いま効くものだけ**(起動時のフォルダ・フォルダを上に。段階4bで「外からドロップしたとき」、
/// 2026-09-14 に「現在のフォルダまでツリーを自動で展開する」)。計画
/// (docs/plans/file-browser-plan.md §3.6)に挙げた残りの行 ―― 圧縮の拡張子・
/// 「ファイルブラウザで開く」の行き先・動画のサムネイル・サムネイルのキャッシュ ―― は、それを使う
/// 機能が入る段階で足す。押しても何も変わらない設定を先に並べると、効かない理由が画面から読めない。
struct FileBrowserSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var favoriteLocations: FavoriteLocationStore

    var body: some View {
        SettingsPaneContainer {
            Section {
                SettingsPicker(
                    "Folder to Show First",
                    selection: $preferences.fileBrowserStartupLocation,
                    help: "The folder the file browser shows the first time you switch to it in a window. After that, each window keeps showing the folder you were in."
                )
                if preferences.fileBrowserStartupLocation == .favorite {
                    favoritePicker
                }
            } header: {
                Text("When the File Browser Opens")
            }

            Section {
                SettingsToggle(
                    "Keep Folders on Top",
                    isOn: $preferences.fileBrowserFoldersFirst,
                    help: "Folders are listed before files whichever column you sort by."
                )
            } header: {
                Text("Sorting")
            }

            Section {
                SettingsToggle(
                    "Expand the Tree to the Current Folder",
                    isOn: $preferences.fileBrowserExpandsTreeToCurrentFolder,
                    help: "Each time you move to another folder, the tree on the left opens down to that folder and selects it. Folders you opened before stay open."
                )
            } header: {
                Text("Tree")
            }

            Section {
                SettingsPicker(
                    "When Items Are Dropped from Other Apps",
                    selection: $preferences.fileBrowserExternalDropAction,
                    help: "Open in Viewer opens the dropped items as a book, as when you drop them anywhere else in the window. Copy or Move puts them in the folder you drop them on, like the Finder: items on the same volume are moved and items from another volume are copied. Hold Option to always copy or Command to always move. Dragging within qooViewer always copies or moves."
                )
            } header: {
                Text("Drag and Drop")
            }

            SettingsResetSection(
                help: "Restores every setting on this page. Your favorite locations and folder access are not affected."
            ) {
                preferences.resetToDefaults(.fileBrowser)
            }
        }
    }

    /// よく使う項目から1つ選ぶ。登録が無ければ淡色(選べるものが無い)。選ばれていた項目が
    /// 登録から外されていれば、ホームを開く(FileBrowserState.startupFolder)。
    @ViewBuilder
    private var favoritePicker: some View {
        let items = favoriteLocations.items
        let selected = items.first { $0.id.uuidString == preferences.fileBrowserStartupFavoriteID }
        SettingsPickerRow(
            "Favorite Location",
            selection: $preferences.fileBrowserStartupFavoriteID,
            currentTitle: selected.map { LocalizedStringKey("\($0.url.lastPathComponent)") }
                ?? (items.isEmpty ? "No Favorite Locations" : "Choose…"),
            help: "Add folders with the + button next to Favorite Locations in the file browser.",
            controlWidth: 220
        ) {
            ForEach(items) { item in
                Text(verbatim: item.url.lastPathComponent).tag(item.id.uuidString)
            }
        }
        .disabled(items.isEmpty)
    }
}
