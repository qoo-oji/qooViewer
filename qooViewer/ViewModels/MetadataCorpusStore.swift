import Combine
import Foundation

/// メタデータ生成(`MetadataGenerator`)の母体のうち、**機能が記録する本の一覧**(2026-09-22。docs/plans/metadata-generator-plan.md)。
///
/// メタデータは本の情報で、どの機能の持ち物でもない(利用者の指示 2026-09-22)。ライブラリとスマートライブラリは、それぞれが
/// 知っている本の一覧(パスだけ)をここへ記録し、メタデータ生成はその記録を読む。**機能を OFF にしても記録は残り、メタデータの
/// 対象は変わらない** ―― OFF の間に止まるのは、記録し直すこと(コレクションの行を読む・対象フォルダを探し直す)だけ。
///
/// - コレクションの本: ライブラリが ON の間に `CollectionStore` から写す(`recordCollectionBooks`)。OFF の間は `CollectionItem`
///   を読まない約束(CLAUDE.md)なので、最後に写した一覧を使う。
/// - スマートライブラリの対象フォルダの本: スマートライブラリが探した結果を対象フォルダごとに写す(`recordSmartLibraryScan`)。
///   対象フォルダを外したら、その一覧も外す(`keepSmartLibraryRoots`)。
///
/// 写しなので保存データの書き出しには入れない(読み込めば、機能が記録し直す)。アプリ自身がファイルを動かしたら付け替える
/// (`relocate`)。
@MainActor
final class MetadataCorpusStore {
    nonisolated struct Record: Codable, Equatable, Sendable {
        var version = Record.currentVersion
        var collectionBookIDs: [String] = []
        /// 対象フォルダ → その中の本。
        var smartLibrary: [String: [String]] = [:]

        static let currentVersion = 1
    }

    private(set) var record: Record
    /// 記録が変わった(メタデータ生成が母体を集め直す)。
    let changes = PassthroughSubject<Void, Never>()
    /// 保存先。nil なら保存しない(テスト)。
    private let url: URL?

    init(url: URL?) {
        self.url = url
        record = url.flatMap(Self.load(from:)) ?? Record()
    }

    /// 既定の保存先(Application Support の中。消えても機能が記録し直す写し)。
    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MetadataCorpus", isDirectory: true)
            .appendingPathComponent("corpus.json")
    }

    var collectionBookIDs: Set<String> { Set(record.collectionBookIDs) }

    var smartLibraryBookIDs: Set<String> { Set(record.smartLibrary.values.joined()) }

    /// コレクションの本の一覧を記録する(ライブラリが ON の間だけ呼ぶ)。
    func recordCollectionBooks(_ bookIDs: Set<String>) {
        let sorted = bookIDs.sorted()
        guard sorted != record.collectionBookIDs else { return }
        record.collectionBookIDs = sorted
        didChange()
    }

    /// スマートライブラリが探した結果を記録する。`roots` の対象フォルダごとに、その中の本で置き換える。
    /// 探しきれなかった(打ち切った)ときは、前の記録に足すだけ(見つからなかった本を「無い」にしない)。
    func recordSmartLibraryScan(roots: [String], bookIDs: [String], isTruncated: Bool) {
        var next = record.smartLibrary
        for root in roots {
            let found = bookIDs.filter { MountTable.path($0, isAtOrUnder: root) }
            let merged = isTruncated ? Set(next[root] ?? []).union(found) : Set(found)
            next[root] = merged.sorted()
        }
        guard next != record.smartLibrary else { return }
        record.smartLibrary = next
        didChange()
    }

    /// 対象フォルダの設定に合わせる(外した対象フォルダの一覧を外す)。機能が OFF でも呼ぶ(設定の変化なので)。
    func keepSmartLibraryRoots(_ roots: [String]) {
        let kept = record.smartLibrary.filter { roots.contains($0.key) }
        guard kept != record.smartLibrary else { return }
        record.smartLibrary = kept
        didChange()
    }

    /// アプリ自身がファイルを動かした(`FileSystemChange`)・アプリの外での移動を見つけた。記録のパスを付け替え、消えた本を外す。
    func relocate(using change: FileSystemChange) {
        let displaced = change.displacedPathSet
        guard !displaced.isEmpty else { return }
        func moved(_ ids: [String]) -> [String] {
            ids.compactMap { id in
                // 関係の無い本は深さぶんの確かめだけで素通り(FileSystemChange.mayAffect)。
                guard FileSystemChange.mayAffect(id, displaced: displaced) else { return id }
                if let path = change.relocatedPath(for: id) { return path }
                return change.displaces(id) ? nil : id
            }
        }
        var next = record
        next.collectionBookIDs = Array(Set(moved(record.collectionBookIDs))).sorted()
        var smart: [String: [String]] = [:]
        for (root, ids) in record.smartLibrary {
            let newRoot = FileSystemChange.mayAffect(root, displaced: displaced) ? change.relocatedPath(for: root) ?? root : root
            smart[newRoot, default: []].append(contentsOf: moved(ids))
        }
        next.smartLibrary = smart.mapValues { Array(Set($0)).sorted() }
        guard next != record else { return }
        record = next
        didChange()
    }

    private func didChange() {
        save()
        changes.send()
    }

    /// 書き込みは画面の外で、**頼んだ順に 1 つずつ**(並べて走らせると、古い中身が後から書き終えて残ることがある)。
    private var saving: Task<Void, Never>?

    private func save() {
        guard let url else { return }
        let record = record
        let previous = saving
        saving = Task.detached(priority: .utility) {
            await previous?.value
            guard let data = try? JSONEncoder().encode(record) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private nonisolated static func load(from url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == Record.currentVersion else { return nil }
        return record
    }
}
