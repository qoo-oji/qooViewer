import SwiftUI
import AppKit
import Combine

/// サイドパネルの行を右クリックしたとき、その行を枠で囲んで「どれに対するメニューか」を
/// 示すための状態(ユーザー要望: Finderのリスト表示で右クリックしたときと同じ見え方にしたい)。
///
/// ■ なぜホバーとメニューの追跡を組み合わせるのか
/// SwiftUIの`.contextMenu`は、**開いた/閉じたを知らせてくれない**。`menuItems`のクロージャは
/// ビューの本体評価の一部として呼ばれるため、そこで`@State`を書き換えるのは
/// 「body評価中の状態変更」になり許されない。右クリックを自前のNSViewで受けてしまうと、
/// 今度はヒットテストの持ち主が変わって`.contextMenu`自体が出なくなる。
///
/// そこで、次の2つの既に分かる事実を突き合わせる。
///   1. どの行の上にカーソルがあるか(`.onHover`)
///   2. いつメニューが開き、いつ閉じたか(`NSMenu.didBeginTracking` / `didEndTracking`)
/// メニューが開いた瞬間にカーソルが乗っていた行こそ、右クリックされた行である。
///
/// メニューバーのメニューを開いた場合も`didBeginTracking`は飛ぶが、そのときカーソルは
/// サイドパネルの行から外れている(=`hoveredRowID`がnil)ので、何も強調されない。
///
/// ■ ホバーの記録は`@Published`にしない
/// カーソルが行をまたぐたびに再描画を起こしたくないため。実際に画面を変える必要があるのは
/// 「メニューが開いた/閉じた」瞬間だけなので、`@Published`はそちらだけに付けてある。
@MainActor
final class SidePanelContextMenuHighlight: ObservableObject {
    /// 右クリックで開いたメニューの対象になっている行のID。メニューが閉じるとnilへ戻る。
    @Published private(set) var highlightedRowID: String?

    /// いまカーソルが乗っている行のID(上記の理由で@Publishedにはしない)。
    private var hoveredRowID: String?
    private let observers = NotificationObserverTokens()

    init() {
        observers.add(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // queue: .mainで登録しているため実行時には必ずMainActor上にいる
            // (プロジェクト内の同種の箇所と同じ対処)。
            MainActor.assumeIsolated {
                guard let self, let hovered = self.hoveredRowID else { return }
                // メニューバーのメニューは対象外。カーソルを動かして開いた場合は行から
                // 外れているので`hoveredRowID`がnilになるが、キーボードショートカットで
                // 開いた場合はカーソルが行の上に残ったままなので、それだけでは足りない。
                guard let menu = notification.object as? NSMenu,
                      !Self.isMainMenuDescendant(menu)
                else { return }
                self.highlightedRowID = hovered
            }
        })
        observers.add(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.highlightedRowID != nil else { return }
                // didEndTrackingはメインスレッドから同期配送されるため、このクロージャは
                // AppKitがまだメニューのトラッキングを巻き戻している最中に走る。その最中に
                // SwiftUI側を触ると、macOS 26でメニューの再構築が走って落ちることがある
                // (ViewerViewのページ一覧の後始末に同じ対処と、その経緯が書いてある)。
                // 1回ランループを跨いでから消す。
                DispatchQueue.main.async {
                    self.highlightedRowID = nil
                }
            }
        })
    }

    deinit {
        // NotificationCenterはクロージャを強参照し続けるため、解除しないとそのままリークになる
        // (RecentFilesStore.deinitと同じ理由)。
        //
        // nonisolated deinitからは@MainActorのメソッドを直接呼べないが、この時点で
        // このオブジェクトを参照しているものはもう無く、トークンの配列を触るのはここだけなので、
        // MainActor.assumeIsolatedで囲って解除する。
        MainActor.assumeIsolated {
            observers.removeAll()
        }
    }

    /// そのメニューがメニューバー(NSApp.mainMenu)の一部かどうか。
    /// コンテキストメニューは`supermenu`をたどってもメインメニューには行き着かない。
    private static func isMainMenuDescendant(_ menu: NSMenu) -> Bool {
        var current: NSMenu? = menu
        while let candidate = current {
            if candidate === NSApp.mainMenu { return true }
            current = candidate.supermenu
        }
        return false
    }

    /// 行の`.onHover`から呼ぶ。離れたときは、その行が今記録されている場合にだけ消す
    /// (行から行へ移るとき、新しい行のenterが先に届くことがあるため。順序に関わらず
    /// 「最後に入った行」が残るようにしている)。
    func updateHover(rowID: String, isHovering: Bool) {
        if isHovering {
            hoveredRowID = rowID
        } else if hoveredRowID == rowID {
            hoveredRowID = nil
        }
    }
}

/// サイドパネルの1行に、右クリック時の枠を付ける。
///
/// 枠は**常に置いたまま色だけを変える**。条件でオーバーレイ自体を出し入れすると
/// ビューの構造が変わり、メニューの表示中にそれをやるとmacOS 26で落ちる経路に触れうる
/// (ThumbnailCellの「表示中のページ」の枠と同じ書き方)。
private struct SidePanelContextHighlightModifier: ViewModifier {
    let rowID: String
    @EnvironmentObject private var highlight: SidePanelContextMenuHighlight

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                highlight.updateHover(rowID: rowID, isHovering: isHovering)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        highlight.highlightedRowID == rowID ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
            )
    }
}

extension View {
    /// - Parameter rowID: サイドパネル内で一意な行の識別子。上段のフォルダと下段の画像で
    ///   同じパスが現れることがあるため、呼び出し側が区画ごとの接頭辞を付けて渡す。
    func sidePanelContextHighlight(rowID: String) -> some View {
        modifier(SidePanelContextHighlightModifier(rowID: rowID))
    }
}
