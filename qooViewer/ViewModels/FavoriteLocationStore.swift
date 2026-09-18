import Combine
import Foundation

/// ファイルブラウザの左の「よく使う項目」(改善要望7 段階3、2026-09-13)。アプリ全体で1つ
/// (AppStores)。
///
/// ■ 持つのはパスだけ
/// フォルダを読む権限は`FolderAccessStore`に一本化してある(「＋」は`NSOpenPanel` →
/// `FolderAccessStore.add` → ここへ登録、の順)。コレクションの自動登録フォルダと同じ判断で、
/// 同じフォルダの権限を2箇所が別々に開け閉めしないため(検討メモ §3.4)。アクセス権を後から
/// 取り消されても、行は残って「アクセスを許可…」の案内に落ちるだけ。
///
/// ■ シークレットウインドウでは登録させない
/// 保存を伴うため(決定事項 Q8)。登録を塞ぐのは画面の側(「＋」を淡色にする)。
///
/// `AppStores.allObjectWillChangePublishers`には**足さない** ―― メニューバーに現れないため
/// (CollectionStoreと同じ理由)。
@MainActor
final class FavoriteLocationStore: ObservableObject {
    struct Item: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        /// 末尾の`/`を持たないパス。
        let path: String

        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    }

    static let defaultsKey = "qooViewer.fileBrowser.favoriteLocations"

    @Published private(set) var items: [Item]

    /// 保存先。テストは専用の suite を渡す(AppPreferences.defaultsと同じ理由)。
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    /// 登録する。同じパスが既にあれば何もしない。
    /// - Returns: 登録された(または既にあった)項目。
    @discardableResult
    func add(_ folder: URL) -> Item {
        let path = Self.path(for: folder)
        if let existing = items.first(where: { $0.path == path }) { return existing }
        let item = Item(id: UUID(), path: path)
        items.append(item)
        save()
        return item
    }

    /// そのフォルダが登録済みか(`add`と同じ規則でパスをそろえて比べる)。
    func contains(_ folder: URL) -> Bool {
        let path = Self.path(for: folder)
        return items.contains { $0.path == path }
    }

    private static func path(for folder: URL) -> String {
        MountTable.normalized(folder.standardizedFileURL.path)
    }

    func remove(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        save()
    }

    /// 並べ替える(ツリーのドラッグ。2026-09-14、ユーザー要望)。`destination` は**動かす前の**並びでの挿入位置
    /// (`NSOutlineView` の行の間のドロップの子の添字そのまま。0 = 先頭、`items.count` = 末尾)。
    /// - Returns: 並びが変わったか。
    @discardableResult
    func move(id: UUID, to destination: Int) -> Bool {
        guard let source = items.firstIndex(where: { $0.id == id }) else { return false }
        let clamped = min(max(destination, 0), items.count)
        // 自分の直前・直後への挿入は動かない。
        guard clamped != source, clamped != source + 1 else { return false }
        var reordered = items
        let item = reordered.remove(at: source)
        reordered.insert(item, at: clamped > source ? clamped - 1 : clamped)
        items = reordered
        save()
        return true
    }

    /// アプリ自身が名前を変えた・移したフォルダ(とその配下)の登録を、新しいパスへ付け替える(2026-09-19 の監査の M4。
    /// `FileSystemChange` の型コメント)。以前は行が古い名前のまま残り、押すと祖先へ退避した。移った先がすでに登録済みなら、
    /// 重なったほうを外す。ゴミ箱へ送ったフォルダの登録は残す(取り消しで戻る。行を押せば今までどおり祖先へ退避する)。
    /// - Returns: 付け替えたか。
    @discardableResult
    func relocate(using change: FileSystemChange) -> Bool {
        guard !change.relocations.isEmpty else { return false }
        var relocated: [Item] = []
        var seen = Set<String>()
        var changed = false
        for item in items {
            let path = change.relocatedPath(for: item.path).map(MountTable.normalized) ?? item.path
            if path != item.path { changed = true }
            guard seen.insert(path).inserted else { continue }
            relocated.append(path == item.path ? item : Item(id: item.id, path: path))
        }
        guard changed else { return false }
        items = relocated
        save()
        return true
    }

    func item(withID id: UUID) -> Item? {
        items.first { $0.id == id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
