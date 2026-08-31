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

        // MARK: - 構造キャッシュ(本そのものを組み立て直すための情報)
        //
        // ■ なぜ同じキャッシュに相乗りさせるのか
        // 入れ子の書庫を含む本は、ページを数え上げるだけでも中の書庫を1つずつ取り出す必要が
        // あり(zipの中央ディレクトリはファイル末尾にあり、rar/7zも索引を読むには本体が要る)、
        // 開くたびに本1冊ぶんの伸長を払っていた。2回目以降はその走査ごと飛ばしたい。
        //
        // 新しいキャッシュを別に作らないのは、**シークレットウインドウで書かないためのガードを
        // 1箇所に保つため**(AppState.isPrivateWindowのコメントに列挙されている「書かないもの」に、
        // 保管庫が2つ並ぶ状態にしたくない)。書き込みの入口はBookLoader.load(from:cachesPageList:)
        // ただ1つのままになる。
        //
        // すべてオプショナルにしてあるので、この仕組みを入れる前に保存されたJSONもそのまま
        // 復号でき(欠けている項目はnilになる)、移行処理は要らない。復元に必要な項目が1つでも
        // 欠けていれば、単に従来どおりの完全な読み込みに落ちる。
        //
        /// このJSONを書いた時点の構造キャッシュの版。組み立て方を変えたら上げること
        /// (古い版は復元に使わず、フルの読み込みに落ちる)。
        var schemaVersion: Int?
        /// 本そのもののパス(ArchiveLocator.rootURL)。各ページのidを組み立て直すのに使う。
        var rootPath: String?
        /// 保存した時点の本体の指紋。合わなければ中身が差し替わったとみなして使わない。
        var fingerprint: Fingerprint?
        /// この本が入れ子の書庫を含んでいたか。**含んでいた本にだけ**高速経路を使う ――
        /// 平なcbzは元々列挙が一瞬で終わるので、キャッシュの整合性に賭ける理由が無い。
        var hasNestedArchives: Bool?
        /// 保存した時点の「並び順をFinderに揃える」の設定(PageOrder.usesFinderOrder)。
        /// pagesは並べ替え済みの順そのものを持っているため、設定が切り替わった後の
        /// 復元に使うと**古い並びのまま開いてしまう**。合わなければ使わない。
        var usesFinderSortOrder: Bool?

        /// 現在の版。
        /// 2: ページの並べ替えを`.numeric`比較からcomparePageOrder(既定でFinderと同じ照合)へ
        ///    変更。保存されているのは並べ替え済みの順そのものなので、古い版は捨てて読み直す。
        ///    どちらの並びで保存したかはusesFinderSortOrderが持つ。
        static let currentSchemaVersion = 2

        /// 本体が差し替わっていないかを見るための軽い指紋(ContentFingerprintと同じ考え方で、
        /// フルハッシュは取らない)。ページ数は`pages.count`が持っているので含めない。
        struct Fingerprint: Codable, Sendable, Equatable {
            var modificationDate: Date?
            var fileSize: Int64?

            /// 実ファイルから今の指紋を読む。属性が1つも取れなければnil(=照合しない)。
            ///
            /// **URL.resourceValues(forKeys:)を使ってはいけない。** あちらは一度読んだ値を
            /// そのURLインスタンスに**キャッシュする**ため、同じURLを持ち回っている経路では
            /// ファイルが差し替わっても古い更新日時が返り続ける。実際、この照合を
            /// resourceValuesで書いたところ、ファイルの更新日時を変えた直後でも
            /// 「変わっていない」と判定してキャッシュを使ってしまった(検証で確認)。
            /// FileManager.attributesOfItemは毎回ファイルシステムに問い合わせる。
            static func current(for url: URL) -> Fingerprint? {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                    return nil
                }
                let modificationDate = attributes[.modificationDate] as? Date
                let fileSize = (attributes[.size] as? NSNumber)?.int64Value
                guard modificationDate != nil || fileSize != nil else { return nil }
                return Fingerprint(modificationDate: modificationDate, fileSize: fileSize)
            }
        }

        struct Page: Codable, Sendable, Equatable {
            /// PageRef.sortKey。行の安定した識別子であり、レイアウト設定(PageLayoutOverride)や
            /// 並べ替え(BookLayoutSettings.pageOrderOverride)のキーでもある。
            let sortKey: String
            /// PageRef.displayName。一覧のファイル名列に出す。
            let displayName: String
            /// この画像が入っているフォルダ/書庫の、本の直下からの相対パス
            /// (PageLocation.folderPath)。ファイル名と一緒に表示して、書庫の中のフォルダ・
            /// 入れ子の書庫のどこにある画像なのかが分かるようにするためのもの。
            /// 本の直下にある画像ではnil。この項目を入れる前に保存されたJSONでもnilになり、
            /// その場合は従来どおりファイル名だけの表示に戻るだけ(本体を読み込み終えた
            /// 時点で行が組み立て直され、そこで埋まる)。
            var folderPath: String?

            // 以下は構造キャッシュ用(上のMARK参照)。
            //
            /// PageRef.idのうち、`Entry.rootPath`より後ろの部分。
            /// **idそのものを持たない**のは、ページごとに本のフルパスを繰り返すと
            /// 1冊ぶんのJSONが倍以上に膨らむため。
            var idSuffix: String?
            /// この画像が入っている書庫の、rootPathからの道順(ArchiveLocator.nestedPath)。
            /// 本そのものの書庫に直接入っている画像なら空配列。
            var nestedPath: [String]?
            /// その書庫の中でのエントリパス(PageSource.archiveのentryPath)。
            var entryPath: String?
            /// EPUBが指定していた見開き内の配置(PageRef.epubSpreadPosition)。
            /// 高速経路はEPUBを対象にしないので実際には常にnilだが、
            /// PageRefを完全に組み立て直せる形にしておくために持たせてある。
            var spreadPosition: PageSpreadPosition?
        }
    }

    /// キャッシュ全体の上限。1冊あたり500ページで24KB程度のため、50MBで2000冊分に相当する。
    private static let maxTotalBytes: Int = 50 * 1024 * 1024

    /// 保存先(~/Library/Caches/<bundle id>/BookPageLists)。作成に失敗した場合はnilになり、
    /// このキャッシュは「常にミスする」だけの無害な存在になる。
    ///
    /// `nonisolated let`にしてあるのは、読み書きの本体(JSONの変換とファイルI/O)をこのactorの
    /// **外**で実行するため。actor上で実行すると、1冊分の書き込みや容量点検のあいだ、他の本の
    /// ページ一覧の読み出しがすべて待たされる。読み出しは「ブックマーク・レイアウトの編集」
    /// ウインドウで本を選び直したときの表示速度に直結するため、待たせたくない
    /// (ThumbnailDiskCacheのdirectoryと同じ理由・同じ形)。
    private nonisolated let directory: URL?
    /// 起動後に一度だけ容量の刈り込みを行うためのフラグ。
    /// 実際にactorの隔離が要るのはこれだけなので、ここだけをactor上に残す。
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
    /// ファイルの置き場所を求めるだけの純粋な計算(ディスクには触れない)。
    private nonisolated func fileURL(forBookID bookID: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(bookID.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".json"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    /// `nonisolated`: ファイルの読み出しとJSONの復元をactorの上で行わないため
    /// (directoryのコメント参照)。`async`のまま残してあるのは、呼び出し側の`await`を
    /// そのまま有効にしておくためと、将来actorの状態が要るようになったときに
    /// 呼び出し側を変えずに済むため。
    nonisolated func pageList(forBookID bookID: String) async -> Entry? {
        guard let url = fileURL(forBookID: bookID),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        return entry
    }

    /// `nonisolated`の理由はpageList(forBookID:)と同じ。
    ///
    /// 書き込みは`.atomic`(一時ファイルへ書いてからリネーム)で行う。読み書きをactorの外へ
    /// 出した以上、書き込み途中のファイルを他のタスクが読みうるため、読み手が常に
    /// 「以前の内容」か「完成した内容」のどちらかしか見ないようにしておく必要がある。
    nonisolated func store(_ entry: Entry, forBookID bookID: String) async {
        guard let url = fileURL(forBookID: bookID),
              let data = try? JSONEncoder().encode(entry)
        else { return }
        try? data.write(to: url, options: .atomic)

        // 起動後の最初の書き込みのタイミングで一度だけ容量を点検する(ThumbnailDiskCacheと
        // 同じ考え方)。1冊あたり数十KB程度と小さいが、二度と開かない本のぶんが際限なく
        // 積もらないようにしておく。
        // 「一度だけ」の判定はhasTrimmedの読み書きを伴うのでactor上で行い、実際の走査は
        // その外で行う(走査中に他のページ一覧の読み出しを待たせないため)。
        guard await claimTrim(), let directory else { return }
        Self.trimIfNeeded(in: directory)
    }

    /// 起動後まだ容量点検を行っていなければ、行う権利を1つだけ取得する。
    private func claimTrim() -> Bool {
        guard !hasTrimmed else { return false }
        hasTrimmed = true
        return true
    }

    /// 上限を超えていたら、最終アクセスが古いものから削除する。
    /// `nonisolated static`: ディレクトリ全走査をactorの上で行わないため。
    private nonisolated static func trimIfNeeded(in directory: URL) {
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
