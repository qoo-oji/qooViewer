import AppKit

/// 一覧(NSTableView / NSOutlineView)の「伸び縮みする列」(ファイルブラウザのリストの名前、スマートライブラリのリストの題)を、
/// 見えている幅にいつも合わせる(2026-09-27、利用者の報告)。
///
/// ■ なぜ要るのか
/// 列の幅は `autosaveTableColumns` が保存して、次に一覧を作ったときに戻す。**戻した幅の合計が今の一覧の幅より広いと、AppKit は
/// 合わせ直さない** ―― `.firstColumnOnlyAutoresizingStyle` が伸び縮みさせるのは、一覧の幅が**変わったとき**の差のぶんだけ。
/// 広いウインドウ(5K の全画面など)で保存された名前の列(実測 1935pt)がそのまま戻り、名前の列には余りがいくらでもあるのに、
/// 右の「種類」などの列が見切れて横のスクロールバーが出ていた。
///
/// ■ 何をするか(Finder のリスト表示と同じ)
/// 伸び縮みする列を「見えている幅 −(ほかの見えている列の幅 + 列の間隔)」にする(最小幅より狭くはしない ―― そのときだけ
/// 横にスクロールする)。合わせ直すのは、一覧の見えている幅が変わったとき・ほかの列の幅を利用者が変えたとき・列を出し入れしたとき・
/// 付けた直後。伸び縮みする列そのものを利用者が広げたときは合わせ直さない(広げた意図を尊重する。次に幅が変わったときに合う)。
@MainActor
final class TableFlexibleColumnFitter {
    private weak var table: NSTableView?
    private var flexibleColumn: NSUserInterfaceItemIdentifier?
    private var observers: [NSObjectProtocol] = []
    private var isFitting = false

    /// 一覧と、その伸び縮みする列を受け持つ。一覧は `NSScrollView` に入れてから渡すこと。
    func attach(to table: NSTableView, flexibleColumn identifier: NSUserInterfaceItemIdentifier) {
        detach()
        self.table = table
        flexibleColumn = identifier
        guard let clip = table.enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification, object: table, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, !self.isFitting,
                      let resized = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                      resized.identifier != self.flexibleColumn
                else { return }
                self.fit()
            }
        })
        // 保存された幅が戻り、一覧が並べ終わってから合わせる。
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    /// 購読を外す(`dismantleNSView` から。閉包が一覧を持ち続けないように ―― CLAUDE.md のリークの決まり)。
    func detach() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        table = nil
        flexibleColumn = nil
    }

    /// 伸び縮みする列を、見えている幅に合わせる(列を出し入れしたときは呼び出し側から呼ぶ)。
    func fit() {
        guard !isFitting, let table, let flexibleColumn,
              let flexible = table.tableColumn(withIdentifier: flexibleColumn),
              let clip = table.enclosingScrollView?.contentView
        else { return }
        let visible = table.tableColumns.filter { !$0.isHidden }
        let others = visible.filter { $0 !== flexible }.reduce(CGFloat(0)) { $0 + $1.width }
        let spacing = table.intercellSpacing.width * CGFloat(visible.count)
        let target = max(flexible.minWidth, (clip.bounds.width - others - spacing).rounded(.down))
        guard abs(flexible.width - target) > 0.5 else { return }
        isFitting = true
        flexible.width = target
        isFitting = false
    }
}
