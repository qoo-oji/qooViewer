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

    private var collection: BookCollection? {
        target.collectionID.flatMap { collectionStore.collection(withID: $0) }
    }

    /// 入れ先のライブラリ。カバーの縦横比だけのために引く(この一覧の22ptのセルも、
    /// 一覧に並んだときと同じ形で出したい)。
    private var library: BookLibrary? {
        collectionStore.library(withID: target.libraryID)
    }

    private var items: [CollectionItem] {
        // 入れた順に上から積まれるほうが、追加中の画面としては分かりやすい。
        collection.map { collectionStore.items(in: $0, sort: .dateAddedAscending) } ?? []
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
                Text("\(items.count)")
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

            HStack {
                Spacer()
                // 幅はボタンではなくラベルへ(BookMetadataSheetの同じコメント参照)。
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
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// 落とされた/選ばれたURLから本だけを拾って登録する。棚(本の並んだフォルダ)は中の本へ
    /// 展開する(CollectionDropClassifier.booksToAdd参照)。
    private func add(_ urls: [URL]) {
        guard !urls.isEmpty, !isAdding else { return }
        isAdding = true
        let order = preferences.siblingBookOrder
        Task {
            defer { isAdding = false }
            let classified = await CollectionDropClassifier.classifyAsync(urls, order: order)
            let books = CollectionDropClassifier.booksToAdd(from: classified)
            guard !books.isEmpty else { return }
            let pending = books.compactMap(CollectionStore.makePendingItem(for:))
            guard !pending.isEmpty else { return }

            let added: [CollectionItem]
            if let collection {
                added = collectionStore.add(pending, to: collection)
            } else if let library = collectionStore.library(withID: target.libraryID),
                      let created = collectionStore.createCollection(
                          name: target.name, in: library, items: pending
                      ) {
                target.collectionID = created.id
                added = collectionStore.items(in: created, sort: .dateAddedAscending)
            } else {
                added = []
            }
            coverExtractor.enqueue(added)
        }
    }
}
