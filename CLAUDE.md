# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

qooViewer is a macOS 15+ manga/comic viewer app (SwiftUI + AppKit + SwiftData), inspired by cooViewer.
It supports folders, zip/cbz, rar/cbr, 7z/cb7, PDF, and EPUB (fixed-layout, image-based comic EPUB only).

## Build & run

This is a GUI app, verified by building and running it in Xcode. There is a unit test target
(`qooViewerTests`, Swift Testing) covering the UI-free `nonisolated` pipeline: page ordering and filename
classification, the archive-reader → `BookLoader` → `PageRef` path, EPUB/PDF structure resolution, and the
export round-trip (`CbzExporter`/`EpubExporter`/`PDFExporter` → read back),
driven by small book fixtures in `qooViewerTests/Fixtures/` (ledger: `manifest.json`; golden = the
`PageRef.sortKey` sequence, i.e. the DB page keys) plus in-test builders in `qooViewerTests/Support/`.
Tests run inside the real app (TEST_HOST) and must never touch shared state — open books through
`FixtureBook.load` (`cachesPageList: false`), never `UserDefaults.standard` / `*.shared` caches /
`mainContext`. Run tests locally with normal signing (no `CODE_SIGNING_ALLOWED=NO`: an unsigned test
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

Normal development is done in Xcode (`Cmd+R`). There is no SwiftLint/SwiftFormat config in this project —
do not assume one exists.

CI is GitHub Actions (`.github/workflows/`): `build.yml` builds Debug and Release on `macos-26` with warnings
treated as errors (passed as `QOO_CI_WARNINGS_AS_ERRORS=YES`, routed through `Configurations/Shared.xcconfig`
so it reaches only the app target, not the SwiftPM dependencies), runs `qooViewerTests` in the Debug job
and validates what its export tests wrote (EPUBCheck + the ComicInfo v2.0 XSD, via
`scripts/ci/validate-exports.sh`), and `check.yml` runs
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

**SwiftData persistence**: `FavoritesStore`, `BookmarkStore`, `LayoutStore`, and `BookMetadataStore`
(ViewModels/) all share a
single `ModelContext` (`QooViewerApp.modelContainer.mainContext`), constructed once in
App/QooViewerApp.swift and injected via `.environmentObject`/`.modelContext` everywhere. Do not create
additional/separate `ModelContext` instances for these models — a prior split-context design caused
silent update failures because SwiftData objects from one context don't affect another. Do not add
`@Attribute(.unique)` to these models — it previously caused data loss when inserting+saving in quick
succession on the same context (see comments in PageLoader-adjacent model files, e.g.
Models/PageLayoutOverride.swift / Models/BookLayoutSettings.swift, before touching uniqueness constraints).
`QooViewerApp.modelSchema`/`modelConfiguration` also has a user-facing recovery path if the store fails to
load (offers to delete and recreate) — keep new model types additive/lightweight-migration-friendly.

**Menu bar ↔ viewer bridging**: `AppState` (ViewModels/AppState.swift) is one-per-window and is exposed to
the menu bar via `FocusedValue` (see the `qooViewerAppState`/`qooViewerMenuCheckmarkState` extension in
AppState.swift). The active `ViewerView` registers closures on `AppState` (`performViewerAction`,
`jumpToBookmark`, `performLayoutStateChange`, etc.) on appear and clears them on disappear, using a
disposable UUID token (`activeViewerToken`) to resolve ordering races when switching books in the same
window. Menu checkmark/enabled state is pushed into `AppState` as plain `Equatable` value fields (not read
off the `ViewerViewModel` class reference) because `FocusedValue` change detection needs a value type.

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

- **Do not update README.md/MANUAL.md/CHANGELOG.md, and do not run `git commit`, unless explicitly
  instructed for that specific change.** Likewise, do not create release tags (e.g. `vX.YY`) unless
  explicitly instructed.
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
    image/thumbnail → leave it alone; an outline there looks wrong
  - a native control whose silhouette smears (the page list's slider) → `.panelControlWell()` instead
  - something tinted with the accent colour whose *state* would be lost against a matching panel
    colour → `.panelOutlinedAccent(in:)`
  Content inside a context menu, sheet, alert or popover needs nothing — macOS draws those opaquely
  and they are unaffected. Forgetting the call only means no outline appears (it never leaks onto the
  wrong part), so the failure is quiet: check it against a panel filled 100% with the text colour
  (light appearance + black, dark appearance + white) before calling the change done.
- **git commit messages**: written in English, concise, as a bullet-point list inside a code block.
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
