import Combine
import Foundation

/// スマートライブラリで保存するもの(アプリで 1 つ。AppStores)。
///
/// - 保存したスマートシェルフ(名前と条件)
/// - スマートライブラリの対象フォルダ(**パスだけ**。読む権限は `FolderAccessStore` に一本化 ―― よく使う項目と同じ判断。
///   FavoriteLocationStore の型コメント)。**並ぶ本はこの中の本だけ**(2026-09-22、利用者の指示。ライブラリ・ファイルブラウザは
///   環境設定で個別に OFF にできるので、その本を混ぜると OFF にした機能の中身がここに出てしまう。切り分けておく)
/// - ブラウザの選択パネルでピン留めした値(欄ごと。パネルの一番上に並ぶ)
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

    private struct Stored: Codable {
        var shelves: [SmartShelf] = []
        var folders: [Folder] = []
        /// 欄(`SmartFacetField.rawValue`)→ ピン留めした値。
        var pins: [String: [SmartFacetValue]] = [:]

        init(shelves: [SmartShelf], folders: [Folder], pins: [String: [SmartFacetValue]]) {
            self.shelves = shelves
            self.folders = folders
            self.pins = pins
        }

        /// 鍵が無い・一部が読めない保存値でも、読める所だけ読む(版を上げて欄を足したときに全部を失わない)。
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            shelves = (try? c.decode([Lossy<SmartShelf>].self, forKey: .shelves))?.compactMap(\.value) ?? []
            folders = (try? c.decode([Folder].self, forKey: .folders)) ?? []
            pins = (try? c.decode([String: [SmartFacetValue]].self, forKey: .pins)) ?? [:]
        }

        enum CodingKeys: String, CodingKey { case shelves, folders, pins }
    }

    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    static let defaultsKey = "qooViewer.smartLibrary.store"

    @Published private(set) var shelves: [SmartShelf] = []
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var pins: [SmartFacetField: [SmartFacetValue]] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            shelves = stored.shelves
            folders = stored.folders
            for (key, values) in stored.pins {
                if let field = SmartFacetField(rawValue: key) { pins[field] = values }
            }
        }
    }

    // MARK: - 保存データの取り込み(2026-09-23)

    /// バックアップ(保存データの JSON)から取り込む。
    ///
    /// - Parameters:
    ///   - folderPaths: 対象フォルダの**パス**。権限は持ち出せないので、**その場所に実際に
    ///     フォルダがあるときだけ**登録する(コレクションの自動登録フォルダと同じ規則。
    ///     フォルダがあっても読むには別途「アクセスを許可」が要る)。
    ///   - replacingExisting: overwrite なら手元のスマートコレクション・対象フォルダ・ピン留めを
    ///     捨ててから入れる。merge なら、スマートコレクションは id が同じものを飛ばし、
    ///     対象フォルダは同じパスを飛ばし、ピン留めは足し合わせる。
    /// - Returns: 取り込んだスマートコレクションと対象フォルダの数。
    @discardableResult
    func importBackup(
        shelves importedShelves: [SmartShelf], folderPaths: [String],
        pins importedPins: [SmartFacetField: [SmartFacetValue]], replacingExisting: Bool
    ) -> (shelves: Int, folders: Int) {
        if replacingExisting {
            shelves = []
            folders = []
            pins = [:]
        }
        var addedShelves = 0
        for shelf in importedShelves where !shelves.contains(where: { $0.id == shelf.id }) {
            shelves.append(shelf)
            addedShelves += 1
        }
        var addedFolders = 0
        for path in folderPaths {
            let normalized = MountTable.normalized(path)
            guard !folders.contains(where: { $0.path == normalized }) else { continue }
            // 実在するフォルダだけ(自動登録フォルダと同じ規則)。
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            folders.append(Folder(id: UUID(), path: normalized))
            addedFolders += 1
        }
        for (field, values) in importedPins {
            var merged = pins[field] ?? []
            for value in values where !merged.contains(value) { merged.append(value) }
            pins[field] = merged.isEmpty ? nil : merged
        }
        save()
        return (addedShelves, addedFolders)
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

    // MARK: - ピン留め

    func isPinned(_ value: SmartFacetValue, in field: SmartFacetField) -> Bool {
        pins[field]?.contains(value) ?? false
    }

    func togglePin(_ value: SmartFacetValue, in field: SmartFacetField) {
        var values = pins[field] ?? []
        if let index = values.firstIndex(of: value) { values.remove(at: index) } else { values.append(value) }
        pins[field] = values.isEmpty ? nil : values
        save()
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
        guard let data = try? JSONEncoder().encode(Stored(
            shelves: shelves, folders: folders,
            pins: Dictionary(uniqueKeysWithValues: pins.map { ($0.key.rawValue, $0.value) })
        )) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
