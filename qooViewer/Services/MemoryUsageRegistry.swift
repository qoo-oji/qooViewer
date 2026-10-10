import CoreGraphics
import Foundation
import os

/// リソースモニタの「メモリ」の内訳の帳簿(2026-10-11、利用者の要望: どの機能がどれだけメモリを使っているかを見えるように)。
///
/// ■ なぜ要るのか
/// 以前のモニタが内訳を出せたのは「このウインドウの本」1 冊だけで、ほかはすべて「この本のキャッシュ以外」の 1 行に入っていた。
/// リソースモニタを作った後に増えたもの ―― ファイルブラウザ・スマートライブラリのサムネイル、コレクションのカバーとタイル、
/// ブックマーク・レイアウトの編集や書き出しの本、原寸大や拡大の高解像度画像 ―― は、上限付きで意図して抱えているのに、どこにも
/// 出ていなかった。
///
/// ■ 形
/// メモリを抱える持ち主(本を読む `PageLoader`、アプリで 1 つのキャッシュ、一覧の画面など)が、**自分の使用量を答える閉包**を
/// ここへ届け出る(`MemoryUsageRegistration`)。モニタは 1 秒ごとに `report()` で全員に尋ね、機能(`MemoryUsageFeature`)ごとに
/// まとめて見せる。プロセスのフットプリントから届け出の合計を引いた残りが「内訳の無いメモリ」。
/// **新しくメモリを抱えるキャッシュを作ったら、ここへ届け出ること** ―― 届け出の無いものは「内訳の無いメモリ」に紛れる。
///
/// **テストはこれに触れない**(アプリ全体で 1 つの状態のため。RunningWorkRegistry と同じ)。届け出る側は `forCurrentProcess` を使い、
/// テストでは nil になる。帳簿そのもののテストは自前のインスタンスを作る。
///
/// nonisolated / ロック: 届け出るのは actor(PageLoader)・メインアクター・書き出しのタスクとさまざまなので、どこからでも呼べる。
nonisolated final class MemoryUsageRegistry: @unchecked Sendable {
    static let shared = MemoryUsageRegistry()

    /// 届け出る側が使う既定値。テストでは共有の状態に触れないよう nil。
    static var forCurrentProcess: MemoryUsageRegistry? {
        RuntimeEnvironment.isRunningTests ? nil : shared
    }

    typealias Provider = @Sendable () async -> [MemoryUsageItem]

    private struct Entry: Sendable {
        let ownerID: UUID
        /// nil なら、別の届け出(`ownerID` が同じもの)へ項目を足すだけの届け出(ビューアの拡大の画像を、その本の行へ足す)。
        let role: MemoryUsageRole?
        let order: Int
        let provider: Provider
    }

    private struct State {
        var entries: [UUID: Entry] = [:]
        var nextOrder = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    fileprivate func add(id: UUID, ownerID: UUID, role: MemoryUsageRole?, provider: @escaping Provider) {
        state.withLock { state in
            state.entries[id] = Entry(ownerID: ownerID, role: role, order: state.nextOrder, provider: provider)
            state.nextOrder += 1
        }
    }

    fileprivate func remove(id: UUID) {
        _ = state.withLock { $0.entries.removeValue(forKey: id) }
    }

    /// いま届け出ている持ち主の数(テスト用)。
    var entryCount: Int { state.withLock { $0.entries.count } }

    /// 全員に尋ねて、持ち主ごとにまとめる。並びは届け出た順(持ち主の最初の届け出の順)。
    /// 項目を足すだけの届け出(`role == nil`)は、同じ持ち主の本体が無ければ捨てる(本体が先に手放された)。
    func report() async -> [MemoryUsageOwner] {
        let entries = state.withLock { Array($0.entries.values) }.sorted { $0.order < $1.order }
        var owners: [UUID: MemoryUsageOwner] = [:]
        var extras: [UUID: [MemoryUsageItem]] = [:]
        var order: [UUID] = []
        for entry in entries {
            let items = await entry.provider()
            if let role = entry.role {
                if owners[entry.ownerID] == nil { order.append(entry.ownerID) }
                owners[entry.ownerID] = MemoryUsageOwner(id: entry.ownerID, role: role, items: items)
            } else {
                extras[entry.ownerID, default: []].append(contentsOf: items)
            }
        }
        return order.compactMap { id in
            guard var owner = owners[id] else { return nil }
            owner.items.append(contentsOf: extras[id] ?? [])
            return owner
        }
    }
}

/// 帳簿への届け出 1 つ。**持っている間だけ**届け出が残る(手放す・`end()`・deinit で外れる)。
///
/// 先に作って後から `activate` する形なのは、actor(PageLoader)の init の中で、自分を弱く捕まえる閉包を
/// 自分の `let` に入れるため(全部の格納プロパティが揃う前には閉包が作れない)。
nonisolated final class MemoryUsageRegistration: @unchecked Sendable {
    /// 持ち主の印。同じ持ち主へ項目を足す届け出(`activate(... role: nil)`)はこれを共有する。
    let ownerID: UUID
    private let id = UUID()
    private let active = OSAllocatedUnfairLock<MemoryUsageRegistry?>(initialState: nil)

    init(ownerID: UUID = UUID()) {
        self.ownerID = ownerID
    }

    /// 帳簿へ載せる(載っていれば置き換える)。`registry` が nil(テスト)なら何もしない。
    /// - Parameter role: nil なら、同じ `ownerID` の持ち主へ項目を足すだけ。
    func activate(in registry: MemoryUsageRegistry?, role: MemoryUsageRole?, provider: @escaping MemoryUsageRegistry.Provider) {
        guard let registry else { return }
        registry.add(id: id, ownerID: ownerID, role: role, provider: provider)
        active.withLock { $0 = registry }
    }

    /// 帳簿から外す。何度呼んでもよい。
    func end() {
        let registry = active.withLock { current in
            let registry = current
            current = nil
            return registry
        }
        registry?.remove(id: id)
    }

    deinit { end() }
}

// MARK: - 値

/// メモリを使う機能のまとまり(モニタの折り畳みの単位)。
nonisolated enum MemoryUsageFeature: String, CaseIterable, Sendable {
    /// 本を読む画面(ビューア・サイドパネル・原寸大のウインドウ)。
    case viewer
    /// 本を読む道具のウインドウ(ブックマーク・レイアウトの編集、本の書き出し)。
    case toolWindows
    /// ホーム(ファイルブラウザ・ライブラリ・スマートライブラリ・インスペクタ)。
    case home
}

/// 届け出た持ち主が何者か(モニタの行の名前と、どの機能に入るか)。本の名前は、シークレットウインドウ・シークレットフォルダの
/// 本では nil(名前を出さない ―― 痕跡を残さない約束。AppState.isPrivateWindow)。
nonisolated enum MemoryUsageRole: Equatable, Sendable {
    /// ビューアで開いている本(PageLoader + 拡大の高解像度画像)。
    case viewerBook(title: String?)
    /// サイドパネル下段(本の中身)が自分で開いている入れ子の書庫(BookContentsBrowserState)。
    case bookContents
    /// 原寸大のウインドウの画像。
    case actualSize
    /// ビューアのページ一覧(ThumbnailGridView)のセルが抱えている絵。
    case pageListCells
    /// サイドパネルのページモードのセルが抱えている絵。
    case sidePanelPageCells
    /// ブックマーク・レイアウトの編集ウインドウの本。
    case bookmarkEditor(title: String?)
    /// ブックマーク・レイアウトの編集ウインドウの右ペインのセルが抱えている絵。
    case bookmarkEditorCells
    /// 書き出しのウインドウの「カバーにするページ」の選択で読んでいる本。
    case exportCoverPicker(title: String?)
    /// 書き出している本。
    case exporting
    /// 上のどれでもない本の読み込み(PageLoader の既定値。アプリの中の呼び出しはどれも役を渡す)。
    case otherBookReading
    /// ホームのアプリで 1 つのキャッシュ(サムネイル・コレクションのカバーとタイル)。
    case homeCaches
    /// コレクションのカバーを作るために読んでいる本(CoverImageResolver。1 枚ごとに短い間だけ)。
    case coverExtraction
    /// ライブラリのコレクションの一覧のセルが抱えている絵。
    case collectionGridCells
    /// コレクションの中の一覧のセルが抱えている絵。
    case collectionItemCells
    /// スマートライブラリの表紙のグリッドのセルが抱えている絵。
    case smartLibraryCells

    var feature: MemoryUsageFeature {
        switch self {
        case .viewerBook, .bookContents, .actualSize, .pageListCells, .sidePanelPageCells:
            return .viewer
        case .bookmarkEditor, .bookmarkEditorCells, .exportCoverPicker, .exporting, .otherBookReading:
            return .toolWindows
        case .homeCaches, .coverExtraction, .collectionGridCells, .collectionItemCells, .smartLibraryCells:
            return .home
        }
    }

    /// 使用量が 0 の間は行を出さない持ち主(ふだんは 0 の、付け足しの持ち主)。本そのものは 0 でも出す。
    var hidesWhenEmpty: Bool {
        switch self {
        case .bookContents, .coverExtraction, .pageListCells, .sidePanelPageCells, .bookmarkEditorCells,
             .collectionGridCells, .collectionItemCells, .smartLibraryCells:
            return true
        default:
            return false
        }
    }
}

/// メモリの使い道の種類(モニタの項目の名前と、上限超過の判定の単位)。
nonisolated enum MemoryUsageKind: String, CaseIterable, Sendable {
    case pageImages
    case thumbnails
    case gridThumbnails
    case nestedArchives
    case sevenZipDecoder
    /// 拡大(ピンチ・拡大鏡)のための高解像度画像(ViewerViewModel.highResolutionSourceImages など)。
    case zoomImages
    case actualSizeImage
    case fileBrowserThumbnails
    case collectionCovers
    case collectionTiles
    /// Lazy な一覧のセルが抱えている絵(LazyCellImageBudget の帳簿)。キャッシュの絵と同じバッファを共有していることが
    /// あるので**見積もり**で、合計には足さない(`countsTowardTotal`)。
    case cellImages

    /// 合計(機能ごと・「内訳の無いメモリ」の引き算)に足すか。
    var countsTowardTotal: Bool { self != .cellImages }
}

/// 1 つの使い道の使用量。
nonisolated struct MemoryUsageItem: Equatable, Sendable {
    var kind: MemoryUsageKind
    var usedBytes: Int
    /// 上限(無ければ nil)。
    var limitBytes: Int?
    /// 件数(数えないものは nil)。
    var count: Int?

    var isOverLimit: Bool {
        guard let limitBytes else { return false }
        return usedBytes > limitBytes
    }

    /// CGImage の並びの使用量(ビットマップの大きさ)。
    static func images(_ kind: MemoryUsageKind, _ images: [CGImage]) -> MemoryUsageItem {
        MemoryUsageItem(kind: kind, usedBytes: images.reduce(0) { $0 + $1.bytesPerRow * $1.height }, count: images.count)
    }

    /// 本を読む `PageLoader` の項目(3 つのキャッシュ・メモリの上の入れ子の書庫・7z のデコーダ)。
    static func items(from statistics: PageCacheStatistics) -> [MemoryUsageItem] {
        [
            MemoryUsageItem(kind: .pageImages, usedBytes: statistics.pageImages.totalBytes,
                            limitBytes: statistics.pageImageLimitBytes, count: statistics.pageImages.count),
            MemoryUsageItem(kind: .thumbnails, usedBytes: statistics.thumbnails.totalBytes,
                            limitBytes: statistics.thumbnailLimitBytes, count: statistics.thumbnails.count),
            MemoryUsageItem(kind: .gridThumbnails, usedBytes: statistics.gridThumbnails.totalBytes,
                            limitBytes: statistics.gridThumbnailLimitBytes, count: statistics.gridThumbnails.count),
            MemoryUsageItem(kind: .nestedArchives, usedBytes: statistics.nestedArchives.inMemoryBytes,
                            limitBytes: statistics.nestedArchives.inMemoryLimitBytes,
                            count: statistics.nestedArchives.inMemoryArchiveCount),
            MemoryUsageItem(kind: .sevenZipDecoder, usedBytes: statistics.nestedArchives.decompressionBufferBytes),
        ]
    }
}

/// 持ち主 1 人ぶん。
nonisolated struct MemoryUsageOwner: Equatable, Sendable, Identifiable {
    var id: UUID
    var role: MemoryUsageRole
    var items: [MemoryUsageItem]

    var feature: MemoryUsageFeature { role.feature }

    /// 合計に足す項目の和。
    var totalBytes: Int {
        items.filter(\.kind.countsTowardTotal).reduce(0) { $0 + $1.usedBytes }
    }

    /// 見積もり(合計に足さない項目)の和。
    var estimatedBytes: Int {
        items.filter { !$0.kind.countsTowardTotal }.reduce(0) { $0 + $1.usedBytes }
    }

    var isEmpty: Bool { items.allSatisfy { $0.usedBytes == 0 } }

    /// 本を読んでいる持ち主か(一時ファイルの「持ち主がいないのに残っている」の判定に使う)。
    var readsBook: Bool {
        switch role {
        case .viewerBook, .bookContents, .bookmarkEditor, .exportCoverPicker, .exporting, .otherBookReading,
             .coverExtraction:
            return true
        default:
            return false
        }
    }
}

/// モニタに出す形(機能ごとのまとまりと合計)。値型で Equatable なのは、変わっていなければ描き直さないため。
nonisolated struct MemoryUsageBreakdown: Equatable, Sendable {
    struct Group: Equatable, Sendable, Identifiable {
        var feature: MemoryUsageFeature
        /// 出す持ち主(`hidesWhenEmpty` で空のものは除いてある)。
        var owners: [MemoryUsageOwner]
        var id: MemoryUsageFeature { feature }
        var totalBytes: Int { owners.reduce(0) { $0 + $1.totalBytes } }
    }

    /// 3 つの機能を常にこの順で(空のまとまりも出す ―― どの画面でも同じ形で読めるように)。
    var groups: [Group]
    /// 全員の合計(合計に足す項目だけ)。
    var attributedBytes: Int
    /// 本を読んでいる持ち主の数(空のものも数える)。
    var bookReaderCount: Int

    init(owners: [MemoryUsageOwner]) {
        groups = MemoryUsageFeature.allCases.map { feature in
            Group(feature: feature, owners: owners.filter { $0.feature == feature && !($0.role.hidesWhenEmpty && $0.isEmpty) })
        }
        attributedBytes = owners.reduce(0) { $0 + $1.totalBytes }
        bookReaderCount = owners.filter(\.readsBook).count
    }

    /// フットプリントから内訳の合計を引いた残り。キャッシュの帳簿は圧縮前の大きさで数えるので、フットプリント(圧縮後)の
    /// ほうが小さくなることがある ―― そのときは引き算に意味が無いので nil(「—」)。
    func unattributedBytes(footprint: Int) -> Int? {
        let rest = footprint - attributedBytes
        return rest >= 0 ? rest : nil
    }
}
