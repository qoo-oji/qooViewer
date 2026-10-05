import AppKit
import SwiftUI

/// コレクションへ本を入れるシート(改善要望5)。「＋」で新しいコレクションを作った直後と、
/// 編集モード中に既存のコレクションへ本を足すときの両方で出る。
///
/// ■ 「まだ行の無いコレクション」を相手にすることがある
/// 1冊も入らないコレクションは作らない方針(CollectionStore.createCollection参照)なので、
/// 「＋」で名前を決めた直後はまだ行が無い。1冊目が入った時点で`createCollection`が行を作り、
/// 2冊目以降は`add(_:to:)`。1冊も入れずに閉じれば何も残らない ―― つまり空のまま閉じる操作が
/// そのまま取り消しになる。
///
/// ■ 一覧に出るのは**この面で入れたぶんだけ**
/// 以前は入れ先のコレクションの中身を丸ごと並べていたが、既に入っている本が並んでいると、
/// いま落とした本がどれなのか読めない(ユーザー指摘 2026-09-09: 「すでに追加済みのファイルは
/// 表示しないでほしい。まぎらわしい」)。この面を開いてから入った本だけを、入った順に積む。
/// 棚全体の冊数は見出しのコレクション名の隣に出ているので、そちらで分かる。
///
/// 既に入っている本を落としたときは、`CollectionStore.add(_:to:)`がパス/iノードで弾くため
/// 行は増えない ―― 「追加済みは出さない」がそのまま成り立つ。
///
/// ■ ドロップを自前で受ける理由
/// シートは別のNSWindowなので、ウインドウ本体に付けた唯一のドロップ受け口
/// (ContentView.applyFileDropTarget)には届かない。URLの取り出しだけは共通の
/// `fileURLDropTarget`を通す(BookFileDropTarget.swiftのコメント参照)。
///
/// シートの中身はmacOSが不透明に描くので、すりガラス面の輪郭は要らない(CLAUDE.md参照)。
struct AddBooksPanel: View {
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var coverExtractor: CollectionCoverExtractor
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    /// 対象。1冊目が入ると`collectionID`が埋まる。
    @Binding var target: WelcomeLibraryState.AddBooksTarget

    @State private var isDropTargeted = false
    /// 追加の判定(フォルダの列挙を伴う)が走っている間。二重に走らせない。
    @State private var isAdding = false
    /// 振り分けている間に落とされた分(2026-10-04 の監査 H-7)。今の回が終わったら続けて足す。以前は受け口が強調して受け取った
    /// うえで `add` の `!isAdding` で黙って捨てていた(NAS 上の大きなフォルダを落とした直後にもう 1 つ落とすと、2 つ目が消えた)。
    @State private var queuedURLs: [URL] = []
    /// 最後の追加で入れなかったもの(本でない・既に入っていた)の知らせ。無ければ nil(2026-09-27。以前は黙っていた)。
    @State private var notice: String?

    private var collection: BookCollection? {
        target.collectionID.flatMap { collectionStore.collection(withID: $0) }
    }

    /// 入れ先のライブラリ。カバーの縦横比だけのために引く(この一覧の22ptのセルも、
    /// 一覧に並んだときと同じ形で出したい)。
    private var library: BookLibrary? {
        collectionStore.library(withID: target.libraryID)
    }

    /// この面で入れた本(入った順)。
    ///
    /// **モデルの参照ではなくidで覚えておく**(CollectionDetailView.missingBookと同じ理由)。
    /// この面を出している間に別のウインドウが同じ本をコレクションから外してsaveすると、
    /// `CollectionItem`本体を持ったままでは、次の描き直しで消えた行の属性を読んで落ちる。
    @State private var addedItemIDs: [UUID] = []

    /// 一覧に並べる本 = この面で入れたぶんだけ(型コメント参照)。外された本は黙って落ちる。
    private var items: [CollectionItem] {
        addedItemIDs.compactMap { collectionStore.item(withID: $0) }
    }

