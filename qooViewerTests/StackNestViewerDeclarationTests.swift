import Foundation
import Security
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

    @Test("アプリ本体は ATS の例外を持たない(通信しない)。StackNestConnector.xpc の ATS はローカルの平文の HTTP だけ")
    func atsLivesOnlyInTheConnector() throws {
        let plist = try Self.builtInfoPlist()
        #expect(plist["NSAppTransportSecurity"] == nil)
        let serviceName = try #require(plist[StackNestConnectorClient.serviceNameInfoKey] as? String)
        #expect(serviceName == "\(try #require(Bundle.main.bundleIdentifier)).StackNestConnector")
        let connector = Bundle.main.bundleURL.appending(path: "Contents/XPCServices/StackNestConnector.xpc")
        let connectorPlist = try #require(NSDictionary(contentsOf: connector.appending(path: "Contents/Info.plist")) as? [String: Any])
        #expect(connectorPlist["CFBundleIdentifier"] as? String == serviceName)
        let ats = try #require(connectorPlist["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats.keys.sorted() == ["NSAllowsLocalNetworking"])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
    }

    @Test("アプリ本体はサンドボックスのまま、通信の entitlement を持たない(外への接続を持つのは StackNestConnector.xpc だけ)")
    func appHasNoNetworkEntitlement() throws {
        let task = try #require(SecTaskCreateFromSelf(nil))
        func value(_ key: String) -> Bool? {
            SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool
        }
        // CI はテストを署名せずに(CODE_SIGNING_ALLOWED=NO)走らせるので、entitlement がひとつも入らず、サンドボックスも無い
        // (2026-10-19、PR #1 で CI を初めて走らせて分かった)。そのときは「通信の entitlement を持たない」だけを見る。署名した
        // 配布物の entitlement は scripts/release/check-release-app.sh が確かめる。
        if Self.embeddedEntitlements()?.isEmpty == false {
            #expect(value("com.apple.security.app-sandbox") == true)
        }
        #expect(value("com.apple.security.network.client") != true)
        #expect(value("com.apple.security.network.server") != true)
    }

    /// 動いているアプリ(テストホスト)の署名に入っている entitlement。署名に無ければ nil。
    private static func embeddedEntitlements() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSRequirementInformation), &information)
                == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    }
}
