import AppKit
import SwiftUI

// ホーム(ライブラリのコレクションの中・スマートライブラリ)の本を、アプリの外へ渡す口(2026-09-23、利用者の指示):
// 右クリックの「コピー」・編集 ▸ コピー(⌘C)と、Finder などへのドラッグ&ドロップ。
//
// ■ 渡すのは本の実体の URL(ファイルブラウザの出し口と同じ。`FileBrowserDragAndDrop.swift` の冒頭)
// ペーストボードには `NSURL` を書く。Finder へ貼る・落とすと、**Finder 自身が**コピーする(サンドボックスに掛からない)。
//
// ■ ドラッグは**コピーだけ**を許す(`HomeBookDragSource.draggingSession(_:sourceOperationMaskFor:)`)
// ファイルブラウザの出し口は移動も許す(Finder の規則で、同じボリュームなら移動になる)が、ここは本棚 ―― 本を並べて眺める所で、
// ファイルの置き場所を変える所ではない。移動を許すと、同じボリュームの Finder のウインドウへ落としただけで本が動き、
// コレクションやスマートライブラリの対象フォルダから外れる(利用者の指示「コピーされるように」)。
//
// ■ SwiftUI の `.onDrag` は使わない
// `.onDrag` は 1 つの `NSItemProvider` しか運べない(複数選んだ本をまとめて運べない。macOS 26 の `dragContainer` は 15 に無い)うえ、
// ドラッグ元が許す操作を指定できない。セルの `DragGesture` が動き出した時点の出来事(`NSApp.currentEvent`)から AppKit の
// `beginDraggingSession` を始める。
//
// ■ 同じウインドウへ落としたときは何もしない
// ウインドウ全体に「本を開く」受け口がある(ContentView.applyFileDropTarget)。少し引きずって同じ一覧の上で離しただけで
// 本が開いたり、編集モードで同じコレクションへ登録し直したりしないよう、受け口はこのドラッグ元のウインドウからのものを断る
// (`HomeBookDragTracker.isDragging(from:)`)。ほかのウインドウ(ビューア・別のウインドウのファイルブラウザ)へは落とせる。
// アプリの中のファイルブラウザへ落としたときも、許しているのはコピーだけなのでコピーになる(`FileBrowserDragTracker` に載せる)。

/// ホームの本をペーストボードへ書く(右クリックの「コピー」・⌘C)。
@MainActor
enum HomeBookPasteboard {
    /// - Parameters:
    ///   - urls: 本の実体の URL。
    ///   - scopedURLs: 書くあいだセキュリティスコープを開けておく URL(コレクションの本はブックマークで許可を持つ。開けていないと
    ///     サンドボックスがほかのアプリへ読み取りの許可を付けられない)。
    ///   - fileBrowser: このウインドウのファイルブラウザ(ペーストの淡色の写しを直す。カットの記憶も下ろす)。
    static func copy(_ urls: [URL], scopedURLs: [URL] = [], fileBrowser: FileBrowserState?,
                     pasteboard: NSPasteboard = .general) {
        guard !urls.isEmpty else { return }
        let started = scopedURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        // ⌘C と同じ: 前のカットの記憶を下ろす(FileBrowserOperations.write)。ファイルブラウザが無くても、記憶はペーストの前に
        // changeCount で確かめ直される(FileCutClipboard.validate)。
        fileBrowser?.cutClipboard.set([], on: pasteboard)
        fileBrowser?.refreshPasteboardState()
    }
}

/// いまホームから始まっている本のドラッグ(グリッドの `HomeBookDragSource` と、スマートライブラリのリストの `NSOutlineView`)。
@MainActor
enum HomeBookDragTracker {
    private static weak var sourceAppState: AppState?
    private static var isActive = false

    static func begin(_ urls: [URL], from appState: AppState?) {
        isActive = true
        sourceAppState = appState
        // アプリの中のファイルブラウザへ落としたときに「アプリの中から」と読ませる(外からのドロップを「ビューアで開く」設定でも、
        // 本をコピーする。許しているのはコピーだけ)。
        FileBrowserDragTracker.begin(urls)
    }

    static func end() {
        guard isActive else { return }
        isActive = false
        sourceAppState = nil
        FileBrowserDragTracker.end()
    }

