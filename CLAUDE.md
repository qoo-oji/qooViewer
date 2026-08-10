# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

qooViewer is a macOS 15+ manga/comic viewer app (SwiftUI + AppKit + SwiftData), inspired by cooViewer.
It supports folders, zip/cbz, rar/cbr, 7z/cb7, PDF, and EPUB (fixed-layout, image-based comic EPUB only).

## Build & run

There is no CLI test target — this is a GUI app, verified by building and running it in Xcode.

```bash
# Build (Debug)
xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Debug build

# Build (Release)
xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Release build
```

Normal development is done in Xcode (`Cmd+R`). There is no SwiftLint/SwiftFormat config and no test target in
this project — do not assume either exists.

Dependencies are Swift Package Manager (resolved automatically by Xcode/xcodebuild): ZIPFoundation, SevenZip.swift
(tracks the `main` branch, not a version tag), Unrar.swift, UniversalCharsetDetection.

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
dedups in-flight requests for the same page, and prefetches pages around the current index into two
`NSCache`s (full image / progress-bar thumbnail). When editing this file, preserve the actor-isolation
boundary: archive/PDF handles must stay actor-confined, but decoding must not block the actor.

**Actor isolation gotcha**: this project targets Swift 6.2 with default actor isolation set to `MainActor`,
so any type/function not explicitly marked is implicitly main-actor-only. Code that must run off the main
actor (used from `PageLoader`, an actor, or from `BookLoader`'s detached tasks) is explicitly marked
`nonisolated` — see the top of Services/ArchiveReading.swift. Keep this in mind when adding new
free functions/types touched from those code paths.

**SwiftData persistence**: `FavoritesStore`, `BookmarkStore`, and `LayoutStore` (ViewModels/) all share a
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

**EPUB as an authority, not just a format**: when a book carries `MangaBook.epubLayoutHint` (page
progression direction / forced spread), the corresponding user settings/toggles are locked and
grayed out in the UI rather than merged — EPUB's declared layout always wins. `ViewerViewModel`'s
`isReadingDirectionLocked`/`isDisplayModeLocked`/`isPageShiftLocked` are the source of truth for this.

**Sandboxing**: the app is (or is meant to be) sandboxed with user-selected read/write file access.
Directly opening a single archive/PDF file only grants access to that file, not sibling files in the same
folder — features like "open file in same folder" / "previous/next book" need the user to separately grant
folder access (`FolderAccessStore`, security-scoped bookmarks). Keep this constraint in mind for any
feature that reads files the user didn't explicitly pick.

**Localization**: `Resources/Localizable.xcstrings` is a String Catalog (English base + Japanese). The
in-app display language setting (`AppPreferences.displayLanguage`) is independent of the OS locale and is
applied via `.environment(\.locale, ...)` on every Scene. A small number of error strings intentionally
still follow the OS locale rather than the in-app setting (see BookLoader.swift's `errorDescription`
comments) — this is a known, deliberate simplification, not a bug.

## Docs in this repo

- `README.md` — user-facing overview and from-scratch Xcode project setup instructions (for building the
  app from the bare source folders, since the Xcode project itself isn't fully self-contained in git).
- `MANUAL.md` — end-user manual for the app's features.
- `CHANGELOG.md` — Keep a Changelog format, Japanese, `[Unreleased]` section at top.

## Working conventions for this repository

- **Do not update README.md/MANUAL.md/CHANGELOG.md, and do not run `git commit`, unless explicitly
  instructed for that specific change.** Likewise, do not create release tags (e.g. `vX.YY`) unless
  explicitly instructed.
- **CHANGELOG.md entries**: Keep a Changelog format, written in Japanese, and limited strictly to
  user-visible impact (what changed for someone using the app) — not implementation detail. Match the
  tone/granularity already in the file (short bullet per change, nested bullets for multi-part changes).
- **git commit messages**: written in English, concise, as a bullet-point list inside a code block.
- The app version lives in `MARKETING_VERSION` in `qooViewer.xcodeproj/project.pbxproj` (both Debug and
  Release configurations) and is versioned independently from `CHANGELOG.md`'s `[Unreleased]` heading —
  don't assume they're always in sync when reading history. Git release tags follow `vX.YY` (e.g. `v1.02`),
  matching the un-prefixed `[X.YY]` heading in CHANGELOG.md.
- Existing Swift code is heavily commented in Japanese, and the comments frequently explain *why* (a past
  bug, a rejected alternative, a platform quirk) rather than *what*. When editing near such comments,
  preserve/update them rather than deleting — they encode real debugging history (e.g. the SwiftData
  context-splitting bug, the `@Attribute(.unique)` data-loss bug, the `FocusedValue` value-type requirement).
