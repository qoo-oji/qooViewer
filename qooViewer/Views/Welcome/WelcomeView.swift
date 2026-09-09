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
/// コレクションの作成・リネーム・削除、本の追加・削除は、右上の鉛筆ボタンで**編集モード**に
/// 入っている間だけできる。閲覧中に誤って棚を壊さないためと、ドロップの意味(開く / 登録する)を
/// 1つのモードで切り替えるため。本を開いた時点で編集モードは解除される(ContentView)。
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
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var coverExtractor: CollectionCoverExtractor
    @EnvironmentObject private var autoFolderScanner: CollectionAutoFolderScanner
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @ObservedObject var state: WelcomeLibraryState

    /// 編集操作を許すか。シークレットウインドウでは常にfalse(型コメント参照)。
    private var allowsEditing: Bool { !appState.isPrivateWindow }

    /// いま見ているライブラリ。保存されていたidの実体が無ければ先頭へ読み替える
    /// (別のウインドウで削除された場合。ライブラリは必ず1つ以上ある ――
    /// CollectionStore.ensureDefaultLibrary)。
    private var library: BookLibrary? {
        WelcomeDropHandling.resolvedLibrary(state: state, collectionStore: collectionStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            WelcomeTopBar(
                state: state, allowsEditing: allowsEditing, selectedLibraryID: library?.id
            )
            Divider()
            if let library {
                WelcomeLibraryPane(state: state, library: library, allowsEditing: allowsEditing)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 環境設定「外観」の「ウェルカム画面」に従う背景。「ウインドウの背後を透かす」
        // (welcomeGlass。既定OFF)がONのときだけ、背後のウインドウ/デスクトップが
        // わずかに透けるすりガラス+重ね色を敷く(ユーザー要望: のっぺりして見える。
        // ただし既定では従来どおり、ウインドウの地の色のまま何も敷かない ―― 従来からの
        // ユーザーは設定を変更しなければ見た目が変わらないこと、というユーザーの指定)。
        // .underWindowBackgroundは「ウインドウのコンテンツ背景」用のいちばん控えめな
        // マテリアルで、メモ.appの本文背景などと同じもの。2層の構成の意味は
        // panelSurfaceBackgroundと同じだが、画面全体に敷くため安全領域も無視して広げる。
        .panelContentOutline(
            width: preferences.welcomeGlass
                ? PanelContentShadow.outlineWidth(
                    forLevel: preferences.welcomeSurfaceStyle.contentShadowLevel
                )
                : 0
        )
        .background {
            if preferences.welcomeGlass {
                ZStack {
                    BehindWindowVisualEffectView(material: .underWindowBackground)
                        .opacity(preferences.welcomeSurfaceStyle.materialOpacity)
                    preferences.welcomeSurfaceStyle.resolvedTint
                }
                .ignoresSafeArea()
            }
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
        .onAppear {
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
                [weak state, weak collectionStore, weak coverExtractor, weak preferences] urls in
                guard let state, let collectionStore, let coverExtractor, let preferences else {
                    return false
                }
                return WelcomeDropHandling.handle(
                    urls, allowsEditing: allowsEditing, state: state,
                    collectionStore: collectionStore, coverExtractor: coverExtractor,
                    preferences: preferences
                )
            }
        }
        .onDisappear {
            appState.welcomeDropHandler = nil
        }
    }

    @ViewBuilder
    private var creationSheet: some View {
        if let creation = state.pendingCreations.first, let library {
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
            let pending = books.compactMap(CollectionStore.makePendingItem(for:))
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
    ///
    /// - Parameter onFinished: 振り分け(フォルダの列挙を伴うのでメインアクターの外で走る)が
    ///   終わり、結果を積み終えたときに呼ぶ(**テストのための口**。画面は渡さない)。
    static func handle(
        _ urls: [URL], allowsEditing: Bool, state: WelcomeLibraryState,
        collectionStore: CollectionStore, coverExtractor: CollectionCoverExtractor,
        preferences: AppPreferences, onFinished: (@MainActor () -> Void)? = nil
    ) -> Bool {
        guard allowsEditing, state.isEditing, !urls.isEmpty,
              resolvedLibrary(state: state, collectionStore: collectionStore) != nil
        else { return false }
        let order = preferences.siblingBookOrder
        let openedCollectionID = state.openedCollectionID
        Task {
            let classified = await CollectionDropClassifier.classifyAsync(urls, order: order)
            if let openedCollectionID,
               let collection = collectionStore.collection(withID: openedCollectionID) {
                addBooks(
                    CollectionDropClassifier.booksToAdd(from: classified), to: collection,
                    collectionStore: collectionStore, coverExtractor: coverExtractor
                )
            } else {
                queueCreations(from: classified, into: state)
            }
            onFinished?()
        }
        return true
    }

    private static func addBooks(
        _ urls: [URL], to collection: BookCollection,
        collectionStore: CollectionStore, coverExtractor: CollectionCoverExtractor
    ) {
        let pending = urls.compactMap(CollectionStore.makePendingItem(for:))
        guard !pending.isEmpty else { return }
        coverExtractor.enqueue(collectionStore.add(pending, to: collection))
    }

    /// 一覧へのドロップ。ばらの本はまとめて1つのコレクションに、棚(本が並んだフォルダ)は
    /// フォルダ名を既定の名前にしたコレクションに、それぞれ1件ずつ名前の入力待ちへ積む。
    private static func queueCreations(
        from classified: [CollectionDropClassifier.Item], into state: WelcomeLibraryState
    ) {
        var queued: [WelcomeLibraryState.PendingCollectionCreation] = []
        let looseBooks = classified.compactMap { item -> URL? in
            if case .book(let url) = item { return url }
            return nil
        }
        if !looseBooks.isEmpty {
            queued.append(
                .init(
                    defaultName: "", books: looseBooks, fromShelf: false, fromDrop: true,
                    autoFolder: commonParentFolder(of: looseBooks)
                )
            )
        }
        for item in classified {
            guard case .shelf(let folder, let books) = item else { continue }
            queued.append(
                .init(
                    defaultName: folder.lastPathComponent, books: books, fromShelf: true,
                    fromDrop: true, autoFolder: folder
                )
            )
        }
        guard !queued.isEmpty else { return }
        state.pendingCreations.append(contentsOf: queued)
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