    /// `appState` のウインドウから始まったドラッグの最中か(同じウインドウの「本を開く」受け口が断るため)。
    ///
    /// **マウスのボタンが離れているかは見ない** ―― 受け口がドロップを受け取るのはボタンを離した後で、出し口の終わりの知らせ
    /// (`draggingSession(_:endedAt:operation:)`。ここで `end`)はその更に後に来る。
    static func isDragging(from appState: AppState) -> Bool {
        isActive && sourceAppState === appState
    }
}

/// ホームのグリッド(SwiftUI)の本のドラッグの出し口(ファイル冒頭のコメント)。ドラッグ 1 回につき 1 つ作り、終わったら手放す。
@MainActor
final class HomeBookDragSource: NSObject, NSDraggingSource {
    /// いま動いているドラッグ(同時に 1 つ)。
    private static var active: HomeBookDragSource?

    private let scopedURLs: [URL]

    private init(scopedURLs: [URL]) {
        self.scopedURLs = scopedURLs
    }

    /// いまドラッグの最中か(`DragGesture` の `onChanged` はドラッグのあいだ何度も来るので、運ぶ本を割り出す前に見る)。
    static var isDragging: Bool { active != nil }

    /// セルの `DragGesture` が動き出したときに呼ぶ。いまの出来事がマウスのドラッグでなければ、または別のドラッグの最中なら何もしない
    /// (SwiftUI の `onChanged` はドラッグのあいだ何度も来る)。
    ///
    /// - Parameters:
    ///   - books: 運ぶ本(URL と、フォルダの本か)。
    ///   - scopedURLs: ドラッグのあいだセキュリティスコープを開けておく URL(`HomeBookPasteboard.copy` と同じ理由)。
    @discardableResult
    static func begin(books: [(url: URL, isDirectory: Bool)], scopedURLs: [URL] = [], appState: AppState) -> Bool {
        guard active == nil, !books.isEmpty, let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              let view = event.window?.contentView
        else { return false }
        let location = view.convert(event.locationInWindow, from: nil)
        let iconSize: CGFloat = 64
        // 重ねて見せるのは数冊まで(Finder と同じく、動き出すと AppKit が束ねて件数を添える)。
        let items = books.enumerated().map { index, book in
            let item = NSDraggingItem(pasteboardWriter: book.url as NSURL)
            let shift = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(
                NSRect(x: location.x - iconSize / 2 + shift, y: location.y - iconSize / 2 + shift,
                       width: iconSize, height: iconSize),
                contents: icon(for: book.url, isDirectory: book.isDirectory)
            )
            return item
        }
        let source = HomeBookDragSource(scopedURLs: scopedURLs.filter { $0.startAccessingSecurityScopedResource() })
        active = source
        HomeBookDragTracker.begin(books.map(\.url), from: appState)
        let session = view.beginDraggingSession(with: items, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        HomeBookDragTracker.end()
        if Self.active === self { Self.active = nil }
    }

    /// 種類のアイコン(名前だけで引く。ディスクに触らない ―― ネットワークのボリュームでドラッグの出だしが止まらないように)。
    static func icon(for url: URL, isDirectory: Bool) -> NSImage {
        FileBrowserIconProvider.icon(for: FileBrowserEntry(
            url: url, displayName: url.lastPathComponent, isDirectory: isDirectory, isPackage: false,
            isSymbolicLink: false, isVolume: false, fileSize: nil, typeDescription: nil,
            creationDate: nil, modificationDate: nil
        ))
    }
}

extension View {
    /// セルから本をドラッグで運び出す(`HomeBookDragSource`)。`begin` は動いているあいだ何度も呼ばれる
    /// (始めるのは最初の 1 回だけ。`HomeBookDragSource.begin` が見分ける)。
    ///
    /// 動き出すまでの距離を取るので、クリック・ダブルクリック(`.onTapGesture`)はそのまま効く。
    func homeBookDragSource(isEnabled: Bool = true, begin: @escaping @MainActor () -> Void) -> some View {
        gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in begin() },
            including: isEnabled ? .all : .subviews
        )
    }
}

// MARK: - コレクションの作成・登録(ファイルブラウザ・スマートライブラリの右クリック)