    /// 見出しに出す冊数。こちらは**棚全体**の冊数(一覧と違い、入れ先が今どれだけ持っているか)。
    private var collectionCount: Int {
        collection?.items.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Add Books")
                    .font(.headline)
                    .fixedSize()
                Text(collection?.name ?? target.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 冊数は名前のすぐ隣に置く ―― 下に裸の数字だけを置いても何の数か読めない
                // (サイドパネルの各見出しと、コレクションの中の見出しと同じ並べ方)。
                Text("\(collectionCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 8)
                Button("Add Books…") { chooseWithPanel() }
                    .disabled(isAdding)
                    .fixedSize()
            }

            bookList

            HStack(alignment: .firstTextBaseline) {
                if let notice {
                    Text(verbatim: notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                // 幅はボタンではなくラベルへ(WelcomeTopBar.openButtonの同じコメント参照)。
                // 1つきりのボタンなので揃える相手はいないが、「完了」の2文字だけの
                // 小さすぎるボタンにしないための下限として使う。
                Button { dismiss() } label: {
                    Text("Done").frame(
                        width: MetadataButtonWidthEstimator.equalWidth(
                            for: [String(localized: "Done", language: locale)],
                            minWidth: 60, chrome: 0
                        )
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }

    private var bookList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items, id: \.id) { item in
                    row(for: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay {
            if items.isEmpty {
                Text("Drag books here, or use “Add Books…”.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    lineWidth: isDropTargeted ? 3 : 1
                )
                .allowsHitTesting(false)
        }
        .fileURLDropTarget(isTargeted: $isDropTargeted) { urls in
            add(urls)
        }
    }

    private func row(for item: CollectionItem) -> some View {
        HStack(spacing: 8) {
            CollectionCoverThumbnail(
                item: item,
                coverStore: collectionStore.coverStore,
                aspectRatio: library?.coverAspectRatio ?? .portrait,
                anchor: library?.coverCropAnchor ?? .center,
                fit: library?.coverFit ?? .crop,
                displayWidth: 22,
                exists: collectionStore.cachedFileExists(for: item),
                isExtracting: coverExtractor.inFlightItemIDs.contains(item.id)
            )
            .frame(width: 22)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            FormatBadgeView(bookID: item.bookID)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .help(item.bookID)
    }

    // MARK: - 追加

    private func chooseWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", language: locale)
        panel.message = String(
            localized: "Choose manga folders, or zip/cbz, rar/cbr, 7z/cb7, PDF, or EPUB files to add to this collection.",
            language: locale
        )
        // このウインドウのシート(2026-09-27。WindowSheet)。その間にライブラリ機能が切られていたら足さない。
        WindowSheet.begin(panel) { response in
            guard response == .OK, preferences.libraryFeatureEnabled else { return }
            add(panel.urls)
        }
    }

    /// 1 回ぶんを足し終えたら、その間に積まれた分を続けて足す(H-7)。待つ間にライブラリ機能が切られていたら足さずに捨てる
    /// (パネルを出したままでも、切った後に登録しない ―― 選ぶパネルの戻りと同じ確かめ)。
    ///
    /// 積まれた分は**今の回と同じ入れ先へ**足す(`into`。今の回で作ったコレクションの id も入っている ―― 2026-10-05 の監査 A6-F1。以前は
    /// 続けて足すときに入れ先をバインディングから読み直したので、待つ間にパネルを閉じて別のコレクションで開き直すと、そちらへ入った)。
    private func finishAdding(into: WelcomeLibraryState.AddBooksTarget) {
        isAdding = false
        let next = queuedURLs
        queuedURLs = []
        guard !next.isEmpty, preferences.libraryFeatureEnabled else { return }
        add(next, into: into)
    }

    /// 落とされた/選ばれたURLから本だけを拾って登録する。棚(本の並んだフォルダ)は中の本へ
    /// 展開する(CollectionDropClassifier.booksToAdd参照)。
    ///
    /// 入れ先は**落とされた時点のもの**(`into` が無ければ今のパネルの対象)を控えて使う(2026-10-05 の監査 A6-F1)。振り分けを待つ間に
    /// パネルが閉じられ、別のコレクションの「本を追加」が開いても、落とされたコレクションへ入れる。パネルへの書き戻し(作った
    /// コレクションの id)は、パネルの対象が同じ(`AddBooksTarget.id`)ときだけ。
    private func add(_ urls: [URL], into given: WelcomeLibraryState.AddBooksTarget? = nil) {
        guard !urls.isEmpty else { return }
        // 足している最中なら積んでおき、終わってから足す(queuedURLs のコメント)。
        guard !isAdding else {
            queuedURLs.append(contentsOf: urls)
            return
        }
        isAdding = true
        let order = preferences.siblingBookOrder
        let locale = locale
        let dropTarget = given ?? target
        Task {
            let finalTarget = await addBooks(urls, into: dropTarget, order: order, locale: locale)
            finishAdding(into: finalTarget)
        }
    }

    /// `add(_:into:)` の本体。足し終えた後の入れ先(作ったコレクションの id を埋めたもの)を返す。
    private func addBooks(
        _ urls: [URL], into dropTarget: WelcomeLibraryState.AddBooksTarget, order: SiblingBookOrder, locale: Locale
    ) async -> WelcomeLibraryState.AddBooksTarget {
        var into = dropTarget
        let classified = await CollectionDropClassifier.classifyAsync(urls, order: order)
        let books = CollectionDropClassifier.booksToAdd(from: classified)
        let skipped = classified.filter { if case .ignored = $0 { true } else { false } }.count
        guard !books.isEmpty else {
            notice = WelcomeDropHandling.noBooksMessage(locale: locale)
            return into
        }
        // ブックマークの生成はメインアクターの外で(CollectionStore.makePendingItemsのコメント参照)。
        let pending = await CollectionStore.makePendingItems(for: books)
        // シークレットフォルダの本は入れない(makePendingItems が外す)。入れなかったことを知らせる。
        let skippedSecret = books.filter(SecretFolderStore.isSecretAppWide).count
        if skippedSecret > 0 { notice = CollectionStore.secretBooksNotAddedMessage(count: skippedSecret, locale: locale) }
        guard !pending.isEmpty else { return into }

        // 待つ間にこのパネル(同じ対象)が別の回でコレクションを作っていれば、それへ入れる。
        let isPanelTarget = target.id == into.id
        if isPanelTarget, into.collectionID == nil, let created = target.collectionID { into.collectionID = created }
        let collection = into.collectionID.flatMap { collectionStore.collection(withID: $0) }
        let added: [CollectionItem]
        if let collection {
            added = collectionStore.add(pending, to: collection)
        } else if into.collectionID != nil {
            // 入れ先のコレクションが(別のウインドウで)消えた。**新しく作らない**(監査 H-9。以前は nil を「まだ作っていない」と
            // 区別せず、同じ名前で作り直していた ―― 後で ⌘Z で戻すと「C 2」が並んだ)。足さずに知らせる。
            notice = WelcomeDropHandling.collectionGoneMessage(locale: locale)
            return into
        } else if let library = collectionStore.library(withID: into.libraryID),
                  let created = collectionStore.createCollection(
                      name: into.name, in: library, items: pending
                  ) {
            into.collectionID = created.id
            if isPanelTarget { target.collectionID = created.id }
            // 名前を決めるときに選ばれていた自動登録フォルダを、行ができたこの時点で
            // 書き込む(AddBooksTarget.autoFolderのコメント参照)。
            if let autoFolder = into.autoFolder {
                collectionStore.setAutoFolder(autoFolder, for: created)
            }
            added = collectionStore.items(in: created, sort: .dateAddedAscending)
        } else {
            added = []
        }
        // 入った順に積む。既に入っていた本はadd(_:to:)が弾いて返さないので、ここには来ない。
        addedItemIDs.append(contentsOf: added.map(\.id))
        coverExtractor.enqueue(added)
        // 入れなかったものを知らせる(本でない・既に入っていた)。全部入ったら消す。
        var parts: [String] = []
        if skipped > 0 { parts.append(WelcomeDropHandling.skippedMessage(skipped, locale: locale)) }
        let duplicates = pending.count - added.count
        if duplicates == 1 {
            parts.append(String(localized: "1 book was already in the collection.", language: locale))
        } else if duplicates > 1 {
            parts.append(String(
                format: String(localized: "%lld books were already in the collection.", language: locale), duplicates
            ))
        }
        notice = parts.isEmpty ? nil : parts.joined(separator: " ")
        return into
    }
}
