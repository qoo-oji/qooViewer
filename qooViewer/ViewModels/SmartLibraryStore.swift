import Combine
import Foundation

/// スマートライブラリで保存するもの(アプリで 1 つ。AppStores)。
///
/// - 保存したスマートシェルフ(名前と条件)
/// - スマートライブラリの対象フォルダ(**パスだけ**。読む権限は `FolderAccessStore` に一本化 ―― よく使う項目と同じ判断。
///   FavoriteLocationStore の型コメント)
/// - どこの本を対象にするか(ライブラリ・よく使う項目・対象フォルダ。それぞれ ON/OFF)
///
/// 保存先は UserDefaults(`qooViewer.smartLibrary.store`、JSON)。**`qooViewer.pref.*` ではない** ―― 環境設定のリセットで
/// 利用者が作ったスマートシェルフが消えないように(ホームの状態 `qooViewer.welcome.*` と同じ扱い)。
/// SwiftData に置かないのは、中身がアプリの設定に近い少量の値で、本ごとのデータではないため
/// (本ごとのメタデータ・読書位置は、並べるときに各ストアから読む)。
///
/// `AppStores.allObjectWillChangePublishers` には**足さない**(メニューバーは名前を読まない。ホームのメニューの
/// スマートライブラリの項目は切り替えだけ)。
@MainActor
final class SmartLibraryStore: ObservableObject {
    struct Folder: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        /// 末尾の`/`を持たないパス(FavoriteLocationStore.Item と同じ規則)。
        let path: String
        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    }

    /// どこの本を対象にするか。
    struct SourceToggles: Codable, Hashable, Sendable {
        var library = true
        var favoriteLocations = true
        var folders = true
    }

    private struct Stored: Codable {
        var shelves: [SmartShelf] = []
        var folders: [Folder] = []
        var sources = SourceToggles()

        init(shelves: [SmartShelf], folders: [Folder], sources: SourceToggles) {
            self.shelves = shelves
            self.folders = folders
            self.sources = sources
        }

        /// 鍵が無い・一部が読めない保存値でも、読める所だけ読む(版を上げて欄を足したときに全部を失わない)。
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            shelves = (try? c.decode([Lossy<SmartShelf>].self, forKey: .shelves))?.compactMap(\.value) ?? []
            folders = (try? c.decode([Folder].self, forKey: .folders)) ?? []
            sources = (try? c.decode(SourceToggles.self, forKey: .sources)) ?? SourceToggles()
        }

        enum CodingKeys: String, CodingKey { case shelves, folders, sources }
    }

    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    static let defaultsKey = "qooViewer.smartLibrary.store"

    @Published private(set) var shelves: [SmartShelf] = []
    @Published private(set) var folders: [Folder] = []
    @Published var sources = SourceToggles() { didSet { if sources != oldValue { save() } } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            shelves = stored.shelves
            folders = stored.folders
            sources = stored.sources
        }
    }

    // MARK: - スマートシェルフ

    func shelf(withID id: UUID) -> SmartShelf? { shelves.first { $0.id == id } }

    /// 足す(名前が空なら「名称未設定」)。
    @discardableResult
    func add(_ shelf: SmartShelf) -> SmartShelf {
        shelves.append(shelf)
        save()
        return shelf
    }

    /// 置き換える(条件の編集・名前の変更)。
    func update(_ shelf: SmartShelf) {
        guard let index = shelves.firstIndex(where: { $0.id == shelf.id }) else { return }
        shelves[index] = shelf
        save()
    }

    func removeShelf(id: UUID) {
        shelves.removeAll { $0.id == id }
        save()
    }

    /// 複製する(名前に「のコピー」を付ける)。
    @discardableResult
    func duplicate(id: UUID, copySuffix: String) -> SmartShelf? {
        guard let source = shelf(withID: id) else { return nil }
        let copy = SmartShelf(name: source.name + copySuffix, conditions: source.conditions)
        if let index = shelves.firstIndex(where: { $0.id == id }) {
            shelves.insert(copy, at: index + 1)
        } else {
            shelves.append(copy)
        }
        save()
        return copy
    }

    // MARK: - 対象フォルダ

    @discardableResult
    func addFolder(_ url: URL) -> Folder {
        let path = MountTable.normalized(url.standardizedFileURL.path)
        if let existing = folders.first(where: { $0.path == path }) { return existing }
        let folder = Folder(id: UUID(), path: path)
        folders.append(folder)
        save()
        return folder
    }

    func removeFolder(id: UUID) {
        folders.removeAll { $0.id == id }
        save()
    }

    /// アプリ自身が名前を変えた・移したフォルダの登録を新しいパスへ付け替える(FavoriteLocationStore.relocate と同じ規則)。
    @discardableResult
    func relocate(using change: FileSystemChange) -> Bool {
        guard !change.relocations.isEmpty else { return false }
        var relocated: [Folder] = []
        var seen = Set<String>()
        var changed = false
        for folder in folders {
            let path = change.relocatedPath(for: folder.path).map(MountTable.normalized) ?? folder.path
            if path != folder.path { changed = true }
            guard seen.insert(path).inserted else { continue }
            relocated.append(path == folder.path ? folder : Folder(id: folder.id, path: path))
        }
        guard changed else { return false }
        folders = relocated
        save()
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(shelves: shelves, folders: folders, sources: sources)) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
