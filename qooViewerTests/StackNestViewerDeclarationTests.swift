import Foundation
import StackNestViewerKit
import Testing

@testable import qooViewer

/// StackNest への対応の宣言。
///
/// StackNest は外部ビューアの `Contents/Info.plist` を**ファイルとして**読んで、渡してよいかを決める(`Bundle` の
/// キャッシュや LaunchServices の登録に頼らない)。ここでも、ビルドされたアプリ(テストホスト = Debug ビルド)の Info.plist を
/// ファイルとして読む。リポジトリの `qooViewer/Info.plist` はビルド設定から生成される鍵と合わさって出来上がるので、ソースを
/// 見ても足りない。
struct StackNestViewerDeclarationTests {
    private static let referenceType = "app.shelfsmith.stacknest.book-reference"

    private static func builtInfoPlist() throws -> [String: Any] {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(object as? [String: Any])
    }

    @Test("宣言の自己点検: StackNestViewerKit が読めない版を宣言していない(部品の verify が空)")
    func declarationPassesTheKitSelfCheck() throws {
        #expect(StackNestViewerSupport.verify(infoDictionary: try Self.builtInfoPlist()).isEmpty)
    }

    @Test("StackNestViewerKit は 0.1 系をつないでいる(版の定数がアプリから見える)")
    func linksTheKit() {
        #expect(StackNestViewerKitInfo.version.hasPrefix("0.1."))
    }

    @Test("StackNestViewerSupport が、読める版として 1 を宣言している")
    func declaresReferenceFormatVersionOne() throws {
        let plist = try Self.builtInfoPlist()
        let support = try #require(plist["StackNestViewerSupport"] as? [String: Any])
        #expect(support["referenceFormatVersions"] as? [Int] == [1])
    }

    @Test("参照ファイルの型を取り込み宣言している(public.json に準拠・拡張子 stacknestbook)")
    func importsTheReferenceType() throws {
        let plist = try Self.builtInfoPlist()
        let imported = try #require(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try #require(imported.first { $0["UTTypeIdentifier"] as? String == Self.referenceType })
        #expect((declaration["UTTypeConformsTo"] as? [String])?.contains("public.json") == true)
        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == ["stacknestbook"])
    }

    @Test("書類の型: 専用の項目で、LSItemContentTypes だけを持ち、順位は Alternate")
    func acceptsTheReferenceAsADocument() throws {
        let plist = try Self.builtInfoPlist()
        let types = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let entry = try #require(types.first {
            ($0["LSItemContentTypes"] as? [String])?.contains(Self.referenceType) == true
        })
        // 拡張子と UTType を同じ項目に混ぜると UTType の側だけが効く(Info.plist の既存の注記)。
        #expect(entry["CFBundleTypeExtensions"] == nil)
        // StackNest は `open -a` で名指しして渡すので、Finder のダブルクリックの既定にはならない。
        #expect(entry["LSHandlerRank"] as? String == "Alternate")
        #expect(entry["CFBundleTypeRole"] as? String == "Viewer")
        // 既存の書庫の項目は、参照ファイルを含まないまま(check-extensions.sh が見る一覧)。
        let archives = try #require(types.first { $0["CFBundleTypeName"] as? String == "Comic Archive" })
        #expect((archives["CFBundleTypeExtensions"] as? [String])?.contains("stacknestbook") == false)
    }

    @Test("ATS: ローカルの通信だけ平文の HTTP を許す(何でも許す NSAllowsArbitraryLoads は使わない)")
    func allowsOnlyLocalNetworking() throws {
        let plist = try Self.builtInfoPlist()
        let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(ats["NSAllowsArbitraryLoads"] == nil)
        #expect(ats["NSAllowsArbitraryLoadsInWebContent"] == nil)
        #expect(ats["NSAllowsArbitraryLoadsForMedia"] == nil)
    }
}
