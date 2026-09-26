import AppKit

/// 「ウインドウ」メニューの下端に並ぶ、開いているウインドウの一覧を**タブのグループごとにまとめる**
/// (2026-09-27、利用者の指摘: 並びがグループごとに揃っていない)。アプリ全体で 1 つ(shared)。
///
/// ■ AppKit の並べ方(2026-09-27、AppKit 単体の実験プログラムで実測)
/// 一覧は**タイトルの字順**(大文字小文字を区別しない)で、タブのグループを見ない。同じウインドウのタブでも、
/// 間に別のウインドウが挟まる。しかも一覧が変わるたび(ウインドウが増える・閉じる・タイトルが変わる・しまう)に
/// 全部を外して字順に入れ直すので、項目を並べ替えても次の変化で元へ戻る。一方、タブを結合・切り離し・並べ替え
/// しても一覧の項目は何も変わらない(並べ直されもしない)。
///
/// ■ やり方
/// AppKit の字順を土台にして、**グループの中でいちばん前にいる項目の位置に、そのグループのタブをタブの並び順で寄せる**
/// (`groupedOrder`)。グループどうしの並びと 1 枚だけのウインドウの並びは AppKit のまま。
/// 寄せ直すのは次の 2 つの契機で、望む並びと同じなら何もしない(項目の差し替えをしない):
/// - 一覧の項目が変わった(AppKit が字順に入れ直した)。AppKit の入れ直しが終わってから寄せるよう、1 回ランループを跨ぐ
/// - イベントを 1 つ処理し終えた(`NSApplication.didUpdateNotification`)。タブの結合・切り離し・並べ替えは項目の変化として
///   届かないので、こちらで拾う。比べるのは項目 20 個ほどの並びだけ
///
/// ■ 触らないもの
/// - メニューバーのメニューが開いている間(`MenuBarMenuGate.isTracking`)。開いている最中の項目の差し替えは macOS 26 で
///   落ちる(`MenuBarMenuGate` の型コメント)。閉じたあとの次のイベントで寄せる
/// - ウインドウを指していない項目(メニューの固定の項目、`Window` シーンの SwiftUI の項目)。動かすのはウインドウを指す項目
///   (target が `NSWindow`)だけで、それらが占めていた位置の中で入れ替える
@MainActor
final class WindowsMenuGrouper {
    static let shared = WindowsMenuGrouper()

    private let tokens = NotificationObserverTokens()
    /// 寄せ直しの最中(自分の差し替えで届く項目の通知を無視する)。
    private var isReordering = false
    /// 項目の通知からの寄せ直しを予約済みか(AppKit の入れ直しは項目ごとに通知が来るので、1 回にまとめる)。
    private var isScheduled = false

    private init() {
        let center = NotificationCenter.default
        tokens.add(center.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.regroupIfNeeded() }
        })
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            tokens.add(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, !self.isReordering, let menu = notification.object as? NSMenu,
                          menu === NSApp.windowsMenu
                    else { return }
                    self.scheduleRegroup()
                }
            })
        }
    }

    private func scheduleRegroup() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isScheduled = false
                self.regroupIfNeeded()
            }
        }
    }

    private func regroupIfNeeded() {
        guard !isReordering, !MenuBarMenuGate.shared.isTracking, let menu = NSApp.windowsMenu else { return }
        let items = menu.items
        let positions = items.indices.filter { items[$0].target is NSWindow }
        guard positions.count > 1 else { return }
        let current = positions.map { items[$0] }
        let ordered = Self.groupedOrder(
            current,
            groupKey: { item in
                let window = item.target as? NSWindow
                return window?.tabGroup.map(ObjectIdentifier.init) ?? window.map(ObjectIdentifier.init) ?? ObjectIdentifier(item)
            },
            rankInGroup: { item in
                guard let window = item.target as? NSWindow else { return 0 }
                return window.tabGroup?.windows.firstIndex(of: window) ?? 0
            }
        )
        guard !zip(current, ordered).allSatisfy({ $0 === $1 }) else { return }
        isReordering = true
        defer { isReordering = false }
        // 後ろから外し、占めていた位置へ前から入れる(ウインドウを指さない項目の位置は変わらない)。
        for position in positions.reversed() { menu.removeItem(at: position) }
        for (position, item) in zip(positions, ordered) { menu.insertItem(item, at: position) }
    }

    /// 並びを、グループごとにまとめた並びにする。グループは最初に現れた位置に置き、グループの中は `rankInGroup` の順
    /// (同じなら元の順)。グループどうしの順と、1 つだけのグループの位置は元のまま。
    nonisolated static func groupedOrder<Item, Key: Hashable>(
        _ items: [Item], groupKey: (Item) -> Key, rankInGroup: (Item) -> Int
    ) -> [Item] {
        var members: [Key: [(rank: Int, offset: Int, item: Item)]] = [:]
        var groupOrder: [Key] = []
        for (offset, item) in items.enumerated() {
            let key = groupKey(item)
            if members[key] == nil { groupOrder.append(key) }
            members[key, default: []].append((rankInGroup(item), offset, item))
        }
        return groupOrder.flatMap { key in
            (members[key] ?? []).sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }.map(\.item)
        }
    }
}
