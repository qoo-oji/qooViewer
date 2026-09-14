import SwiftUI

/// 環境設定ウインドウの「ファイルブラウザ」画面(改善要望7 段階3、2026-09-13)。
///
/// 段階3で並べるのは**いま効くものだけ**(起動時のフォルダ・フォルダを上に。段階4bで「外からドロップしたとき」、
/// 2026-09-14 に「現在のフォルダまでツリーを自動で展開」、段階 6 で「圧縮ファイルの形式」、段階 7b で
/// 「動画のサムネイルを生成」、段階 8 で「ファイルブラウザで開く」の行き先、段階 8.5 で「読み取り専用」、2026-09-14 に「画像フォルダを開くとき」)。計画
/// (docs/plans/file-browser-plan.md §3.6)に挙げた残りの行 ――
/// サムネイルのキャッシュ ―― は環境設定「キャッシュ」に置いた。押しても何も変わらない設定を先に並べると、効かない理由が画面から読めない。
struct FileBrowserSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var favoriteLocations: FavoriteLocationStore

    var body: some View {
        SettingsPaneContainer {
            // 読み取り専用モード(決定事項 Q12、段階 8.5)。既定 ON なので、ファイルを変えたい人が最初に探す場所として先頭に置く。
            Section {
                SettingsToggle(
                    "Read-Only",
                    isOn: $preferences.fileBrowserReadOnly,
                    help: "Items can't be pasted, cut, moved to the Trash, renamed, compressed or extracted, no new folders can be made, dragging doesn't move items, and file changes can't be undone or redone. You can still browse, open books, copy items, add favorite locations, create and add to collections, edit metadata and export books. Turn this off to change files in the file browser."
                )
            } header: {
                Text("File Operations")
            }

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
                SettingsPicker(
                    "While a Book Is Open",
                    selection: $preferences.fileBrowserRevealDestination,
                    help: "Where Show in File Browser opens the file browser when the window is showing a book. In a window that isn't showing a book, the file browser opens in that window."
                )
            } header: {
                Text("Show in File Browser")
            }

            // 2026-09-14、ユーザー要望。右クリックの「開く」は常にこの反対(FileBrowserImageFolderOpenAction)。
            Section {
                SettingsPicker(
                    "Double-Click or Return",
                    selection: $preferences.fileBrowserImageFolderOpenAction,
                    help: "What happens when you double-click an image folder, or select it and press Return, in list or icon view. Open in the right-click menu does the other one, so both stay within reach. Folders that aren't books always open as folders, and the tree on the left isn't affected."
                )
            } header: {
                Text("Opening Image Folders")
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
                SettingsToggle(
                    "Make Thumbnails for Videos",
                    isOn: $preferences.fileBrowserVideoThumbnailsEnabled,
                    help: "Shows a frame from each video in icon view, made by Quick Look. While qooViewer is open, thumbnails for the videos in your favorite locations and their subfolders are also made in the background, so they appear right away. Some formats, such as MKV, need a Quick Look extension from another app."
                )
            } header: {
                Text("Icon View")
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

            Section {
                SettingsPicker(
                    "Format of Compressed Files",
                    selection: $preferences.fileBrowserCompressionFormat,
                    help: "The file extension given to archives made with Compress. Both are ordinary ZIP archives; .cbz is recognized as a comic book by qooViewer and other comic readers."
                )
            } header: {
                Text("Compression")
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
