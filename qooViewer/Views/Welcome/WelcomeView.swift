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
    @ObservedObject var state: WelcomeLibraryState

    /// 編集操作を許すか。シークレットウインドウでは常にfalse(型コメント参照)。
    private var allowsEditing: Bool { !appState.isPrivateWindow }

    /// いま見ているライブラリ。保存されていたidの実体が無ければ先頭へ読み替える
    /// (別のウインドウで削除された場合。ライブラリは必ず1つ以上ある ――
    /// CollectionStore.ensureDefaultLibrary)。
    private var library: BookLibrary? {
        state.selectedLibraryID.flatMap { collectionStore.library(withID: $0) }
            ?? collectionStore.libraries.first
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
            appState.welcomeDropHandler = { urls in handleDrop(urls) }
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
                onCommit: { name in finishCreation(creation, name: name, in: library) },
                onCancel: { dropFirstPendingCreation() },
                dismissesOnFinish: false
            )
            // 次の1件へ差し替わったときに、名前欄と検証の状態を作り直す。
            .id(creation.id)
        }
    }

    // MARK: - 作成

    private func finishCreation(
        _ creation: WelcomeLibraryState.PendingCollectionCreation, name: String, in library: BookLibrary
    ) {
        dropFirstPendingCreation()
        let pending = creation.books.compactMap(CollectionStore.makePendingItem(for:))
        // 本の入っていない作成(「＋」から)は、行を作らずに「本を追加」パネルへ進む。
        // 1冊目が入った時点でCollectionStore.createCollectionが行を作る。
        guard !pending.isEmpty else {
            presentAddBooks(.init(collectionID: nil, name: name, libraryID: library.id))
            return
        }
        guard let created = collectionStore.createCollection(
            name: name, in: library, items: pending
        ) else { return }
        coverExtractor.enqueue(collectionStore.items(in: created, sort: .dateAddedAscending))
        // 要望どおり、作成のあとは本が入った状態の「本を追加」パネルを開く(そのまま足せる)。
        presentAddBooks(.init(collectionID: created.id, name: created.name, libraryID: library.id))
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

    // MARK: - ドロップ

    /// ウインドウへ落とされたURLの振り分け。`true`を返したらこのドロップは処理済みで、
    /// 本を開く処理へは回さない。
    ///
    /// **編集モードのときだけ引き受ける。** 閲覧中のドロップは従来どおり「その本を開く」で、
    /// 意味が変わるのは編集モードに入っている間だけ、という1つの規則にしてある。
    private func handleDrop(_ urls: [URL]) -> Bool {
        guard allowsEditing, state.isEditing, !urls.isEmpty, library != nil else { return false }
        let order = preferences.siblingBookOrder
        let openedCollectionID = state.openedCollectionID
        Task {
            let classified = await CollectionDropClassifier.classifyAsync(urls, order: order)
            if let openedCollectionID,
               let collection = collectionStore.collection(withID: openedCollectionID) {
                addBooks(CollectionDropClassifier.booksToAdd(from: classified), to: collection)
            } else {
                queueCreations(from: classified)
            }
        }
        return true
    }

    private func addBooks(_ urls: [URL], to collection: BookCollection) {
        let pending = urls.compactMap(CollectionStore.makePendingItem(for:))
        guard !pending.isEmpty else { return }
        coverExtractor.enqueue(collectionStore.add(pending, to: collection))
    }

    /// 一覧へのドロップ。ばらの本はまとめて1つのコレクションに、棚(本が並んだフォルダ)は
    /// フォルダ名を既定の名前にしたコレクションに、それぞれ1件ずつ名前の入力待ちへ積む。
    private func queueCreations(from classified: [CollectionDropClassifier.Item]) {
        var queued: [WelcomeLibraryState.PendingCollectionCreation] = []
        let looseBooks = classified.compactMap { item -> URL? in
            if case .book(let url) = item { return url }
            return nil
        }
        if !looseBooks.isEmpty {
            queued.append(.init(defaultName: "", books: looseBooks, fromShelf: false))
        }
        for item in classified {
            guard case .shelf(let name, let books) = item else { continue }
            queued.append(.init(defaultName: name, books: books, fromShelf: true))
        }
        guard !queued.isEmpty else { return }
        state.pendingCreations.append(contentsOf: queued)
    }
}