extension CollectionMenuLibrary {
    /// 「コレクションに登録」「コレクションを作成」のサブメニューに並べるライブラリとコレクション。本棚と同じ並び順。
    ///
    /// 右クリックのメニューはセルの本体評価のたびに組まれることがある(OpenWithApplications の型コメント)ので、ストアの通し番号と
    /// 並び順・表示言語が変わらない間は `cache` を返す。
    @MainActor
    static func libraries(
        in collectionStore: CollectionStore, sort: FavoritesSortOption, locale: Locale, cache: inout CollectionMenuCache?
    ) -> [CollectionMenuLibrary] {
        if let cached = cache, cached.revision == collectionStore.revision, cached.sort == sort,
           cached.localeIdentifier == locale.identifier {
            return cached.libraries
        }
        let libraries = collectionStore.libraries.map { library in
            CollectionMenuLibrary(
                // 本棚の帯と同じ名前(既定のライブラリは表示言語の訳)。
                id: library.id, name: library.displayName(language: locale),
                collections: collectionStore.collections(in: library, sort: sort).map { ($0.id, $0.name) }
            )
        }
        cache = CollectionMenuCache(
            revision: collectionStore.revision, sort: sort, localeIdentifier: locale.identifier, libraries: libraries
        )
        return libraries
    }

    /// 「コレクションを作成」のサブメニュー(作る先のライブラリ)。ライブラリが 1 つなら選ぶものが無いので nil
    /// (サブメニューにせず、押すとそのまま名前を訊く)。
    static func createMenuNodes(
        for libraries: [CollectionMenuLibrary], create: @escaping @MainActor (UUID) -> Void
    ) -> [FileBrowserMenuNode]? {
        guard libraries.count > 1 else { return nil }
        return libraries.map { library in
            .item(title: library.name, image: nil, isEnabled: true, action: { create(library.id) })
        }
    }

    /// 「コレクションに登録」のサブメニュー。ライブラリが 1 つなら 1 段で並べる(ライブラリの名前を見せる意味が無い)。
    static func addMenuNodes(
        for libraries: [CollectionMenuLibrary], locale: Locale, add: @escaping @MainActor (UUID) -> Void
    ) -> [FileBrowserMenuNode] {
        func collectionItems(_ library: CollectionMenuLibrary) -> [FileBrowserMenuNode] {
            guard !library.collections.isEmpty else {
                return [.item(
                    title: String(localized: "No Collections", language: locale), image: nil, isEnabled: false, action: {}
                )]
            }
            return library.collections.map { collection in
                .item(title: collection.name, image: nil, isEnabled: true, action: { add(collection.id) })
            }
        }
        if libraries.count == 1, let only = libraries.first { return collectionItems(only) }
        return libraries.map { library in
            .submenu(title: library.name, isEnabled: true, children: collectionItems(library))
        }
    }
}

/// `CollectionMenuLibrary.libraries` の控えの入れ物(SwiftUI の画面が持つ。本体評価の中で書き換えるので参照で持つ)。
@MainActor
final class CollectionMenuCacheBox {
    var cache: CollectionMenuCache?
}

/// 本(分類済み)をコレクションへ登録する。ファイルブラウザ・スマートライブラリの「コレクションに登録」が共有する。
@MainActor
enum CollectionBookAdding {
    struct Result {
        let addedTitles: [String]
        let requestedCount: Int
        let collectionName: String
    }

    /// - Returns: 登録した結果。コレクションが待っている間に消された・入れる本が無ければ nil。
    static func add(
        _ books: [URL], to collectionID: UUID,
        collectionStore: CollectionStore?, coverExtractor: CollectionCoverExtractor?
    ) async -> Result? {
        // ブックマークの生成はメインアクターの外で(CollectionStore.makePendingItemsのコメント)。
        let pending = await CollectionStore.makePendingItems(for: books)
        // 待っている間に消されたコレクションには足さない(idで引き直す。WelcomeDropHandling.handle と同じ)。
        guard let collectionStore, let collection = collectionStore.collection(withID: collectionID), !pending.isEmpty
        else { return nil }
        // 足してから表紙の抽出を頼む。`coverExtractor?.enqueue(store.add(...))` と 1 行で書くと、抽出役が居ないときに
        // 引数ごと評価されず、本が足されない(テストで踏んだ)。
        let added = collectionStore.add(pending, to: collection)
        coverExtractor?.enqueue(added)
        return Result(addedTitles: added.map(\.title), requestedCount: pending.count, collectionName: collection.name)
    }
}
