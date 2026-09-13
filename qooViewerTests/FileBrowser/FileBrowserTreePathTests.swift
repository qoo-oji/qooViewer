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
