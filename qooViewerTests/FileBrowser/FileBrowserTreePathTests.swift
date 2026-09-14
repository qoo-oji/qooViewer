import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// ツリーを「現在のフォルダまで開く」道筋(FileBrowserTreePath)。根はツリーに並ぶ順(ボリューム・ホーム・よく使う項目)。
struct FileBrowserTreePathTests {
    private let roots = ["/", "/Volumes/XOther", "/Users/nobody", "/Users/nobody/XFavorite", "/Volumes/XOther/XShelf"]

    @Test("現在のフォルダを含む根のうち、いちばん深いものから道筋を作る")
    func startsFromTheDeepestRoot() {
        #expect(
            FileBrowserTreePath.plan(to: "/Users/nobody/XFavorite/XA/XB", roots: roots)
                == .init(rootIndex: 3, steps: ["/Users/nobody/XFavorite/XA", "/Users/nobody/XFavorite/XA/XB"])
        )
        #expect(
            FileBrowserTreePath.plan(to: "/Users/nobody/XOuter", roots: roots)
                == .init(rootIndex: 2, steps: ["/Users/nobody/XOuter"])
        )
        #expect(
            FileBrowserTreePath.plan(to: "/Volumes/XOther/XShelf/XA", roots: roots)
                == .init(rootIndex: 4, steps: ["/Volumes/XOther/XShelf/XA"])
        )
    }

    @Test("起動ボリュームの根からは / の直下を 1 段目にする")
    func startsFromTheStartupVolume() {
        #expect(
            FileBrowserTreePath.plan(to: "/Applications/XTools", roots: roots)
                == .init(rootIndex: 0, steps: ["/Applications", "/Applications/XTools"])
        )
    }

    @Test("根そのものなら道筋は空、末尾の / は無視する")
    func targetIsARoot() {
        #expect(FileBrowserTreePath.plan(to: "/Users/nobody/", roots: roots) == .init(rootIndex: 2, steps: []))
        #expect(FileBrowserTreePath.plan(to: "/", roots: roots) == .init(rootIndex: 0, steps: []))
    }

    @Test("名前の途中までしか一致しない根は含めない")
    func prefixOfANameIsNotAnAncestor() {
        #expect(
            FileBrowserTreePath.plan(to: "/Volumes/XOtherDisk/XA", roots: roots)
                == .init(rootIndex: 0, steps: ["/Volumes", "/Volumes/XOtherDisk", "/Volumes/XOtherDisk/XA"])
        )
        #expect(FileBrowserTreePath.plan(to: "/Volumes/XOtherDisk", roots: ["/Volumes/XOther"]) == nil)
    }

    @Test("同じ深さの根が 2 つあれば、先に並ぶほうを開く")
    func tieGoesToTheEarlierRoot() {
        let roots = ["/Users/nobody", "/Users/nobody"]
        #expect(FileBrowserTreePath.plan(to: "/Users/nobody/XA", roots: roots)?.rootIndex == 0)
    }

    @Test("道筋の 1 段は完全一致を優先し、無ければ大小文字の違いを無視して探す")
    func matchingAStep() {
        let children = ["/Users/nobody/xa", "/Users/nobody/XA/", "/Users/nobody/XB"]
        #expect(FileBrowserTreePath.index(of: "/Users/nobody/XA", in: children) == 1)
        #expect(FileBrowserTreePath.index(of: "/Users/nobody/xb", in: children) == 2)
        #expect(FileBrowserTreePath.index(of: "/Users/nobody/XC", in: children) == nil)
    }
}

/// ツリーが FSEvents のパスを行のパスへ揃える、アイコン表示の名前のクリックの範囲(2026-09-14)。
@MainActor
struct FileBrowserTreeAndIconHitTests {
    @Test("FSEvents が付ける起動ボリュームのデータ領域の頭を外す。ほかのパスはそのまま")
    func dataVolumePrefixIsStripped() {
        // ツリーと表示中のフォルダの見張りで共有する(2026-09-14 に FileBrowserState へ移した)。
        typealias Paths = FileBrowserState
        // 頭は定数から組む(`/Volumes/<名前>/<名前>` の形を書くと禁止語の検査が合成名でも止める)。
        let prefix = Paths.dataVolumePrefix
        #expect(Paths.pathOutsideDataVolume(prefix + "/Users/nobody/XA") == "/Users/nobody/XA")
        #expect(Paths.pathOutsideDataVolume("/Volumes/XOther/XA") == "/Volumes/XOther/XA")
        #expect(Paths.pathOutsideDataVolume(prefix + "X/XA") == prefix + "X/XA")
    }

    @Test("名前のクリックは文字の上だけ。短い名前の横の余白は含まない")
    func nameHitAreaFollowsTheText() {
        let cellWidth: CGFloat = 120
        let rect = FileBrowserIconView.nameRect(of: "a", cellWidth: cellWidth, top: 100)
        #expect(rect.contains(CGPoint(x: cellWidth / 2, y: 105)))
        #expect(!rect.contains(CGPoint(x: 4, y: 105)), "名前の横の余白で編集が始まる")
        #expect(!rect.contains(CGPoint(x: cellWidth / 2, y: 90)), "アイコンの上で編集が始まる")
        let long = FileBrowserIconView.nameRect(of: String(repeating: "long name ", count: 20), cellWidth: cellWidth, top: 100)
        #expect(long.width >= cellWidth * 0.8, "折り返す長い名前はセルの幅いっぱいに近い")
        #expect(long.height < 50, "2 行を超えて伸びた")
    }

    /// AppKit の `hitTest` が判定を飛ばして名前の欄を返す状態(アイコン表示のサブメニューのあと。FileBrowserTableView.hitTest の
    /// コメント)はテストでは作れないので、欄が当たったことにして確かめ直しの判定だけを見る。
    @Test("リストは、編集を始めてはいけない名前の欄が当たっても表を返す。ほかの部品はそのまま")
    func listResolvesRefusedNameFieldToTable() {
        let table = FileBrowserTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let field = FileBrowserNameField(frame: NSRect(x: 10, y: 10, width: 100, height: 20))
        field.editingName = "a.txt"
        table.addSubview(field)
        // 行を選んでいない(1 行だけを選んでいるときしか編集を始めない)→ 表。
        #expect(table.resolvedHit(field, event: nil) === table)
        let icon = NSImageView(frame: .zero)
        #expect(table.resolvedHit(icon, event: nil) === icon)
        #expect(table.resolvedHit(nil, event: nil) == nil)
    }

    @Test("ツリーは行の文字の欄が当たっても一覧を返す(行の選択と右クリックのメニューは一覧が受ける)。ほかの部品はそのまま")
    func treeResolvesRowLabelsToOutline() {
        let outline = FileBrowserOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let label = NSTextField(labelWithString: "Notes")
        let button = NSButton(frame: .zero)
        #expect(outline.resolvedHit(label) === outline)
        #expect(outline.resolvedHit(button) === button)
    }
}
