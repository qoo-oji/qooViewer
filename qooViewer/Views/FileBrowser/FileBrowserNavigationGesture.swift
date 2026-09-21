import AppKit

/// ファイルブラウザの「戻る」「進む」を、トラックパッドの左右フリックとマウスのサイドボタンから引く決まり
/// (ユーザー要望 2026-09-21)。イベントを受ける側は FileBrowserNavigationGestureMonitor.swift。
/// ここは画面に依らない判定だけ(テストできるように分けてある)。
///
/// ■ 向き
/// どちらもブラウザ(Safari・Chromium)と同じ: **中身が右へ動く向き = 戻る**。
/// - 2本指(`.scrollWheel` の並び): 積算した `scrollingDeltaX` が正 → 戻る、負 → 進む。`scrollingDeltaX` には
///   システムの「ナチュラルなスクロール」がすでに織り込まれているので、ここでは反転しない
/// - 3本指/4本指(`.swipe`): `deltaX` が正 → 戻る、負 → 進む(Chromium の `swipeWithEvent:` と同じ)
/// - マウス: ボタン 3 → 戻る、ボタン 4 → 進む(ドライバ無しのマウスが送ってくる番号。ブラウザ各種と同じ)
enum FileBrowserNavigationGesture {
    /// マウスのサイドボタン(`NSEvent.buttonNumber`)。
    static func command(forMouseButton buttonNumber: Int) -> FileBrowserEditCommand? {
        switch buttonNumber {
        case 3: return .goBack
        case 4: return .goForward
        default: return nil
        }
    }

    /// 3本指/4本指の `.swipe`。
    static func command(forSwipeDeltaX deltaX: CGFloat) -> FileBrowserEditCommand? {
        if deltaX > 0 { return .goBack }
        if deltaX < 0 { return .goForward }
        return nil
    }
}

/// 2本指の左右フリックの 1 回ぶん。「ページ間をスワイプ」が 2 本指のとき、その操作は `.swipe` ではなく `.scrollWheel` の
/// 並びとして届く(ViewerView.makeScrollMonitor の調査のコメント)。指が触れてから離れるまでを積算し、**離れたときに 1 回だけ**
/// 判定する(1 個ずつのイベントに反応すると、1 回のフリックで何階層も戻る)。
///
/// ■ 横にスクロールできる一覧の上では、端にいるときだけ
/// リスト表示は列が収まらないと横にスクロールする。そこでの左右の 2 本指は「一覧を横へ動かしたい」なので、フリックを始めた時点で
/// その向きにまだスクロールできるなら移動しない(Safari など、AppKit のスワイプ追跡と同じ約束)。
struct FileBrowserSwipeTracker {
    /// これより小さい動き(触れただけ)には反応しない。
    static let minimumDistance: CGFloat = 20
    /// 横の動きが縦の何倍あれば「左右のフリック」とみなすか。ページ送りと違い、誤って移動すると一覧ごと変わるので、
    /// ビューア(横 > 縦)より厳しくしてある ―― 縦スクロールの途中の斜めのぶれでは移動しない。
    static let horizontalDominance: CGFloat = 2

    private var isTracking = false
    private var deltaX: CGFloat = 0
    private var deltaY: CGFloat = 0
    private var canScrollTowardLeft = false
    private var canScrollTowardRight = false

    /// 1 個の `.scrollWheel` を渡す。フリックが終わって移動すると決まったときだけ操作を返す。
    /// - Parameters:
    ///   - phase: `NSEvent.phase`(慣性のぶんは空で届くので、積算に入らない)。
    ///   - horizontalRoom: ポインタの下の一覧が、いま左・右へまだスクロールできるか。**`.began` のときだけ読む**。
    mutating func feed(
        phase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat,
        horizontalRoom: () -> (towardLeft: Bool, towardRight: Bool)
    ) -> FileBrowserEditCommand? {
        if phase.contains(.began) {
            let room = horizontalRoom()
            isTracking = true
            self.deltaX = 0
            self.deltaY = 0
            canScrollTowardLeft = room.towardLeft
            canScrollTowardRight = room.towardRight
        }
        // `.began` を見ていない並び(ほかのウインドウの上で始まった、など)は数えない。
        guard isTracking, !phase.isEmpty else { return nil }
        if phase.contains(.cancelled) {
            isTracking = false
            return nil
        }
        self.deltaX += deltaX
        self.deltaY += deltaY
        guard phase.contains(.ended) else { return nil }
        isTracking = false

        guard abs(self.deltaX) >= Self.minimumDistance,
              abs(self.deltaX) > abs(self.deltaY) * Self.horizontalDominance else { return nil }
        // 中身が右へ動く向き(正)は、一覧にとっては左へのスクロール。
        if self.deltaX > 0 {
            return canScrollTowardLeft ? nil : .goBack
        }
        return canScrollTowardRight ? nil : .goForward
    }
}
