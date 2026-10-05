import Foundation

/// **アプリ自身が**移した・名前を変えた本の保存データを、新しいパスへ付け替える段取り(2026-09-19 の監査の H1。
/// docs/plans/fs-ui-consistency-audit.md)。
///
/// ■ なぜ要るか
/// 保存データ(ブックマーク・レイアウト・メタデータ・棚の本・お気に入り)は `bookID`(パス)で引き、外れたときは本を開いた時点で
/// `FileNodeIdentifier`(inode + ボリューム)から追従する(各ストアの `reconcileBookIDIfMoved`)。それは「移すのはアプリの外」
/// だった頃の作りで、**別ボリュームへの移動は inode が変わるので追えない**(docs/06「移動・リネームへの追従」)。いまは
/// ファイルブラウザ自身が移すので、新旧のパスが分かっている(`FileSystemChange.relocations`)。それを使えば別ボリュームでも、
/// 本を開くのを待たずに、フォルダごと移した中の本もまとめて付け替えられる。
///
/// ■ 決まり
/// - 付け替えるのは `bookID` が移った項目自身か、その配下にある行。
/// - **移った先のパスにすでに行があるストアでは付け替えない**(`reconcileBookIDIfMoved` と同じ。置き換えで上書きした本の行を黙って
///   混ぜない)。
/// - 別ボリュームへ移した本は inode もブックマークも変わるので、新しい場所で取り直す(`locators`)。同じボリュームの中なら
///   どちらもそのまま使える(ブックマークは移動に付いていく)。
/// - 取り消しで戻したときも、同じ仕組みで元のパスへ戻る(取り消しも `FileOperationService` を通る)。
nonisolated struct BookRelocationPlan: Sendable {
    /// 別ボリュームへ移した本の、新しい場所の手がかり。
    struct Locator: Sendable {
        let identifier: FileNodeIdentifier?
        let bookmarkData: Data?
    }

    /// 古い `bookID` → 新しい `bookID`。
    let bookIDs: [String: String]
    /// 新しい `bookID` → 取り直した手がかり(別ボリュームへ移したものだけ)。
    let locators: [String: Locator]
    /// 新しい `bookID` のうちフォルダの本(棚のキャプションの付け替えに使う。`derivedTitle`)。
    let directoryBookIDs: Set<String>

    var isEmpty: Bool { bookIDs.isEmpty }

    /// 付け替えの知らせ(`.layoutDataDidChange` / `.bookmarksDidChange`)の userInfo の鍵。値は付け替えた本の古い・新しい
    /// `bookID`(`Set<String>`)。`"bookID"` の無い知らせは「全部が変わった」として受け手が全部を読み直すので、開いている本の
    /// ビューアはこれを見て、自分の本が入っていなければ読み直さない(2026-09-25 の監査。以前はアプリの中でファイルを 1 つ
    /// 動かすたびに、開いている全冊のビューアが Bookmark の全件のフェッチとレイアウトの組み直しをしていた)。
    static let relocatedBookIDsUserInfoKey = "relocatedBookIDs"

    /// `moves` で付け替えた本の古い・新しい `bookID`(知らせに付ける)。
    static func relocatedBookIDs(_ moves: [String: String]) -> Set<String> {
        Set(moves.keys).union(moves.values)
    }

    /// あるストアで実際に動かす組(古い → 新しい)。`present` はそのストアに行のある bookID。
    ///
    /// 「移った先に行があるなら付け替えない」の決まりを、**付け替えの後の姿で**当てる(2026-09-22 の監査): 移った先の行自身も
    /// この付け替えで出ていくなら、その先は空く(A → B と C → A が続けて届いた・A と B を入れ替えた)。以前は付け替える前の行で
    /// 「埋まっている」と見て、C の保存データを実在しないパスに取り残した。出ていくはずの行が自分の行き先で止められたら、その行は
    /// 動かず、そこへ入るはずだった組も止める(同じパスに行が 2 つできないように、止まる組が無くなるまで繰り返す)。
    /// 同じ行き先へ 2 つ来たら、古いパスの名前順で先のほうだけ。
    func moves(present: Set<String>) -> [String: String] {
        var moves: [String: String] = [:]
        var claimed = Set<String>()
        for old in bookIDs.keys.sorted() where present.contains(old) {
            guard let new = bookIDs[old], new != old, claimed.insert(new).inserted else { continue }
            moves[old] = new
        }
        var changed = true
        while changed {
            changed = false
            for (old, new) in moves where present.contains(new) && moves[new] == nil {
                moves[old] = nil
                changed = true
            }
        }
        return moves
    }

    /// `knownBookIDs`(どれかのストアに行のある本)のうち、`change` で移ったものの付け替えを組む。
    /// 手がかりの取り直しはファイルに触るので、**メインアクターの外で呼ぶ**。
    static func make(knownBookIDs: Set<String>, change: FileSystemChange, mounts: MountTable = .current()) -> BookRelocationPlan {
        var bookIDs: [String: String] = [:]
        var locators: [String: Locator] = [:]
        var directories: Set<String> = []
        // 移った元の祖先を持たない本は、組を 1 つずつ当てる前に外す(パスの深さぶんの辞書引き)。以前は記録のある全冊に
        // `relocatedPath`(組の数ぶん回る)を当てていたので、2 万冊 × 2000 件の一括リネームで数十秒ぶんの CPU を使った
        // (2026-10-05 の効率の監査 A3)。
        let displaced = change.displacedPathSet
        let relocator = change.relocator()
        for old in knownBookIDs {
            guard FileSystemChange.mayAffect(old, displaced: displaced),
                  let new = relocator.relocatedPath(for: old), new != old else { continue }
            bookIDs[old] = new
            let oldURL = URL(fileURLWithPath: old), newURL = URL(fileURLWithPath: new)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: new, isDirectory: &isDirectory), isDirectory.boolValue { directories.insert(new) }
            guard !mounts.areOnSameVolume(oldURL, newURL) else { continue }
            locators[new] = Locator(
                identifier: FileNodeIdentifier.current(for: newURL),
                bookmarkData: try? newURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            )
        }
        return BookRelocationPlan(bookIDs: bookIDs, locators: locators, directoryBookIDs: directories)
    }

    /// 2 つの計画を合わせる(`BookRecordRelocator.apply` が、計画を作っている間に増えた行のぶんを足す。2026-10-04 のレビューの R4-1)。
    /// 同じ古い bookID が両方にあれば、こちらのものを残す(同じ変更から作るので行き先は同じ)。
    func merging(_ other: BookRelocationPlan) -> BookRelocationPlan {
        BookRelocationPlan(
            bookIDs: bookIDs.merging(other.bookIDs) { mine, _ in mine },
            locators: locators.merging(other.locators) { mine, _ in mine },
            directoryBookIDs: directoryBookIDs.union(other.directoryBookIDs)
        )
    }

    /// 本のファイル名から決まる題(`BookLoader` が `MangaBook.title` に入れるのと同じ: フォルダは名前そのまま、ファイルは拡張子を除く)。
    static func derivedTitle(forBookID bookID: String, isDirectory: Bool) -> String {
        let url = URL(fileURLWithPath: bookID)
        return isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}

