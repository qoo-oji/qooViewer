import Foundation
import CryptoKit

/// 1冊分の「ページ一覧」(並び順・ファイル名)を、アプリのキャッシュディレクトリへ
/// 永続化しておくための保管庫。
///
/// なぜ必要か: 「ブックマーク・レイアウトの編集」ウインドウの右ペインは、左ペインで本を
/// 選び直すたびにBookLoader.load(from:)の完了を待ってから描画を始めていた。この読み込みは
/// 書庫の全走査(入れ子書庫があれば展開まで)を伴うため、本を行き来するだけで毎回そのぶん
/// 待たされる。本体が未接続の外付け/ネットワークボリューム上にあるとなおさら顕著になる。
///
/// 右ペインの行が必要とするのはページの並び順とファイル名だけで、レイアウト状態や
/// ブックマークはDB(SwiftData)から即座に引ける。そこでページ一覧をここへ覚えておき、
/// 2回目以降は本体の読み込みを待たずに行を描画し、サムネイルだけを後追いで埋める。
///
/// ThumbnailDiskCacheと違い、キーはbookIDだけにしてある。本体の更新日時・サイズをキーに
/// 含めてしまうと、キャッシュを引くために先に本体のURLを解決してファイル属性を読む必要があり
/// (=まさに避けたい待ち時間)、本末転倒になるため。
///
/// actorそのものは(このプロジェクトの既定のMainActor隔離とは無関係に)固有の隔離を持つため、
/// `nonisolated`の指定は不要かつ書けない(ThumbnailDiskCacheと同じ)。
actor BookPageListCache {
    static let shared = BookPageListCache()

    /// 1冊分のキャッシュ。
    ///
    /// 本体が差し替えられていないかは、更新日時などの指紋ではなく、読み込み完了後に
    /// ページ一覧そのものを突き合わせて判断する(指紋より確実で、かつファイル属性を
    /// 読むための待ち時間も要らない)。
    struct Entry: Codable, Sendable {
        let pages: [Page]

        struct Page: Codable, Sendable, Equatable {
            /// PageRef.sortKey。行の安定した識別子であり、レイアウト設定(PageLayoutOverride)や
            /// 並べ替え(BookLayoutSettings.pageOrderOverride)のキーでもある。
            let sortKey: String
            /// PageRef.displayName。一覧のファイル名列に出す。
            let displayName: String
        }
    }

    /// キャッシュ全体の上限。1冊あたり500ページで24KB程度のため、50MBで2000冊分に相当する。
    private static let maxTotalBytes: Int = 50 * 1024 * 1024

    /// 保存先(~/Library/Caches/<bundle id>/BookPageLists)。作成に失敗した場合はnilになり、
    /// このキャッシュは「常にミスする」だけの無害な存在になる。
    private let directory: URL?
    /// 起動後に一度だけ容量の刈り込みを行うためのフラグ。
    private var hasTrimmed = false

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let base else {
            directory = nil
            return
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "qooViewer"
        let url = base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("BookPageLists", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            directory = url
        } catch {
            directory = nil
        }
    }

    /// bookIDはファイルのパスなので、そのままではファイル名にできない。ハッシュ化して使う。
    private func fileURL(forBookID bookID: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(bookID.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".json"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    func pageList(forBookID bookID: String) -> Entry? {
        guard let url = fileURL(forBookID: bookID),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        return entry
    }

    func store(_ entry: Entry, forBookID bookID: String) {
        guard let url = fileURL(forBookID: bookID),
              let data = try? JSONEncoder().encode(entry)
        else { return }
        try? data.write(to: url, options: .atomic)

        // 起動後の最初の書き込みのタイミングで一度だけ容量を点検する(ThumbnailDiskCacheと
        // 同じ考え方)。1冊あたり数十KB程度と小さいが、二度と開かない本のぶんが際限なく
        // 積もらないようにしておく。
        if !hasTrimmed {
            hasTrimmed = true
            trimIfNeeded()
        }
    }

    /// 上限を超えていたら、最終アクセスが古いものから削除する。
    private func trimIfNeeded() {
        guard let directory else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }

        var files: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let size = values.fileSize ?? 0
            files.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > Self.maxTotalBytes else { return }

        // 上限の8割まで落とす(削除のたびにすぐ上限へ戻らないようにするため)。
        let target = Self.maxTotalBytes * 8 / 10
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > target else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// キャッシュを丸ごと捨てる(環境設定「リセット」タブの一括削除から呼ばれる)。
    func removeAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hasTrimmed = false
    }
}
