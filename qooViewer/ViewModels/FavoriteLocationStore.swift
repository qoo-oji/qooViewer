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
        let path = MountTable.normalized(folder.standardizedFileURL.path)
        if let existing = items.first(where: { $0.path == path }) { return existing }
        let item = Item(id: UUID(), path: path)
        items.append(item)
        save()
        return item
    }

    func remove(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        save()
    }

    func item(withID id: UUID) -> Item? {
        items.first { $0.id == id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