/// **フォルダの本のページの鍵は絶対パス**(`PageRef.sortKey`。BookLoader.collectPages ―― 中の書庫・PDF のページも、その書庫の絶対パスが頭に付く)。
/// 本が移る・名前が変わると `bookID` だけでなく鍵の頭も変わるので、鍵で持っている保存データ(`PageLayoutOverride.pageKey`・
/// `BookLayoutSettings.coverPageKey` / `shelfCoverPageKey` / `pageOrderOverride`・`Bookmark.pageKey`・`BookReadingState.lastPageKey`)も
/// 一緒に付け替える(並べ替えは最初の版で漏れていた。2026-09-21 の監査の M1)。
///
/// 2026-09-21 まで付け替えていたのは `bookID` だけで、フォルダの本を移すと、ページ単位のレイアウト・「本の中のページ」で選んだ表紙が
/// 黙って外れ、ブックマークは番号へ落ちた(鍵が合わないので、並びが変わると別のページを指す)。feature-toggle-audit.md §7 で見つけた件。
/// 書庫・PDF・EPUB の本の鍵は本の中で閉じている(`/` で始まらない)ので、ここでは何も変わらない。
nonisolated enum PageKeyRelocation {
    /// `old` の本の鍵を `new` の本の鍵にする。付け替えが要らない鍵(本の中で閉じた鍵・その本の配下でない鍵)は nil。
    static func relocated(_ pageKey: String, fromBookID old: String, toBookID new: String) -> String? {
        guard old != new, old.hasPrefix("/"), pageKey.hasPrefix(old + "/") else { return nil }
        return new + pageKey.dropFirst(old.count)
    }

    /// 付け替え漏れの鍵(2026-09-21 より前に移した本の行)を、いまの本のページから求め直す。
    ///
    /// 漏れた鍵は「昔の本のパス + 本の中の相対パス」。昔のパスは分からないので、**いまの本のページの相対パスで終わる鍵**を探し、
    /// 残りを昔のパスの候補とする。漏れた鍵の全部(対応するページがもう無い鍵は除く)に共通する候補が**ちょうど 1 つ**のときだけ直す ――
    /// 2 つ以上あり得るとき(昔のフォルダ名と同じ名前のサブフォルダに、同じ名前の画像があるような場合)は、推測せず何もしない。
    /// - Parameters:
    ///   - keys: その本の行が持っている鍵。
    ///   - currentPageKeys: いま開いた本のページの鍵(`PageRef.sortKey`)。
    /// - Returns: 直す鍵 → 新しい鍵。
    static func repairs(forStaleKeys keys: [String], bookID: String, currentPageKeys: [String]) -> [String: String] {
        guard bookID.hasPrefix("/") else { return [:] }
        let prefix = bookID + "/"
        let current = Set(currentPageKeys)
        let relatives = Set(currentPageKeys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(bookID.count)) })
        guard !relatives.isEmpty else { return [:] }
        let stale = Set(keys.filter { $0.hasPrefix("/") && !$0.hasPrefix(prefix) && !current.contains($0) })
        guard !stale.isEmpty else { return [:] }
        var rootsByKey: [String: Set<String>] = [:]
        for key in stale {
            let roots = Set(relatives.filter { key.hasSuffix($0) && key.count > $0.count }.map { String(key.dropLast($0.count)) })
            if !roots.isEmpty { rootsByKey[key] = roots }
        }
        guard var common = rootsByKey.values.first else { return [:] }
        for roots in rootsByKey.values { common.formIntersection(roots) }
        guard common.count == 1, let root = common.first else { return [:] }
        var result: [String: String] = [:]
        for key in rootsByKey.keys { result[key] = bookID + key.dropFirst(root.count) }
        return result
    }
}

