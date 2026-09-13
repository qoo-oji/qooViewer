import SwiftUI

/// サイドパネルのブックマークモードの下段: ライブラリ → コレクション → 本のツリー
/// (ユーザー要望 2026-09-13)。
///
/// ■ 何ができるか
/// - 最初はライブラリだけが並ぶ。行をクリックすると、その中のコレクション、さらにその中の本へと
///   展開する(開閉は「ダブルクリックで開く」の設定に関わらず常にシングルクリック ―― お気に入り
///   ツリーのフォルダ行と同じ判断。SidePanelFavoriteRow.folderRowのコメント)
/// - 本をクリック(設定によってはダブルクリック)で開く
/// - 本の右クリックは、履歴モードの行と同じ「開く / 新規◯◯で開く / Finderで表示」
///   (ユーザー指定: 既存のモードの動作に合わせる)。**ライブラリ・コレクションの右クリックは
///   まだ無い**(ユーザー指定: ひとまず非サポート)。項目の無いcontextMenuは付けない
///
/// ■ 並び順はウェルカム画面と同じ
/// 同じウインドウのウェルカム画面(WelcomeLibraryState)の並び順をそのまま使う。棚を見る場所が
/// 2つあって並びが違うと、同じ本を探すのに2通りの順番を覚えることになる。
///
/// ■ 行はツリーを平らにした1本の配列で並べる
/// SwiftUIの`some View`は自分自身を再帰で呼べないので、お気に入りツリーは行ごとのView構造体を
/// 再帰させている。こちらは階層が2段で固定なので、展開状態から「いま見えている行」の配列を
/// 作って`LazyVStack`へ流す ―― 数千冊のコレクションを開いても、組み立てるのは見えている行だけ。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// 文字とアイコンの行なので`.panelOutlinedContent()`、今開いている本の行の強調は
/// フォルダブラウザの行と同じ`.panelOutlinedAccent(in:)`。
struct SidePanelLibraryTreeSection: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var collectionStore: CollectionStore
    @Environment(\.locale) private var locale

    @Binding var expandedLibraryIDs: Set<UUID>
    @Binding var expandedCollectionIDs: Set<UUID>
    /// ウェルカム画面の並び順(コレクション・本)。
    let collectionSort: FavoritesSortOption
    let itemSort: FavoritesSortOption
    /// 今開いている本(MangaBook.id = パス)。その本の行を強調する。
    let currentBookPath: String?
    var onOpen: (URL) -> Void
    var onOpenInNewWindow: (URL, BookOpenDestination) -> Void

    /// ツリーを平らにした1行。
    private enum Row: Identifiable {
        case library(BookLibrary)
        case collection(BookCollection)
        case book(CollectionItem)
        /// 開いたコレクションに本が無い(ほぼ起きない ―― 空のコレクションは作らない方針)。
        case empty(parentID: UUID)

        var id: String {
            switch self {
            case .library(let library): return "library:\(library.id.uuidString)"
            case .collection(let collection): return "collection:\(collection.id.uuidString)"
            case .book(let item): return "book:\(item.id.uuidString)"
            case .empty(let parentID): return "empty:\(parentID.uuidString)"
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        for library in collectionStore.libraries {
            rows.append(.library(library))
            guard expandedLibraryIDs.contains(library.id) else { continue }
            let collections = collectionStore.collections(in: library, sort: collectionSort)
            if collections.isEmpty { rows.append(.empty(parentID: library.id)) }
            for collection in collections {
                rows.append(.collection(collection))
                guard expandedCollectionIDs.contains(collection.id) else { continue }
                let items = collectionStore.items(in: collection, sort: itemSort)
                if items.isEmpty { rows.append(.empty(parentID: collection.id)) }
                rows.append(contentsOf: items.map(Row.book))
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            // 他の段(ブックマーク・お気に入り)と同じ位置・同じ書式の見出し。
            Text("Libraries")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .panelOutlinedContent()
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
            }
            // folderSection/BookContentsSectionViewの同名の.focusable(false)と同じ理由。
            .focusable(false)
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .library(let library):
            disclosureRow(
                id: library.id, depth: 0, expanded: $expandedLibraryIDs,
                icon: "books.vertical", title: library.displayName(language: locale),
                count: library.collections.count
            )
        case .collection(let collection):
            disclosureRow(
                id: collection.id, depth: 1, expanded: $expandedCollectionIDs,
                icon: "rectangle.stack", title: collection.name, count: collection.items.count
            )
        case .book(let item):
            bookRow(item)
        case .empty(let parentID):
            // 親の深さに合わせて字下げする(ライブラリの下なら1段、コレクションの下なら2段)。
            let depth = expandedLibraryIDs.contains(parentID) ? 1 : 2
            Text("(Empty)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
                .padding(.leading, Self.leadingInset(depth: depth) + Self.chevronWidth + 6)
                .padding(.vertical, 4)
        }
    }

    private static let chevronWidth: CGFloat = 10
    private static func leadingInset(depth: Int) -> CGFloat { 8 + CGFloat(depth) * 14 }

    /// 開閉できる行(ライブラリ・コレクション)。
    private func disclosureRow(
        id: UUID, depth: Int, expanded: Binding<Set<UUID>>, icon: String, title: String, count: Int
    ) -> some View {
        let isExpanded = expanded.wrappedValue.contains(id)
        return HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.chevronWidth)
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .panelOutlinedContent()
        .padding(.leading, Self.leadingInset(depth: depth))
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(title)
        .onTapGesture {
            if isExpanded {
                expanded.wrappedValue.remove(id)
            } else {
                expanded.wrappedValue.insert(id)
            }
        }
    }

    private func bookRow(_ item: CollectionItem) -> some View {
        let isCurrent = item.bookID == currentBookPath
        let exists = collectionStore.cachedFileExists(for: item)
        return HStack(spacing: 6) {
            // 開閉の三角ぶんの幅を空けて、同じ深さの行と名前の開始位置を揃える。
            Color.clear.frame(width: Self.chevronWidth, height: 1)
            Image(systemName: Self.iconName(forBookID: item.bookID))
                .frame(width: 16)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .panelOutlinedContent()
        .padding(.leading, Self.leadingInset(depth: 2))
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        // 実体が見つからない本は、ウェルカム画面のカバーと同じく淡く描く(開こうとすると鳴るだけ)。
        .opacity(exists ? 1 : 0.45)
        .contentShape(Rectangle())
        .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
        .panelOutlinedAccent(in: Rectangle(), isEnabled: isCurrent)
        .help(item.bookID)
        .onTapGesture(count: preferences.sidePanelUsesDoubleClick ? 2 : 1) { open(item) }
        .sidePanelContextHighlight(rowID: "libraryTreeBook:\(item.id.uuidString)")
        .contextMenu {
            // 履歴モードの行と同じ並び(ユーザー指定)。ブックマークの解決は選ばれた時点で行う
            // (行を描くたびに解決すると、一覧全体でディスクを触ることになる)。
            BookOpenContextMenuItems(
                onOpen: { open(item) },
                onOpenIn: { destination in
                    guard let url = resolvedURL(item) else { return }
                    onOpenInNewWindow(url, destination)
                }
            )
            Divider()
            Button("Show in Finder") {
                guard let url = resolvedURL(item) else { return }
                FinderReveal.reveal(url)
            }
        }
    }

    private func open(_ item: CollectionItem) {
        guard let url = resolvedURL(item) else { return }
        onOpen(url)
    }

    /// 開く直前にブックマークを解決する。見つからなければ警告音だけ鳴らす ―― 理由を書き分けた
    /// アラート(「本が見つかりません」)はウェルカム画面のコレクションの中が持っており、細い
    /// パネルの行からは淡く描いてあることで伝える。
    private func resolvedURL(_ item: CollectionItem) -> URL? {
        guard let url = collectionStore.resolvedExistingURL(for: item) else {
            NSSound.beep()
            return nil
        }
        return url
    }

    /// 本の行のアイコン。コレクションに入るのは書庫・PDF・EPUB・フォルダだけなので、
    /// 本のファイルと分からないものはフォルダとして描く(拡張子の有無では決めない ――
    /// 「Vol.1」のようなフォルダ名は拡張子を持っているように見える)。
    private static func iconName(forBookID bookID: String) -> String {
        let fileName = URL(fileURLWithPath: bookID).lastPathComponent
        if isArchiveFile(fileName) || isPDFFile(fileName) || isEpubFile(fileName) {
            return sidePanelFileIconName(fileName: fileName)
        }
        return "folder"
    }
}
