# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

qooViewer is a macOS 15+ manga/comic viewer app (SwiftUI + AppKit + SwiftData), inspired by cooViewer.
It supports folders, zip/cbz, rar/cbr, 7z/cb7, PDF, and EPUB (fixed-layout, image-based comic EPUB only).

## Build & run

This is a GUI app, verified by building and running it in Xcode. There is a unit test target
(`qooViewerTests`, Swift Testing) covering the UI-free pipeline: page ordering and filename
classification, the archive-reader → `BookLoader` → `PageRef` path, EPUB/PDF structure resolution, the
export round-trip (`CbzExporter`/`EpubExporter`/`PDFExporter` → read back), and the saved-data import
path (`LibraryImportExportService.apply` / `LayoutStore.importSourceLayoutIfNeeded`) on an
in-memory SwiftData container the test builds itself (`qooViewerTests/Support/InMemoryLibrary.swift`),
driven by small book fixtures in `qooViewerTests/Fixtures/` (ledger: `manifest.json`; golden = the
`PageRef.sortKey` sequence, i.e. the DB page keys) plus in-test builders in `qooViewerTests/Support/`.
The file-operation engine for the file browser (`Services/FileOperations/`, `ViewModels/FileCommands/`) is also
covered, partly on disposable disk-image volumes that the scheme's Test pre-/post-action attaches with
`scripts/test/test-volumes.sh` — the sandboxed test host cannot run `hdiutil` itself (tests fail, not skip, when the
volumes are missing; run the script by hand if you test outside the scheme). Tests never touch the real Trash
(`FileOperationEnvironment.pseudoTrash`). Tests run inside the real app (TEST_HOST) — its window and startup code really run, so anything the app would do on
its own that touches shared state or makes noise is switched off under `RuntimeEnvironment.isRunningTests` (the welcome
screen starts on the bookshelf instead of listing the real home folder, file-operation sounds are silent); the window
still shows a spinning cursor while main-actor tests run, which is expected. Tests must never touch shared state — open books through
`FixtureBook.load` (`cachesPageList: false`), build stores on `InMemoryLibrary`'s own container, never
`UserDefaults.standard` / `*.shared` caches / `QooViewerApp.modelContainer.mainContext`. Run tests locally with normal signing (no `CODE_SIGNING_ALLOWED=NO`: an unsigned test
host triggers a macOS removable-volume permission dialog on every launch). Fixture regeneration is
`scripts/fixtures/build-fixtures.sh` (local only; needs `7zz` and `rar`); details in
`docs/02-project-and-build.md`. Everything about the UI is still verified by running the app.

```bash
# Build (Debug)
xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Debug build

# Build (Release)
xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Release build

# Test (Debug; the tests are hosted in the app, so this builds the app too)
xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Debug \
  -destination 'platform=macOS' test
```

Normal development is done in Xcode (`Cmd+R`). **The Debug configuration uses its own bundle identifier
(`com.qooProject.qooViewer.debug`, shown as "qooViewer Debug")**, so a Debug build — and the test host —
has a separate sandbox container and never touches the everyday app's saved data; checks that need real
data go through the installed Release app. There is no SwiftLint/SwiftFormat config in this project —
do not assume one exists.

