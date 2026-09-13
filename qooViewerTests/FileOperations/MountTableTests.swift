import Foundation
import Testing

@testable import qooViewer

/// マウント表の読み取り(Services/FileOperations/MountTable.swift)。
///
/// 見るのは「最長一致」と「外れたボリュームの判定」の 2 つの罠 ―― どちらも素直に書くと、
/// 知りたい場面でだけ逆を答える(`/` は常に接頭辞なので、何もかもが起動ボリュームに見える)。
struct MountTableTests {
    @Test("起動ボリュームのパスは / に載っている")
    func bootVolumePathsResolveToRoot() {
        let table = MountTable.current()
        #expect(table.entry(containing: "/Users")?.mountPoint == "/")
        #expect(table.isMounted("/"))
    }

    @Test("使い捨てボリュームの中は、そのボリュームに載っている(まだ無いパスも / へ後退しない)")
    func disposableVolumeWinsTheLongestMatch() throws {
        guard let volume = DisposableVolume.make(.apfs, "mount-table") else { return }
        let table = MountTable.current()
        let entry = try #require(table.entry(containing: volume.file("not/yet/created.txt")))
        #expect(entry.mountPoint == volume.mountPoint.path)
        #expect(entry.isLocal)
        #expect(entry.fileSystemType == "apfs")
        #expect(!table.areOnSameVolume(volume.file("a"), URL(fileURLWithPath: "/Users")))
        #expect(table.areOnSameVolume(volume.file("a"), volume.file("b/c")))
        #expect(!table.isOnAnUnmountedVolume(volume.file("a")))
        #expect(table.volumeIdentifier(volume.mountPoint) != nil)
    }

    @Test("表に居ない /Volumes/<名前> の下は「外れたボリューム」")
    func absentVolumeIsReportedAsUnmounted() {
        let table = MountTable.current()
        let absent = URL(fileURLWithPath: "/Volumes/qooTest-absent-\(UUID().uuidString)/book.cbz")
        // 最長一致は / まで後退する ―― だからこちらでは判定しない、を固定する。
        #expect(table.entry(containing: absent)?.mountPoint == "/")
        #expect(table.isOnAnUnmountedVolume(absent))
        #expect(!table.isOnAnUnmountedVolume(URL(fileURLWithPath: "/Users/someone/book.cbz")))
    }

    @Test("接頭辞が同じだけの別の場所は配下とみなさない")
    func prefixSharingSiblingIsNotUnderAncestor() {
        #expect(MountTable.path("/Volumes/XY/x", isAtOrUnder: "/Volumes/XY"))
        #expect(!MountTable.path("/Volumes/XYZ/x", isAtOrUnder: "/Volumes/XY"))
        #expect(MountTable.path("/Volumes/XY", isAtOrUnder: "/Volumes/XY"))
        #expect(MountTable.normalized("/Volumes/XY///") == "/Volumes/XY")
        #expect(MountTable.normalized("/") == "/")
        #expect(MountTable.volumeRoot(of: "/Volumes/XY/c/d") == "/Volumes/XY")
        #expect(MountTable.volumeRoot(of: "/Users/x") == nil)
    }
}
