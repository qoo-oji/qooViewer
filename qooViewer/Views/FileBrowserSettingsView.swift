import SwiftUI

/// 環境設定ウインドウの「ファイルブラウザ」画面(改善要望7 段階3、2026-09-13)。
///
/// 段階3で並べるのは**いま効くものだけ**(起動時のフォルダ・フォルダを上に。段階4bで「外からドロップしたとき」、
/// 2026-09-14 に「現在のフォルダまでツリーを自動で展開」と「サブフォルダを右と同じ順に並べる」、段階 6 で「圧縮ファイルの形式」、段階 7b で
/// 「動画のサムネイルを生成」、段階 8 で「ファイルブラウザで開く」の行き先、段階 8.5 で「読み取り専用」、2026-09-14 に「画像フォルダを開くとき」)。計画
/// (docs/plans/file-browser-plan.md §3.6)に挙げた残りの行 ――
/// サムネイルのキャッシュ ―― は環境設定「キャッシュ」に置いた。押しても何も変わらない設定を先に並べると、効かない理由が画面から読めない。
struct FileBrowserSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var favoriteLocations: FavoriteLocationStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsPaneContainer {
            // 並び(2026-09-27、環境設定の点検で利用者と決めた): より根本的なものほど上、同じくらいなら触る頻度の高いものから。
            // ファイル操作(読み取り専用 = ほかの操作すべての前提・自動リネーム)→ 他のアプリからのドロップ(ファイルが動く)→ 画像フォルダを開くとき
            // (ダブルクリックの意味)→ 最初のフォルダ → 並べ替え → アイコン表示(動画の絵は裏でも作る)→ ツリー → 圧縮の形式
            // (拡張子が変わるだけ)→ 「ファイルブラウザで表示」の行き先。
            // 読み取り専用モード(決定事項 Q12、段階 8.5)。既定 ON なので、ファイルを変えたい人が最初に探す場所として先頭に置く。
            Section {
                SettingsToggle(
                    "Read-Only",
                    isOn: $preferences.fileBrowserReadOnly,
                    // 「コレクションの作成と登録」は、ライブラリ機能が OFF の間は無い機能なので文から外す(2026-09-21 の監査の D3)。
                    help: preferences.libraryFeatureEnabled
                        ? "Items can't be pasted, cut, moved to the Trash, renamed, compressed or extracted, no new folders can be made, dragging doesn't move items, and file changes can't be undone or redone. You can still browse, open books, copy items, add favorite locations, create and add to collections, edit metadata and export books. Turn this off to change files in the file browser."
                        : "Items can't be pasted, cut, moved to the Trash, renamed, compressed or extracted, no new folders can be made, dragging doesn't move items, and file changes can't be undone or redone. You can still browse, open books, copy items, add favorite locations, edit metadata and export books. Turn this off to change files in the file browser."
                )
                // Finder の「拡張子を変更する前に警告を表示」と同じ(2026-10-24)。名前の変更の確認なので、読み取り専用の次。
                SettingsToggle(
                    "Show Warning Before Changing an Extension",
                    isOn: $preferences.fileBrowserWarnsBeforeChangingExtension,
                    help: "When you rename a file and change its extension, qooViewer asks first, as the Finder does."
                )
                // 自動リネーム(2026-09-15)。ファイルを変える機能なので、読み取り専用の隣に置く(読み取り専用の間は止まる)。
                // ファイルブラウザ機能が OFF の間は自動リネームも止まっている(AppStores.applyFileBrowserFeature)ので、押せない。
                // 「ホーム」メニューの同じ項目は OFF の間は消える ―― ここだけ設定を見ずに開けていた(2026-09-21 の監査の F1)。
                Button("Auto Rename Settings…") {
                    openWindow(id: AutoRenameSettingsWindow.windowID)
                }
                .disabled(!preferences.fileBrowserFeatureEnabled)
            } header: {
                Text("File Operations")
            } footer: {
                Text("Auto rename renames items in Favorite Locations automatically by your rules. It doesn’t run while Read-Only is on or while the file browser is turned off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            // 2026-09-14、ユーザー要望。右クリックの「開く」はこの設定に関係なく常にフォルダを開き、⌥ で「本として開く」
            // (2026-10-24 から。それまではこの反対をした。FileBrowserImageFolderOpenAction)。
            Section {
                SettingsPicker(
                    "Double-Click or Return",
                    selection: $preferences.fileBrowserImageFolderOpenAction,
                    help: "What happens when you double-click a folder with images directly inside, or select it and press Return. Open in the right-click menu always opens the folder; hold Option to change it to Open as Book. Other folders and volumes always open as folders. Return in the tree on the left follows this setting too."
                )
            } header: {
                Text("Opening Image Folders")
            }

            // 2026-10-24、ユーザー決定(FileBrowserImageFileOpenAction)。
            Section {
                SettingsPicker(
                    "What to Open",
                    selection: $preferences.fileBrowserImageFileOpenAction,
                    help: "What opens when you open one image file in the file browser, by double-clicking, pressing Return, or choosing Open or an Open in New item from the right-click menu. Whole Folder as a Book opens the folder the image is in as a book, starting at that image; like opening the folder itself, it includes images in its subfolders and pages of archives in it. Selecting several images and opening them always makes one book of just those images. Images directly on a volume, directly in your home folder or its standard folders such as Desktop, Downloads and Pictures, or in a folder qooViewer has no access to open on their own, as do hidden images."
                )
            } header: {
                Text("Opening Image Files")
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
                    "Make Thumbnails for Videos",
                    isOn: $preferences.fileBrowserVideoThumbnailsEnabled,
                    help: "Shows a frame from each video in icon view, made by Quick Look. While qooViewer is open, thumbnails for the videos in your favorite locations and their subfolders are also made in the background, so they appear right away. Some formats, such as MKV, need a Quick Look extension from another app."
                )
            } header: {
                Text("Icon View")
            }

            Section {
                SettingsToggle(
                    "Expand the Tree to the Current Folder",
                    isOn: $preferences.fileBrowserExpandsTreeToCurrentFolder,
                    help: "Each time you move to another folder, the tree on the left opens down to that folder and selects it. Folders you opened before stay open."
                )
                SettingsToggle(
                    "Sort Subfolders Like the List",
                    isOn: $preferences.fileBrowserTreeFollowsListSort,
                    help: "Subfolders in the tree on the left are sorted by the same column and direction as the items on the right. Volumes, Home Folder and your favorite locations keep their order. When this is off, subfolders are sorted by name."
                )
                // Finder のサイドバーの「最近の項目」(2026-09-28、利用者の要望。既定 OFF)。
                SettingsToggle(
                    "Show Recents at the Top of the Tree",
                    isOn: $preferences.fileBrowserShowsRecents,
                    help: "Adds “Recents” above Volumes in the tree on the left. It lists the books you have opened in qooViewer, newest first (the same list as the File menu's Open Recent), so you can get back to them from a Home that has no history button. It is not shown in private windows."
                )
                // LAN の SMB サーバ(2026-10-25、利用者の要望。既定 OFF ―― AppPreferences.fileBrowserShowsNetwork)。
                SettingsToggle(
                    "Show Network in the Tree",
                    isOn: $preferences.fileBrowserShowsNetwork,
                    help: "Adds “Network” below Volumes in the tree on the left, listing the file servers found on your local network. Click one to connect: macOS asks for a password if needed and lets you choose the volumes to mount. The first time, macOS asks whether qooViewer may find devices on your local network. If you didn’t allow it, turn on qooViewer in System Settings > Privacy & Security > Local Network."
                )
            } header: {
                Text("Tree")
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

            Section {
                SettingsPicker(
                    "While a Book Is Open",
                    selection: $preferences.fileBrowserRevealDestination,
                    help: "Where Show in File Browser opens the file browser when the window is showing a book. In a window that isn't showing a book, the file browser opens in that window."
                )
            } header: {
                Text("Show in File Browser")
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