**Distribution builds are made with Xcode 27 (macOS 27 SDK)** — moved from Xcode 26.6 on 2026-09-16 because an app
linked against the macOS 26 SDK stops showing the current value on the Settings pop-ups when run on macOS 27 (an OS-side
problem in the old-SDK path, not this app's code; details in `docs/09-ui-and-windows.md`「環境設定」). Xcode 27 runs on
macOS 26.6+, and the macOS 15.0 deployment target is unchanged. **A `Menu`'s `label:` must hold exactly one `Text`** —
that old path extracts the first `Text` as the title instead of drawing the label, so the hidden `Text`s that reserved
the widest option's width made every Settings pop-up read "the first option"; the width measurement now sits outside the
`Menu` (`SettingsPicker.widthProbe`) and is applied on macOS 15 only — built with the macOS 27 SDK and run on macOS 27,
the label is drawn as-is, so the reserved width left short options stuck at the left of a wide button (2026-09-18). Linking against the macOS 27 SDK also hides menu item images by default
(ordinary images too, not just SF Symbols): the Open With app icons are forced visible (`NSMenuItem.showsImageOnMacOS27()`, wrapped in
`#if compiler(>=6.4)` because CI's Xcode 26.6 lacks the API; `.labelStyle(.titleAndIcon)` in SwiftUI), and a two-axis `ScrollView`
now puts smaller content top-leading (the Actual Size window centers it itself). Swift 6.4 added `#ImplicitStrongCapture`, which flags a
`[weak x]` capture whose outer closure captures the same thing implicitly and strongly; silence it by making the outer
capture explicit, never by dropping the inner `weak`.

CI is GitHub Actions (`.github/workflows/`): `build.yml` builds Debug and Release on `macos-26` with warnings
treated as errors (passed as `QOO_CI_WARNINGS_AS_ERRORS=YES`, routed through `Configurations/Shared.xcconfig`
so it reaches only the app target, not the SwiftPM dependencies), runs `qooViewerTests` in the Debug job
and validates what its export tests wrote (EPUBCheck + the ComicInfo v2.0 XSD, via
`scripts/ci/validate-exports.sh`); a third job builds Debug, runs the tests and smoke-launches the app on the
`xcode-27` runner (macOS 27 + Xcode 27; public preview, arm64 only — there is no `macos-27` runner and `macos-26`
carries no Xcode 27). `check.yml` runs
`scripts/ci/check-all.sh` — repository consistency checks (Team ID leak, Info.plist ↔ `imageExtensions`,
`MARKETING_VERSION` ↔ CHANGELOG ↔ tag, fork pins, line endings, docs links). **Run `scripts/ci/check-all.sh`
before committing**; it is the same script CI runs. The CI signing is ad-hoc and for verification only —
release zips are still built and signed locally. Details in `docs/02-project-and-build.md`.

Dependencies are Swift Package Manager (resolved automatically by Xcode/xcodebuild): ZIPFoundation (0.9.20),
and two forks maintained by the app's author, each pinned by branch **and** revision in `Package.resolved`:
`qoo-oji/SevenZip.swift` (`streaming-extract`) and `qoo-oji/Unrar.swift` (`memory-archive`). To move a fork
forward, push the fork, hand-edit the `revision` in `Package.resolved`, then run
`xcodebuild -resolvePackageDependencies`. What the forks change and why is in `docs/11-forked-dependencies.md`.
`UniversalCharsetDetection` was removed on 2026-09-01 (commit `5eaca7f`); zip filename encoding is now
detected archive-wide with Foundation (`EntryNameDecoder` in Services/ZipArchiveReader.swift).

## Architecture

Standard MVVM layout: `App/`, `Models/`, `Services/`, `ViewModels/`, `Views/`, `Resources/`.

**Book loading pipeline**: `BookLoader.load(from:)` (Services/BookLoader.swift) dispatches on file type —
folder (recursive scan), archive (zip/rar/7z via the `ArchiveReading` protocol in
Services/ArchiveReading.swift), PDF (`CGPDFDocument`), or EPUB (`EpubStructureResolver` resolves the
package document's spine — EPUB is the only format where page order/spread hints come from the file
itself rather than filename sort). All of this runs off the main actor via `Task.detached`, since
scanning/extracting can be slow. The result is a `MangaBook` (Models/MangaBook.swift), whose `pages: [PageRef]`
array is mutable so the viewer can reorder/exclude pages live without reopening the book.

**Page image loading**: `PageLoader` (Services/PageLoader.swift) is an `actor` per opened book. It owns
per-archive `ArchiveReading` readers and `CGPDFDocument`s, decodes images off-actor in background tasks,
dedups in-flight requests for the same page, limits concurrent full-size decodes (display requests
jump ahead of prefetches), and prefetches pages around the current index into three `PagePixelCache`s
(strict LRU with byte/count limits; full image / progress-bar thumbnail / grid thumbnail). When editing this file, preserve the actor-isolation
boundary: archive/PDF handles must stay actor-confined, but decoding must not block the actor.

**Actor isolation gotcha**: this project targets Swift 6.2 with default actor isolation set to `MainActor`,
so any type/function not explicitly marked is implicitly main-actor-only. Code that must run off the main
actor (used from `PageLoader`, an actor, or from `BookLoader`'s detached tasks) is explicitly marked
`nonisolated` — see the top of Services/ArchiveReading.swift. Keep this in mind when adding new
free functions/types touched from those code paths.

**SwiftData persistence**: `FavoritesStore`, `BookmarkStore`, `LayoutStore`, `BookMetadataStore`, and
`CollectionStore` (ViewModels/) all share a
single `ModelContext` (`QooViewerApp.modelContainer.mainContext`), constructed once in
App/QooViewerApp.swift and injected via `.environmentObject`/`.modelContext` everywhere. Do not create
additional/separate `ModelContext` instances for these models — a prior split-context design caused
silent update failures because SwiftData objects from one context don't affect another. Do not add
`@Attribute(.unique)` to these models — it previously caused data loss when inserting+saving in quick
succession on the same context (see comments in PageLoader-adjacent model files, e.g.
Models/PageLayoutOverride.swift / Models/BookLayoutSettings.swift, before touching uniqueness constraints).
`QooViewerApp.modelSchema`/`modelConfiguration` also has a user-facing recovery path if the store fails to
load (offers to delete and recreate) — keep new model types additive/lightweight-migration-friendly.
**Whenever a `@Model` changes (or `QooViewerApp.modelTypes` does), add a row to
`StoreSchemaGuard.generations`** (`StoreSchemaGuardTests` fails otherwise), and cover any new persisted
attribute with a save → close → reopen test on a disposable on-disk store (`DisposableStore` /
`StorePersistenceTests`) — in-memory stores never exercise reopening or migration. When the new attribute
lives on `BookLayoutSettings`, also decide whether the saved-data JSON exports it: a column that is
*not* exported must be listed in `BookLayoutSettings.holdsNonExportedData`, or an "overwrite" import
silently drops it (this is how collection covers were lost on overwrite imports until 2026-09-13). SwiftData silently
"migrates" a newer store down to an older model and drops the columns that model doesn't know; on
2026-09-11 launching the previous release did exactly that to 131 collection covers. Never run an older
build of the app (including a test host built from an old tag) against real data. Details in
`docs/06-persistence.md`.

**Welcome screen (UI name: 「ホーム」 / "Home" since 2026-09-15; code keeps `Welcome*`, and the file browser's home directory is "Home Folder" / 「ホームフォルダ」) = the bookshelf (libraries / collections)**: `Views/Welcome/` plus `CollectionStore`,
`CollectionCoverStore` (covers on disk under Application Support — not a cache, never evicted),
`CollectionCoverExtractor` (one app-wide queue) and `CollectionAutoFolderScanner` + `FolderChangeWatcher`
(FSEvents). Covers are stored uncropped; aspect ratio / crop anchor are per-library and applied at draw
time. The auto-add folder holds a *path only* — folder permission stays with `FolderAccessStore`. Edit
mode only decides what a click/drop means and whether the trash shows; creating/adding/renaming are not
gated on it. The welcome screen has a second mode, the **file browser** (`WelcomeLibraryState.mode`, `Views/FileBrowser/`,
`FileBrowserState` one-per-window — its sort key/direction are the side panel's `AppPreferences.folderBrowserSortKey`/`…Direction`, shared on purpose, while "folders first" stays separate — `FavoriteLocationStore`): list, tree and icons are AppKit (`NSTableView`/`NSOutlineView`/`NSCollectionView` — the icon view was moved off SwiftUI on 2026-09-15 so all three share the same drop, menu, key and rename paths), listing runs on `FileIO` (never `Task.detached`), and new tabs/windows receive a folder through
`WindowContentRequest.browse` (the value type of the book `WindowGroup`s). Every write operation (copy/cut/paste, trash, compress/extract,
new folder, rename, bulk rename, undo/redo) goes through `FileBrowserOperations` (one per `FileBrowserState`, serial, confirmations via
`FileBrowserOperationPresenting`), which is also the one place that refuses them while read-only mode is on — or the file browser feature is off —
(`isReadOnly`; checked at each entrance, and again by `asking` when a confirmation or sheet returns, so a sheet left up
across the switch does nothing; operations accepted before the switch still finish)
(`AppPreferences.fileBrowserReadOnly`, **default ON**; the UI only dims items via `FileBrowserActions.allowsFileChanges`, and drags out
become copy-only); tests inject a pseudo trash, a uniquely named pasteboard and a scripted presenter. An item is
greyed out by the same predicate the action uses to refuse (`FileBrowserActions.canOpen` / `canChange` — which also
excludes books open in a viewer — / `canWriteInto`), shared by the context menu, the menu bar (`FileBrowserMenuSelection`)
and the lists' keys (`canPerform`); never enable something that then silently does nothing (docs/15「淡色の条件」, 2026-09-19). Holding Option while the
context menu is open swaps Copy → Copy as Pathname and Open With → Always Open With, as in Finder (2026-09-21;
`FileBrowserMenuCommand.optionAlternate`, built as AppKit alternate items right after their primary, never listed in
`groups(for:)`; Always Open With writes a per-file xattr, so it is refused in read-only mode). "Replace" moves the existing item into a hidden
`.qooViewer-replace-<UUID>/` folder only after recording it in `ReplaceBackupJournal`, and `ReplaceBackupRecovery` puts it back at launch
(skipped under tests) — keep that record-before-backup order. Anything that deletes a tree item by item lists names with `readdir`
(`FileOperationService.directoryEntryNames`): `FileManager.contentsOfDirectory` silently omits `._*` names even on APFS, and a
`rmdir` on an exFAT folder left with only `._` files hung the kernel (and Finder) during the 2026-09-15 audit — do not run such
experiments on FAT/exFAT disk images from parallel agents. On FAT/exFAT `st_ctime` is just the modification date (measured
2026-09-15), so "has the source changed" checks there compare size and mtime with the copy (`FileOperationService.SourceChangeCheck`),
never ctime against the clock. **The app mutates the file system while it stays active** (file browser operations, undo/redo,
auto rename), so "refresh on app activation" is not enough any more: every such change is reported from one place, `FileOperationService`'s
`changeObserver` (only `FileOperationService.shared` is wired, to `FileSystemChangeCenter.shared`; both file-browser commands and
`AutoRenameService` use `.shared`), as a `FileSystemChange` carrying old → new paths. Consumers: every `FileBrowserState` and
`SidePanelBrowserState` (rewrite path-held state, follow a renamed current folder, reload — the only signal on network volumes),
`FavoriteLocationStore.relocate`, `FileCutClipboard` (the cut memory is app-wide), and `AppStores.handleFileSystemChange`
(`BookRecordRelocator` rekeys the five stores + `BookReadingState` by path, across volumes too, then existence refreshes). New code that
moves/renames/deletes user files must go through `FileOperationService`, and new UI that mirrors the file system must subscribe. Under tests
each state gets a private center/clipboard and `AppStores` does not subscribe. Operations on a book open in any viewer are refused
(`FileBrowserOperations.refusesBecauseOpenInViewer`), and a book whose bookmark resolves into the Trash counts as missing
(`BookLocationResolver.isInTrash`). Audit and rationale: `docs/plans/fs-ui-consistency-audit.md`, docs/15「アプリ自身の変更の知らせ」.
Inline rename (list and icon view) is started only by the app, never by AppKit: name
fields are not editable at rest (NSTableView's own click-to-edit ran from a private delayed perform that ignored drags and
started editing a file that had just been moved, 2026-09-19); every start goes through `FileBrowserNameEditing.canBegin`
(item still listed and on disk), clicks wait in `FileBrowserNameClickRename`, and an edit whose item vanishes is cancelled.
Bulk rename copies
Finder's measured rules (`Models/BulkRename.swift`; registered extensions, collisions avoided rather than refused, so no two-pass rename) — change them only against the real Finder.
**Auto rename** (2026-09-15; `Models/AutoRename.swift`, `AutoRenameStore`, `Services/AutoRename/`, `Views/AutoRename/`; design and measurements in
`docs/plans/auto-rename-study.md`) renames items under Favorite Locations by rules while the app runs, outside `FileBrowserOperations`: it is not
started under tests, pauses in read-only mode, never touches a target until its current contents are confirmed, waits for writes to settle
(Finder's `brok`/`MACS` marker; whole-tree snapshots for folders — renaming a folder mid-copy breaks Finder's copy), applies name rules to the
name without its registered extensions, and turns off only targets whose folder is gone on a volume with the same UUID. The context menu's links to existing features (create/add
to collection, Edit Metadata on a book outside any collection, Export Book without loading it first, Open With) are in
`FileBrowserLibraryActions.swift`; submenus whose contents vary are a `FileBrowserMenuNode` tree drawn by both the AppKit and
SwiftUI menus. "Show in File Browser" (next to every "Show in Finder") goes through `AppState.revealInFileBrowser` and, from
views, the `\.revealInFileBrowser` environment value, which holds `AppState` weakly; `OpenWindowAction` is passed per call and
never stored on `AppState`; its AppKit menu items carry closures in a box whose action must not be named
`perform(_:)` (it silently resolved to NSObject's `performSelector:`). Windows and tabs without a book are titled by
what they show (`WindowTitle`: current folder / library / collection). Back/forward also comes from trackpad flicks and
mouse side buttons (2026-09-21; `FileBrowserNavigationGestureMonitor`, a window-scoped local event monitor that consumes
nothing but the momentum of a flick that navigated; rules in `FileBrowserNavigationGesture`, docs/15). Drag and drop
decides move/copy in one place (`FileDropPlan` + `FileBrowserDropDecision`); the right pane is covered by a drop target that refuses
*as a target*, because a refused inner SwiftUI drop falls through to the window-wide "open book" drop target. Inside SwiftUI
`.contextMenu`, `.disabled` has no effect on a `Menu` (submenu), so a disabled submenu is drawn as a disabled `Button`; and the list/tree
override `hitTest` so a name field the table would refuse never becomes the hit view (AppKit skipped that check after a SwiftUI
context submenu closed). The icon view shows
book/image thumbnails via `FileBrowserThumbnailProvider` (one app-wide, in `AppStores`; `BookThumbnailer` reads only the first image,
never `BookLoader.load`; disk cache `FileBrowserThumbnailDiskCache`, on by default) and video thumbnails through QuickLook
(`VideoThumbnailLoading`, with a `hev1` retagging fallback; `FileBrowserVideoThumbnailWarmer` pre-makes the ones under favorite
locations, and is not connected under tests). Anything in the file browser that reads a folder the user has not entered
(tree triangles, thumbnails, the video warmer) must skip TCC-protected locations by path string alone
(`DirectoryProbe.protectedPrefixes`) and network volumes by `MountTable` — checking by touching them is itself what
raises the TCC dialog or blocks for 30 s (docs/15 「サンドボックスと TCC の約束」). Design in `docs/15-file-browser.md`,
remaining stages and the handoff in `docs/plans/file-browser-plan.md`.
**A folder book's page keys (`PageRef.sortKey`) are absolute paths**, so everything that rekeys a moved book
(`reconcileBookIDIfMoved`, `applyBookRelocation`, `BookRecordRelocator`) must also rewrite the page keys stored with it —
`PageLayoutOverride.pageKey`, `coverPageKey` / `shelfCoverPageKey`, `Bookmark.pageKey`, `BookReadingState.lastPageKey` — through
`PageKeyRelocation` (2026-09-21; before that only `bookID` moved and per-page layout and cover choices silently fell off). New
page-keyed persisted data must join that list (docs/06「移動・リネームへの追従」). File-operation progress is shown by
`FileBrowserProgressBar` in the pane, and by `WelcomeView` while the pane is not on screen (shelf mode, or the feature turned off mid-copy).
`CollectionStore` is deliberately *not* in `AppStores.allObjectWillChangePublishers` (it publishes on every
cover extraction/existence check); the menu bar's **Home** menu (2026-09-15) reads library/collection names from
`HomeMenuDirectoryStore`, a value copy that publishes only when names, order or membership change. Home-screen menu
items (Home menu; file-browser items in File/Edit; View menu swapped while Home is shown) read per-window values from
`MenuCheckmarkState.homeMenu` / `.fileBrowserSelection`, and anything that needs a sheet/alert owned by a view goes
through `WelcomeLibraryState.menuRequest` (docs/09「メニューバーのホーム画面の項目」). **The whole library feature can be
switched off at run time** (Settings ▸ General ▸ "Enable Libraries", `AppPreferences.libraryFeatureEnabled`, default ON;
2026-09-21): Home shows only the file browser (no top bar, `WelcomeLibraryState.mode` pinned to `.browser`), the library
items leave the Home menu, the file browser context menu and the side panel, and the library-only background work stops —
existence refresh, cover extraction and its launch preparation, auto-folder scanning and FSEvents, launch sweeps, the Home
menu directory, collection reconciliation on book open. What stops and what deliberately does not (`BookRecordRelocator`,
saved-data import/export/cleanup, following a moved book on open — `reconcileBookIDIfMoved` on all five stores together —
and the "books this app knows" lookups behind Edit Metadata / Export / cleanup) is listed on `AppStores.applyLibraryFeature`;
**new library-only work must check the flag there too**, and must not fetch `CollectionItem`s while it is off — what stays on
is only work that keeps saved data correct or a user action from failing. **Anything that can now be stopped at run time**
(`AutoRenameService.stop()`, `CollectionCoverExtractor.cancelAll()`) must let itself be restarted: the stopped side checks
cancellation *and a generation number* after every await, `stop` nils the Task variables it cancels, and every entry point
callable from outside checks "am I stopped" (2026-09-21 audit, `docs/plans/feature-toggle-audit.md`). Data is never deleted; books whose layout changed
while off are remembered in UserDefaults and get their covers redone when it is turned back on (docs/14
「ライブラリ機能の ON/OFF」). **The file browser has the same kind of switch** ("Enable File Browser",
`AppPreferences.fileBrowserFeatureEnabled`): its items leave Home, the menu bar and every context menu — including all
"Show in File Browser" items, which read `RevealInFileBrowserAction.isFeatureEnabled` — and `AutoRenameService` and the
video thumbnail warmer stop (`AppStores.applyFileBrowserFeature`). The two flags together pick the Home layout in one
place, `WelcomeLibraryState.constrained`: both on = as before, library only = the pre-file-browser shelf (v1.50–v1.56: the top bar gets its Open Book… / Open from History buttons back), file browser
only = the pane with no top bar, both off = `WelcomeMode.classic`, the pre-bookshelf welcome screen restored as
`ClassicWelcomeView` (and no Home menu). `.classic` is never a user choice and forced modes are never saved. New file
browser entry points must check the flag (docs/15「ファイルブラウザ機能の ON/OFF」) — including `Window` scenes, which add
themselves to the Window menu unless `.commandsRemoved()` (the Auto Rename Settings window also closes itself when the
flag goes off). The favorites feature is hidden behind
`FavoritesFeature.isEnabled == false` — models, stores, window and JSON schema are kept so the data
survives. Design and the reasons are in `docs/14-library-collections.md`.

**Menu bar ↔ viewer bridging**: `AppState` (ViewModels/AppState.swift) is one-per-window and is exposed to
the menu bar via `FocusedValue` (see the `qooViewerAppState`/`qooViewerMenuCheckmarkState` extension in
AppState.swift). The active `ViewerView` registers closures on `AppState` (`performViewerAction`,
`jumpToBookmark`, `performLayoutStateChange`, etc.) on appear and clears them on disappear, using a
disposable UUID token (`activeViewerToken`) to resolve ordering races when switching books in the same
window. Menu checkmark/enabled state is pushed into `AppState` as plain `Equatable` value fields (not read
off the `ViewerViewModel` class reference) because `FocusedValue` change detection needs a value type.
**Closures in the viewer's toolbar buttons, context menu items, Toggle bindings and confirmation dialogs
must go through `ViewerActionRelay` (`relay.send { $0.perform(.x) }`), never capture `ViewerView`
directly.** SwiftUI hands those closures to AppKit objects that outlive the window, so a direct capture
kept each closed book window's AppState/ViewerViewModel/PageLoader/NSWindow alive (about 118 MB per close,
fixed 2026-09-13). Same rule for `NSViewRepresentable` callbacks (clear them in `dismantleNSView`) and
`NSTrackingArea(owner: self)`. Leaks here are silent — verify with `heap`/`footprint` as in
`docs/12-verification-and-debugging.md`. Details in `docs/09-ui-and-windows.md`.

**EPUB/PDF layout is a seed, not an authority**: when a book carries `MangaBook.sourceLayoutHint` (page
progression direction / forced spread) or per-page spread hints, those are imported into the database
**once**, the first time the book is opened (`LayoutStore.importSourceLayoutIfNeeded(for:)`, guarded by
`BookLayoutSettings.didImportSourceLayout`), and everything afterwards follows the DB. The user can freely
change reading direction / spread / per-page layout for EPUB and PDF just like any other format.
Priority is DB (`BookLayoutSettings` / `PageLayoutOverride`) > `BookReadingState`, with the file's own hint
used only as a fallback for pages the import didn't cover (see `ViewerViewModel.layoutHint(at:)`).

This replaced an earlier design in which the file's declaration always won and the corresponding
toggles were locked and grayed out. `isReadingDirectionLocked`/`isDisplayModeLocked`/
`hasAuthoritativeSourceLayout` are gone; only `ViewerViewModel.isPageShiftLocked` remains, and it is
unrelated to EPUB — it grays out "shift by one page" while a spread with explicit per-page layout is on
screen. `BookLayoutSettings.hasEpubLayoutLock` is a leftover attribute, kept only to avoid a schema
migration; it is neither read nor written.

**Sandboxing**: the app is (or is meant to be) sandboxed with user-selected read/write file access.
Directly opening a single archive/PDF file only grants access to that file, not sibling files in the same
folder — features like "open file in same folder" / "previous/next book" need the user to separately grant
folder access (`FolderAccessStore`, security-scoped bookmarks). Keep this constraint in mind for any
feature that reads files the user didn't explicitly pick.

**Localization**: `Resources/Localizable.xcstrings` is a String Catalog (English base + Japanese). The
in-app display language setting (`AppPreferences.displayLanguage`) is independent of the OS locale. SwiftUI
`Text` follows it via `.environment(\.locale, ...)`, applied to the *content view* of every window (a
scene-level `.environment` does not reach the window content). Strings built in code must use
`String(localized:language:)` (Models/AppLanguage.swift) with `preferences.effectiveLocale`,
`@Environment(\.locale)`, or `AppLanguage.currentLocale` (for nonisolated services / pre-preferences code)
— Foundation's `String(localized:locale:)` only affects formatting and always picks the OS-language
translation. Window titles must be passed as such Strings, never as `Text(key)` / `Window("key", id:)`.
The menu bar and system dialogs cannot be switched at runtime; the setting is also written to the app's
`AppleLanguages` so they follow from the next launch (`AppLanguage.applyAppleLanguagesOverride`).

## Docs in this repo

- `README.md` — user-facing overview and build instructions. The repository is clone-and-build: the
  `.xcodeproj` (with a shared scheme), `Info.plist`, app icon and String Catalog are all committed, and
  `DEVELOPMENT_TEAM` is deliberately absent — a developer's own Team ID goes in the gitignored
  `Configurations/Local.xcconfig`, which `Configurations/Shared.xcconfig` pulls in via `#include?`.
- `MANUAL.md` — end-user manual for the app's features.
- `CHANGELOG.md` — Keep a Changelog format, Japanese, `[Unreleased]` section at top.
- `docs/` — maintainer-facing specification (Japanese): architecture, the reasoning behind design
  decisions, and the forked dependencies. Start at `docs/README.md`. Keep it in step with the code
  when a design decision changes; it is not covered by the "do not update" rule below.

## Working conventions for this repository

- **個人情報の流出防止(改善要望7、2026-09-13)。蔵書のフォルダ名・ファイル名(ボリューム名は除く)を、コード・
  コメント・docs・テスト・フィクスチャ・コミットメッセージ・ブランチ/タグ名・スクリーンショットのどこにも書かない。**
  「一般的な語だから」は理由にならない(実在する名前は語の意味に関わらず流出)。書いてよいのは集計と形だけ。
  検査は `scripts/ci/check-private-terms.sh`(`check-all.sh` の一部。手元の禁止語リスト
  `~/Library/Application Support/qooViewer-dev/private-terms.txt` は `scripts/dev/build-private-terms.py` で自分の
  蔵書から作る ―― **リポジトリの外に置き、絶対にコミットしない**)と git hook(`scripts/dev/install-git-hooks.sh` を
  一度実行。リストが無いとコミットは拒否される)。検査の出力に語そのものは出ない(`--reveal` は手元だけ)。
  一般語として見逃す語は `private-terms-allow.txt` へ ―― 実在の固有名は絶対に足さない。実機検証は使い捨て
  ボリューム(`hdiutil`)に合成名の本を置いて行い、実蔵書を表示したウインドウのスクリーンショットは撮らない。
  既存の 1 件(ルートのフォルダ名、`8adb1d9` 以降の履歴)はユーザー判断で履歴に残してある。
  詳細は `docs/02-project-and-build.md`「CI」と `docs/plans/file-browser-study.md` §1。

- **Do not update README.md/MANUAL.md/CHANGELOG.md, and do not run `git commit`, unless explicitly
  instructed for that specific change.** Likewise, do not create release tags (e.g. `vX.YY`) unless
  explicitly instructed. **A request to "update the documentation" (ドキュメントを更新) is such an
  instruction and covers the whole set** — CHANGELOG.md (`[Unreleased]`), MANUAL.md, README.md, docs/, and
  this file as needed — not just docs/. It does not cover bumping `MARKETING_VERSION` or cutting a release.
- **CHANGELOG.md entries**: Keep a Changelog format, written in Japanese, and limited strictly to
  user-visible impact (what changed for someone using the app) — not implementation detail. Match the
  tone/granularity already in the file (short bullet per change, nested bullets for multi-part changes).
- **Anything drawn on a frosted-glass surface must handle the text outline.** The five surfaces
  (`PanelSurface`) let the user fill them with an arbitrary colour, so text and icons can end up the
  same colour as the panel and vanish. When you **add or change any UI on one of those surfaces**,
  decide what the new element does about the outline and do it in the same change:
  - bare text / bare icons → add `.panelOutlinedContent()` (or apply it to a container that holds
    nothing but text and icons)
  - a part with its own opaque background (search field, filled badge, selected mode button), or an
    image/thumbnail → leave it alone; an outline there looks wrong. **Check that the background is
    actually opaque before deciding this** — a faint ground such as `Color.secondary.opacity(0.15)`
    is not one, and the part vanishes with its contents (measured on the collection cover's format
    badge, 2026-09-10)
  - a region that has only a faint ground and no text of its own (a cover cell with no artwork yet) →
    `.panelOutlinedFrame(in:)`, which draws the same reversed-colour border as
    `.panelOutlinedAccent(in:)` but for a different reason: not "the state is lost", but "you cannot
    tell anything is there at all"
  - a native control whose silhouette smears (the page list's slider) → `.panelControlWell()` instead
  - something tinted with the accent colour whose *state* would be lost against a matching panel
    colour → `.panelOutlinedAccent(in:)`
  A selection or "current item" highlight takes its colour from `SelectionEmphasis` (accent only while the window is
  key — and, for AppKit lists, while that list is first responder — grey otherwise, as in macOS; 2026-09-19), never
  `Color.accentColor` directly; drop-target highlights and state colours stay accent (docs/15「選択の強調」).
  Content inside a context menu, sheet, alert or popover needs nothing — macOS draws those opaquely
  and they are unaffected. Forgetting the call only means no outline appears (it never leaks onto the
  wrong part), so the failure is quiet: check it against a panel filled 100% with the text colour
  (light appearance + black, dark appearance + white) before calling the change done.
- **git commit messages**: written in English and concise. **The first line is a one-line summary**, then a blank
  line, then a bullet-point list of the changes — never a message that starts directly with the bullets (several
  commits in 2026-09 did, and the user pointed it out). When proposing a message in chat, show it inside a code block.
- The app version lives in `MARKETING_VERSION` in `qooViewer.xcodeproj/project.pbxproj` (both Debug and
  Release configurations) and is versioned independently from `CHANGELOG.md`'s `[Unreleased]` heading —
  don't assume they're always in sync when reading history. Git release tags follow `vX.YY` (e.g. `v1.02`),
  matching the un-prefixed `[X.YY]` heading in CHANGELOG.md.
- Existing Swift code is heavily commented in Japanese, and the comments frequently explain *why* (a past
  bug, a rejected alternative, a platform quirk) rather than *what*. When editing near such comments,
  preserve/update them rather than deleting — they encode real debugging history (e.g. the SwiftData
  context-splitting bug, the `@Attribute(.unique)` data-loss bug, the `FocusedValue` value-type requirement).
- **When a bug turns out to almost certainly be in AppKit/SwiftUI itself** (not this app's code) — e.g. a
  window-lifecycle/state-restoration quirk, a delegate method that silently never fires, layout/rendering
  glitches tied to a specific Scene/View combination — search the web for existing reports before spending
  more time on trial-and-error reproduction. Other developers have very likely hit the same platform bug,
  and there may be a known workaround, a filed Apple Feedback report confirming it's not app-specific, or a
  purpose-built API that sidesteps it. Precedent: the "external app opens qooViewer while it has zero
  windows" bug (window flashes and closes, or renders blank) turned out to be caused by macOS's standard
  window state restoration reusing a stale `NSWindow` on reactivation — found via web search once AppKit/
  SwiftUI was suspected, and fixed with `.restorationBehavior(.disabled)` on the affected `WindowGroup`
  (macOS 15+) rather than by continuing to patch around the symptom in app code.
