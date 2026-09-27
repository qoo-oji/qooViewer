import AppKit
import SwiftUI

/// 起動時、まだ何も開いていないときに表示する画面(改善要望5で全面的に作り直した)。
///
/// 以前は「開く…」ボタンと、最近開いたファイル/最近のお気に入りの2列を中央に置いただけの
/// 画面だった。いまは**本棚**を持つ ―― 上の帯でライブラリを選び、その下にコレクション(本を
/// 束ねた棚)をカバー付きのタイルで並べ、タイルをクリックすると中の本が並ぶ。従来どおり
/// ドラッグ&ドロップやボタンから直接開くこともでき、履歴は帯の「履歴から開く」へ畳んだ。
///
/// ■ 編集モード
/// 右上の鉛筆ボタンの**編集モード**は、コレクションに入れる・外す操作を前に出すモード(2026-09-27 から。
/// WelcomeLibraryState.isEditing)。ドロップの意味(開く / 登録する)を切り替え、削除(ゴミ箱・右クリックの削除)を出す。
/// クリックの意味は変えない(いつでも選ぶ)。本を開いた時点で編集モードは解除される(ContentView)。
///
/// ■ シークレットウインドウ
/// 編集モードに入れない(`allowsEditing == false`)。コレクションの登録はDBへの書き込みで、
/// 「シークレットウインドウは何も記録しない」という約束から外れるため(AppState.isPrivateWindow
/// のコメント参照)。閲覧と、そこから本を開くことは通常どおりできる。
///
/// ■ すりガラス面の決まりごと
/// この画面全体が`PanelSurface.welcome`。文字・アイコンには`.panelOutlinedContent()`、
/// 選択中のライブラリのようにアクセント色で状態を示すものには`.panelOutlinedAccent(in:)`、
/// スライダーには`.panelControlWell()`を掛けてある(各部品のコメント参照)。
struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var preferences: AppPreferences
    /// 外観タブの設定。本のウインドウではそのウインドウの揃い(ノーマル/シークレット。ContentView が渡す)。
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var coverExtractor: CollectionCoverExtractor
    @EnvironmentObject private var autoFolderScanner: CollectionAutoFolderScanner
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @ObservedObject var state: WelcomeLibraryState
    /// ファイルブラウザの閲覧状態(改善要望7 段階3)。ウインドウに1つ(ContentViewが持つ)。
    let fileBrowser: FileBrowserState
    /// スマートライブラリの表示の状態。ウインドウに1つ(ContentViewが持つ。開いている束へ戻れるように)。
    let smartLibrary: SmartLibraryViewState

    /// 編集操作を許すか。シークレットウインドウでは常にfalse(型コメント参照)。
    private var allowsEditing: Bool { !appState.isPrivateWindow }
    /// ホームの下に短く出す知らせ(AppState.viewerNotice。ドロップで開かなかった・登録しなかったもの。2026-09-27)。
    @State private var noticeMessage: String?
    @State private var noticeDismissTask: Task<Void, Never>?

    /// いま見ているライブラリ。保存されていたidの実体が無ければ先頭へ読み替える
    /// (別のウインドウで削除された場合。ライブラリは必ず1つ以上ある ――
    /// CollectionStore.ensureDefaultLibrary)。
    private var library: BookLibrary? {
        // ライブラリ機能がOFFの間は引かない(名前を訊くシートも出さない)。
        guard state.isLibraryFeatureEnabled else { return nil }
        return WelcomeDropHandling.resolvedLibrary(state: state, collectionStore: collectionStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ライブラリもスマートライブラリも OFF の間は帯ごと出さない(環境設定「一般」→「ホーム」。2026-09-21、ユーザー要望) ――
            // 帯に並ぶのはモードの切り替えとライブラリで、ファイルブラウザしか無いなら置く意味が無い(WelcomeLibraryState.showsTopBar)。
            if state.showsTopBar {
                WelcomeTopBar(
                    state: state, allowsEditing: allowsEditing, selectedLibraryID: library?.id
                )
                // 標準の Divider はすりガラスの上で薄く、帯と中身の境目が読みにくい(WelcomeSeparator参照)。
                WelcomeSeparator(axis: .horizontal)
            }
            // 中身は `mode` で決まる。環境設定で機能をOFFにしている間は、そのモードを出さない
            // (WelcomeLibraryState.constrained): 出せないモードは、本棚 → ファイルブラウザ → スマートライブラリの順で最初に出せるものへ読み替え、
            // 3つともOFFなら本棚を足す前のウェルカム画面。
            if state.mode == .classic {
                ClassicWelcomeView()
            } else if state.mode == .browser {
                FileBrowserPane(state: fileBrowser)
            } else if state.mode == .smart, state.isSmartLibraryFeatureEnabled {
                SmartLibraryPane(home: state, state: smartLibrary, allowsEditing: allowsEditing)
            } else if let library {
                WelcomeLibraryPane(state: state, library: library, allowsEditing: allowsEditing)
            } else {
                Spacer(minLength: 0)
            }
            // ファイル操作の進捗の帯は、ふだんはファイルブラウザのペインの中(パスバーの上)に出る。**操作の最中にペインが消えても**
            // (本棚へ切り替えた・環境設定でファイルブラウザを OFF にした)操作は最後まで続くので、帯と中止ボタンはここへ引き継ぐ
            // (2026-09-21 の監査 docs/plans/feature-toggle-audit.md §4 ―― 以前は進捗も中止の手段もペインごと消えた)。動いていなければ何も描かない。
            // 地は不透明(controlBackgroundColor)なので、すりガラス面の輪郭は掛けない(FileBrowserProgressBar の型コメント)。
            if state.mode != .browser {
                FileBrowserProgressBar(operations: fileBrowser.operations)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ⌘= でも「拡大」(表示メニューの ⌘+ は US 配列の ⌘= で届かない。HomeZoomInEqualsKeyMonitor)。
        .homeZoomInEqualsKey(appState: appState)
        // 環境設定「外観」の「ウェルカム画面」に従う背景。「ウインドウの背後を透かす」
        // (welcomeGlass。既定OFF)がONのときだけ、背後のウインドウ/デスクトップが
        // わずかに透けるすりガラス+重ね色を敷く(ユーザー要望: のっぺりして見える。
        // ただし既定では従来どおり、ウインドウの地の色のまま何も敷かない ―― 従来からの
        // ユーザーは設定を変更しなければ見た目が変わらないこと、というユーザーの指定)。
        // .underWindowBackgroundは「ウインドウのコンテンツ背景」用のいちばん控えめな
        // マテリアルで、メモ.appの本文背景などと同じもの。2層の構成の意味は
        // panelSurfaceBackgroundと同じだが、画面全体に敷くため安全領域も無視して広げる。
        .panelContentOutline(
            width: appearance.welcomeGlass
                ? PanelContentShadow.outlineWidth(
                    forLevel: appearance.welcomeSurfaceStyle.contentShadowLevel
                )
                : 0
        )
        .background {
            if appearance.welcomeGlass {
                ZStack {
                    BehindWindowVisualEffectView(material: .underWindowBackground)
                        .opacity(appearance.welcomeSurfaceStyle.materialOpacity)
                    appearance.welcomeSurfaceStyle.resolvedTint
                }
                .ignoresSafeArea()
            }
        }
        // 知らせ(AppState.viewerNotice)。ビューアと同じく下に浮かべ、クリックは下へ通す。本を開く前に出した知らせも拾う(isFresh)。
        .overlay(alignment: .bottom) {
            ZStack {
                if let noticeMessage {
                    OverlayToast(message: noticeMessage)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 48)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: noticeMessage)
        }
        .onChange(of: appState.viewerNotice) { _, notice in
            if let notice { showNotice(notice.message) }
        }
        .onAppear {
            if let notice = appState.viewerNotice, notice.isFresh { showNotice(notice.message) }
        }
        // 名前を訊くシート。棚をまとめてドロップすると複数たまるので、1枚を開いたまま中身だけ
        // 差し替えて順に処理し、行列が空になった時点で閉じる(CollectionNameSheet.
        // dismissesOnFinishのコメント参照)。
        .sheet(
            isPresented: Binding(
                get: { !state.pendingCreations.isEmpty },
                set: { if !$0 { state.pendingCreations = [] } }
            )
        ) {
            creationSheet
        }
        // ファイル/フォルダのドロップの受け口はウインドウ全体に1つだけ
        // (ContentView.applyFileDropTarget)。ウェルカム画面が出ている間だけ、その手前に
        // 割り込ませてもらう(AppState.welcomeDropHandler参照)。
        // 外側のonAppearでも、中で弱く捕まえる4つを**明示的に**捕まえる。Swift 6.4(Xcode 27)は
        // 「中で`weak`なのに外側が暗黙に強く捕まえている」形を警告する(#ImplicitStrongCapture)。
        // 捕まえ方は今までと同じで、AppStateに預ける閉包が弱いまま、という下のコメントの肝は変わらない。
        .onAppear { [state, collectionStore, coverExtractor, preferences, appState] in
            // ライブラリ機能がOFFの間は、下の2つは呼んでも何もしない(それぞれの isLibraryFeatureEnabled)。ドロップの受け口は
            // 編集モードのときだけ引き受けるので、編集モードに入れないOFFの間は常に「本を開く」へ回る。
            coverExtractor.refill()
            // 自動登録フォルダを見に行く契機のひとつ(CollectionAutoFolderScannerの型コメント
            // 参照。監視の取りこぼしを、この画面を見にきた時点で回収する)。
            autoFolderScanner.scheduleScan()
            // **このViewの値(self)を閉包に捕まえない**(監査で指摘 2026-09-09)。捕まえると
            // AppState → 閉包 → WelcomeViewの写し → @EnvironmentObject → AppState の循環になり、
            // onDisappearが来るまで(来なければずっと)AppStateが解放されない。要るものだけを
            // weakで捕まえ、振り分けの本体は状態を持たないWelcomeDropHandlingに置いてある。
            let allowsEditing = allowsEditing
            appState.welcomeDropHandler = {
                [weak state, weak collectionStore, weak coverExtractor, weak preferences, weak appState] urls in
                guard let state, let collectionStore, let coverExtractor, let preferences else {
                    return false
                }
                return WelcomeDropHandling.handle(
                    urls, allowsEditing: allowsEditing, state: state,
                    collectionStore: collectionStore, coverExtractor: coverExtractor,
                    preferences: preferences,
                    notify: { appState?.postViewerNotice($0) }
                )
            }
        }
        .onDisappear {
            appState.welcomeDropHandler = nil
        }
    }

    private func showNotice(_ message: String) {
        noticeDismissTask?.cancel()
        noticeMessage = message
        noticeDismissTask = Task { @MainActor in
            try? await Task.sleep(for: FileBrowserState.toastDuration)
            guard !Task.isCancelled else { return }
            noticeMessage = nil
        }
    }

    @ViewBuilder
    private var creationSheet: some View {
        // 作る先: ファイルブラウザのサブメニューで選んだライブラリ(PendingCollectionCreation.libraryID)、無ければ選んでいるライブラリ。
        if let creation = state.pendingCreations.first,
           let library = creation.libraryID.flatMap({ collectionStore.library(withID: $0) }) ?? library {
            CollectionNameSheet(
                kind: .newCollection,
                initialName: creation.defaultName,
                isDuplicate: { collectionStore.hasCollectionNamed($0, in: library) },
                autoFolder: .init(initial: creation.autoFolder),
                onCommit: { name, autoFolder in
                    finishCreation(creation, name: name, autoFolder: autoFolder, in: library)
                },
                onCancel: { dropFirstPendingCreation() },
                dismissesOnFinish: false
            )
            // 次の1件へ差し替わったときに、名前欄と検証の状態を作り直す。
            .id(creation.id)
        }
    }

    // MARK: - 作成

    /// - Parameter autoFolder: シートで選ばれた自動登録フォルダ(未選択ならnil)。
    private func finishCreation(
        _ creation: WelcomeLibraryState.PendingCollectionCreation, name: String,
        autoFolder: URL?, in library: BookLibrary
    ) {
        dropFirstPendingCreation()
        let order = preferences.siblingBookOrder
        Task {
            var books = creation.books
            // 「＋」から作って自動登録フォルダだけを選んだ場合は、そのフォルダに並んでいる本で
            // 棚を作る ―― 指定した瞬間に中身が入るほうが素直で、そうしないと「空の棚は作らない」
            // 方針(CollectionStore.createCollection)に阻まれて、行が作られないまま
            // 「本を追加」パネルだけが開くことになる。
            if books.isEmpty, let autoFolder, folderAccess.isPathCovered(autoFolder) {
                books = await Task.detached(priority: .userInitiated) {
                    CollectionAutoFolderScan.books(in: autoFolder, order: order)
                }.value
            }
            // ブックマークの生成はメインアクターの外で(CollectionStore.makePendingItemsのコメント参照)。
            let pending = await CollectionStore.makePendingItems(for: books)
            // 本の入っていない作成(「＋」から)は、行を作らずに「本を追加」パネルへ進む。
            // 1冊目が入った時点でCollectionStore.createCollectionが行を作る ―― 選ばれていた
            // 自動登録フォルダも、そのときに書き込めるようパネルへ持たせる。
            //
            // ドロップから来た作成では、ここへ来るのは落とされたものが1つも本にならなかった
            // ときだけ。空のパネルを出しても入れるものが無いので、何もせず終わる。
            guard !pending.isEmpty else {
                guard !creation.fromDrop else { return }
                presentAddBooks(
                    .init(
                        collectionID: nil, name: name, libraryID: library.id,
                        autoFolder: autoFolder
                    )
                )
                return
            }
            guard let created = collectionStore.createCollection(
                name: name, in: library, items: pending
            ) else { return }
            if let autoFolder {
                collectionStore.setAutoFolder(autoFolder, for: created)
                // 棚のフォルダを落として作ったときは、そのフォルダの許可も預ける(2026-09-27)。落としたフォルダにはドロップの
                // 許可が付いているが、自動登録フォルダを走査するのは FolderAccessStore が覆う場所だけなので、預けないと
                // 「アクセスを許可」待ちのまま止まっていた(docs/14 の「フォルダをドロップ → 権限も付いてくる」はこれで本当になる)。
                // シートで別のフォルダへ変えたときは、そのフォルダの許可は付いてこないので預けない。
                if creation.fromDrop, creation.fromShelf, autoFolder == creation.autoFolder,
                   !folderAccess.isPathCovered(autoFolder) {
                    folderAccess.add(url: autoFolder)
                }
            }
            coverExtractor.enqueue(collectionStore.items(in: created, sort: .dateAddedAscending))
            // **ドロップで作ったときはパネルを出さない**(ユーザー指示 2026-09-09)。
            // 入れたい本はドロップで渡し終えているので、そのうえで空の「本を追加」パネルが
            // 出るのは、棚を1つ作るたびに閉じるだけの手間が増えるということでしかない。
            // 「＋」から作ったときだけは、本を入れる場がそこにしか無いので開く
            // (作成の直後は本が入った状態で開き、そのまま足せる)。
            guard !creation.fromDrop else { return }
            presentAddBooks(
                .init(
                    collectionID: created.id, name: created.name, libraryID: library.id,
                    autoFolder: autoFolder
                )
            )
        }
    }

    private func dropFirstPendingCreation() {
        guard !state.pendingCreations.isEmpty else { return }
        state.pendingCreations.removeFirst()
    }

    /// 閉じかけのシートの上へ次のシートを重ねないよう、1回だけ実行を遅らせる。
    private func presentAddBooks(_ target: WelcomeLibraryState.AddBooksTarget) {
        DispatchQueue.main.async {
            state.addingBooks = target
        }
    }
}

/// ウェルカム画面へのドロップの振り分け(WelcomeView.handleDropから切り出したもの)。
///
/// Viewの外にあるのは、AppState.welcomeDropHandlerへ登録する閉包に**Viewの値を捕まえさせない**
/// ため(WelcomeView.onAppearのコメント参照)。状態は持たず、要るものはすべて引数で受ける。
@MainActor
enum WelcomeDropHandling {
    /// いま見ているライブラリ。保存されていたidの実体が無ければ先頭へ読み替える
    /// (別のウインドウで削除された場合。ライブラリは必ず1つ以上ある ――
    /// CollectionStore.ensureDefaultLibrary)。
    static func resolvedLibrary(
        state: WelcomeLibraryState, collectionStore: CollectionStore
    ) -> BookLibrary? {
        state.selectedLibraryID.flatMap { collectionStore.library(withID: $0) }
            ?? collectionStore.libraries.first
    }

    /// ウインドウへ落とされたURLの振り分け。`true`を返したらこのドロップは処理済みで、
    /// 本を開く処理へは回さない。
    ///
    /// **編集モードのときだけ引き受ける。** 閲覧中のドロップは従来どおり「その本を開く」で、
    /// 意味が変わるのは編集モードに入っている間だけ、という1つの規則にしてある。
    /// (タイルの上に落としたときは、タイル自身の受け口が先に受ける ―― `addDropped(_:toCollection:…)`。)
    ///
    /// 本にならなかったもの・既に入っていた本は `notify` で知らせる(2026-09-27。以前は黙っていた)。
    ///
    /// - Parameter onFinished: 振り分け(フォルダの列挙を伴うのでメインアクターの外で走る)が
    ///   終わり、結果を積み終えたときに呼ぶ(**テストのための口**。画面は渡さない)。
    static func handle(
        _ urls: [URL], allowsEditing: Bool, state: WelcomeLibraryState,
        collectionStore: CollectionStore, coverExtractor: CollectionCoverExtractor,
        preferences: AppPreferences, notify: @escaping @MainActor (String) -> Void = { _ in },
        onFinished: (@MainActor () -> Void)? = nil
    ) -> Bool {
        guard allowsEditing, state.isEditing, !urls.isEmpty,
              resolvedLibrary(state: state, collectionStore: collectionStore) != nil
        else { return false }
        let order = preferences.siblingBookOrder
        let locale = preferences.effectiveLocale
        let openedCollectionID = state.openedCollectionID
        Task {
            let classified = await CollectionDropClassifier.classifyAsync(urls, order: order)
            if let openedCollectionID,
               collectionStore.collection(withID: openedCollectionID) != nil {
                await add(
                    classified, toCollection: openedCollectionID,
                    collectionStore: collectionStore, coverExtractor: coverExtractor, locale: locale, notify: notify
                )
            } else {
                let skipped = classified.filter { if case .ignored = $0 { true } else { false } }.count
                if queueCreations(from: classified, into: state) {
                    if skipped > 0 { notify(skippedMessage(skipped, locale: locale)) }
                } else {
                    notify(noBooksMessage(locale: locale))
                }
            }
            onFinished?()
        }
        return true
    }

    /// タイルの上に落とされた本を、そのコレクションへ足す(編集モードのとき。2026-09-27、ホームの操作の統一 ―― 以前はタイルの上でも
    /// 一覧の余白と同じく新しいコレクションを作っていた)。
    static func addDropped(
        _ urls: [URL], toCollection collectionID: UUID, collectionStore: CollectionStore,
        coverExtractor: CollectionCoverExtractor, preferences: AppPreferences,
        notify: @escaping @MainActor (String) -> Void
    ) {
        guard !urls.isEmpty else { return }
        let order = preferences.siblingBookOrder
        let locale = preferences.effectiveLocale
        Task {
            let classified = await CollectionDropClassifier.classifyAsync(urls, order: order)
            await add(
                classified, toCollection: collectionID,
                collectionStore: collectionStore, coverExtractor: coverExtractor, locale: locale, notify: notify
            )
        }
    }

    /// 振り分けたものをコレクションへ足し、結果を知らせる(棚は中の本に展開する)。
    private static func add(
        _ classified: [CollectionDropClassifier.Item], toCollection collectionID: UUID,
        collectionStore: CollectionStore, coverExtractor: CollectionCoverExtractor,
        locale: Locale, notify: @MainActor (String) -> Void
    ) async {
        let books = CollectionDropClassifier.booksToAdd(from: classified)
        let skipped = classified.filter { if case .ignored = $0 { true } else { false } }.count
        guard !books.isEmpty else {
            notify(noBooksMessage(locale: locale))
            return
        }
        // ブックマークの生成はメインアクターの外で(CollectionStore.makePendingItemsの
        // コメント参照)。待っている間に消されたコレクションには足さないよう、戻ってから
        // idで引き直す。
        let pending = await CollectionStore.makePendingItems(for: books)
        guard let collection = collectionStore.collection(withID: collectionID), !pending.isEmpty else { return }
        let added = collectionStore.add(pending, to: collection)
        coverExtractor.enqueue(added)
        var message = FileBrowserActions.addedToCollectionMessage(
            addedTitles: added.map(\.title), requestedCount: pending.count, collectionName: collection.name, locale: locale
        )
        if skipped > 0 { message += " " + skippedMessage(skipped, locale: locale) }
        notify(message)
    }

    /// 落としたものに本が 1 つも無かった(ばらの画像・中間フォルダ・空のフォルダ・対応しないファイル)。
    static func noBooksMessage(locale: Locale) -> String {
        String(
            localized: "Nothing was added. Archives, PDF and EPUB files, and folders of images can be used as books.",
            language: locale
        )
    }

    /// 本でないので登録しなかった数。
    static func skippedMessage(_ count: Int, locale: Locale) -> String {
        count == 1
            ? String(localized: "1 item wasn’t added because it isn’t a book.", language: locale)
            : String(format: String(localized: "%lld items weren’t added because they aren’t books.", language: locale), count)
    }

    /// 一覧へのドロップ。ばらの本はまとめて1つのコレクションに、棚(本が並んだフォルダ)は
    /// フォルダ名を既定の名前にしたコレクションに、それぞれ1件ずつ名前の入力待ちへ積む。
    ///
    /// ファイルブラウザの右クリック「コレクションを作成」も同じ振り分けで積む(改善要望7 段階 8。
    /// 名前を訊くシートはこの画面が持つので、ファイルブラウザを出したままでも出る)。
    ///
    /// - Returns: 1件でも積んだか(何も本にならなかったら false)。
    @discardableResult
    static func queueCreations(
        from classified: [CollectionDropClassifier.Item], into state: WelcomeLibraryState, libraryID: UUID? = nil
    ) -> Bool {
        var queued: [WelcomeLibraryState.PendingCollectionCreation] = []
        let looseBooks = classified.compactMap { item -> URL? in
            if case .book(let url) = item { return url }
            return nil
        }
        if !looseBooks.isEmpty {
            queued.append(
                .init(
                    defaultName: "", books: looseBooks, fromShelf: false, fromDrop: true,
                    autoFolder: commonParentFolder(of: looseBooks), libraryID: libraryID
                )
            )
        }
        for item in classified {
            guard case .shelf(let folder, let books) = item else { continue }
            queued.append(
                .init(
                    defaultName: folder.lastPathComponent, books: books, fromShelf: true,
                    fromDrop: true, autoFolder: folder, libraryID: libraryID
                )
            )
        }
        guard !queued.isEmpty else { return false }
        state.pendingCreations.append(contentsOf: queued)
        return true
    }

    /// 落とされた本が全部同じフォルダに入っていたなら、そのフォルダ。
    ///
    /// **1つに定まらないときはnil**(空欄)にする ―― 別々の場所から集めた本で棚を作ったときに、
    /// そのうちの1つのフォルダだけが自動登録フォルダとして選ばれていると、なぜそこなのかが
    /// 画面から読めない。
    ///
    /// ここで返るフォルダには**列挙する権限が付いてこない**(サンドボックスが許すのは落とされた
    /// ファイルそのものだけ。CLAUDE.md)。初期値としてパスを出すだけで、実際に走査が始まるのは
    /// ユーザーがアクセスを許可してから(CollectionAutoFolderRow参照)。
    private static func commonParentFolder(of books: [URL]) -> URL? {
        let parents = Set(books.map { $0.deletingLastPathComponent().path })
        guard parents.count == 1, let path = parents.first else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