/// **本の保存データを新しいパスへ付け替えた**、という知らせ(`.booksDidRelocate`。2026-10-04 の監査 §1-7 ―― 段 4 で決めた形)。
///
/// ■ なぜ要るか
/// 付け替えはストアの行を書き換えるだけで、**画面の側が握っている bookID**(書き出しウインドウのチェックと題の編集、編集ウインドウの
/// 選択・保留中の確認・取り消しの控え、メタデータの編集の一覧、インスペクタの打ちかけ)は古いパスのまま残った(TW-5・BE-7・BE-13・
/// MD-2・SL-1)。ストアの知らせ(`relocatedBookIDsUserInfoKey`)は古い・新しい bookID を混ぜた集合で、対応が無い。
///
/// ■ なぜこの形か(採らなかった案)
/// - 画面が `FileSystemChangeCenter` を購読する案: あの箱が運ぶのは**アプリの中の操作**だけで、アプリの外での移動を見つけた経路
///   (起動後の `ExternalMoveSweeper`・コレクションの実在確認・フォルダの設定の追従・メタデータの編集ウインドウ・本を開いたときの
///   `reconcileBookIDIfMoved`)は箱を通らずに付け替える。画面がそれを受けられない。
/// - 各ストアの知らせに旧 → 新を載せる案: ストアごとに「そのストアで動いた行」しか言えず(移った先に行があれば動かない)、
///   メタデータのストアは bookID の無い知らせを出す。画面は 5 つの知らせを継ぎ合わせることになる。
/// 付け替えは必ず `BookRecordRelocator.apply`(アプリの中の操作も外の移動も)か、本を開いたときの付け替え(AppState)を通るので、
/// **その 2 か所が、ストアと読書位置を書き換え終えた直後に 1 回出す**。中身は付け替えに使った `FileSystemChange`(起きた順、
/// または同じ時点の写し)そのもので、受け手は自分の握っている bookID を `newBookID(for:)` で引き直す ―― どのストアにも行の無い本
/// (インスペクタで初めてメタデータを打っている本)にも答えられる。
///
/// ■ 受け手の決まり
/// - 同じメインアクターの番の中で、ストアの知らせ(`.layoutDataDidChange` など)の**後**に届く。ストアの知らせで裏の読み直しを
///   始めた受け手は、この知らせで世代を進めて、付け替えの前に集めた結果を捨てる(書き出しウインドウ)。
/// - テストの中でも `NotificationCenter.default` に出る(ほかのストアの知らせと同じ)。受け手は自分の握っている bookID しか書き換えない
///   ので、並んで走る別のテストの知らせを受けても何も起きない。
nonisolated struct BookRelocationNotice: Sendable {
    /// `.booksDidRelocate` の userInfo の鍵。値はこの型。
    static let userInfoKey = "notice"

    /// 付け替えに使った変更(`relocations` だけを見る)。
    let change: FileSystemChange
    /// `change` の付け替えの索引(受け手は握っている bookID の数だけ引くので、1 回ごとに組を全部なめない。2026-10-05 の効率の監査 A3)。
    private let relocator: FileSystemChange.Relocator

    init(change: FileSystemChange) {
        self.change = change
        relocator = change.relocator()
    }

    /// 知らせから取り出す。この型の知らせでなければ nil。
    init?(_ notification: Notification) {
        guard let notice = notification.userInfo?[Self.userInfoKey] as? BookRelocationNotice else { return nil }
        self = notice
    }

    /// `bookID` の本(またはその入ったフォルダ)が移っていれば、移った先の bookID。移っていなければ nil。
    func newBookID(for bookID: String) -> String? {
        guard let new = relocator.relocatedPath(for: bookID), new != bookID else { return nil }
        return new
    }

    /// `bookID` の今の bookID(移っていなければそのまま)。
    func current(_ bookID: String) -> String { newBookID(for: bookID) ?? bookID }

    /// 鍵が bookID の辞書を引き直す。移った先にすでに値があれば、そちらを残す(付け替えの「移った先に行があれば動かさない」と同じ)。
    /// 2 つが同じ先へ移ったら、古い bookID の名前順で先のほう(`BookRelocationPlan.moves` と同じ)。
    func rekeyed<Value>(_ dictionary: [String: Value]) -> [String: Value] {
        var result: [String: Value] = [:]
        var moved: [(old: String, new: String, value: Value)] = []
        for (bookID, value) in dictionary {
            if let new = newBookID(for: bookID) {
                moved.append((bookID, new, value))
            } else {
                result[bookID] = value
            }
        }
        for entry in moved.sorted(by: { $0.old < $1.old }) where result[entry.new] == nil {
            result[entry.new] = entry.value
        }
        return result
    }

    /// bookID の集合を引き直す。
    func rekeyed(_ bookIDs: Set<String>) -> Set<String> {
        Set(bookIDs.map(current))
    }

    /// 付け替えを終えたことを知らせる(`BookRecordRelocator.apply` と、本を開いたときの付け替え ―― 型コメント)。
    @MainActor
    static func post(_ change: FileSystemChange) {
        guard !change.relocations.isEmpty else { return }
        NotificationCenter.default.post(
            name: .booksDidRelocate, object: nil, userInfo: [userInfoKey: BookRelocationNotice(change: change)]
        )
    }
}

extension Notification.Name {
    /// 本の保存データを新しいパスへ付け替えた(`BookRelocationNotice`)。
    static let booksDidRelocate = Notification.Name("qooViewer.booksDidRelocate")
}
