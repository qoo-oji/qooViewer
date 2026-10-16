import Foundation
import Testing

@testable import qooViewer

/// ATS(App Transport Security)が StackNest の宛先への平文の HTTP を止めないこと。
///
/// テストはアプリに載せて走る(TEST_HOST)ので、アプリの Info.plist の ATS がそのまま効く。ATS に止められた要求は
/// `NSURLErrorAppTransportSecurityRequiresSecureConnection`(-1022)で失敗し、止められなかった要求は繋がらない(-1004)・
/// 時間切れ(-1001)などで失敗する。**見るのはその番号だけ**で、宛先が実際に応えるかは問わない。
///
/// どれも実際に接続を試す(繋がらないか時間切れになる。機器があれば拒否が返る)ので、`TEST_RUNNER_QOO_ATS_PROBE_URL` を付けて
/// xcodebuild を呼んだときだけ動く。ふだんのテスト(と CI)では skipped で、全体のテストを伸ばさない。
struct StackNestATSTests {
    private static let atsBlocked = URLError.Code.appTransportSecurityRequiresSecureConnection.rawValue
    /// 手で走らせるときの宛先。nil ならこのスイートのテストは走らない。
    /// nonisolated: 有効にするかの判定(`.enabled(if:)`)は Swift Testing がメインアクターの外で評価する(ZipEntryNameTests.paths と同じ)。
    nonisolated static let probeURL = ProcessInfo.processInfo.environment["QOO_ATS_PROBE_URL"].flatMap(URL.init(string:))

    /// `url` を GET したときの `URLError` の番号。応答が返れば nil。
    static func errorCode(fetching url: URL, timeout: TimeInterval) async -> Int? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: url)
            return nil
        } catch let error as URLError {
            return error.code.rawValue
        } catch {
            return -1
        }
    }

    @Test(
        "この Mac(127.0.0.1)と私設の IP アドレスへの平文の HTTP は ATS に止められない(手動)",
        .enabled(if: StackNestATSTests.probeURL != nil),
        arguments: ["http://127.0.0.1:1/", "http://192.168.0.1:9/", "http://10.0.0.1:9/", "http://172.16.0.1:9/"]
    )
    func plainHTTPToPrivateAddressesIsAllowed(address: String) async throws {
        let url = try #require(URL(string: address))
        let code = await Self.errorCode(fetching: url, timeout: 2)
        #expect(code != Self.atsBlocked)
    }

    /// 止められる側(docs/10 の記録): Tailscale の範囲(100.64/10)と公開の IP アドレス(文書用の 192.0.2.1)。
    /// OS の方針が変わったときに気づくためのもの。
    @Test(
        "Tailscale の範囲と公開の IP アドレスへの平文の HTTP は ATS に止められる(手動)",
        .enabled(if: StackNestATSTests.probeURL != nil),
        arguments: ["http://100.64.0.1:9/", "http://192.0.2.1:9/"]
    )
    func plainHTTPToTailscaleAndPublicAddressesIsBlocked(address: String) async throws {
        let url = try #require(URL(string: address))
        let code = await Self.errorCode(fetching: url, timeout: 2)
        #expect(code == Self.atsBlocked)
    }

    /// 手で走らせる確認。`TEST_RUNNER_QOO_ATS_PROBE_URL` を付けて xcodebuild を呼んだときだけ動く。
    /// 宛先の名前は tailnet の名前を含む(個人の識別子)ので、リポジトリにもログの写しにも残さない。結果は番号だけを見る。
    @Test("ATS の実地確認(手動): 指定した宛先への平文の HTTP", .enabled(if: StackNestATSTests.probeURL != nil))
    func probeConfiguredAddress() async throws {
        let target = try #require(Self.probeURL)
        // 対照: 公開のドメインへの平文の HTTP は必ず止められる。止められなければ、この実行では ATS が効いていない(判定できない)。
        let control = await Self.errorCode(fetching: try #require(URL(string: "http://example.com/")), timeout: 5)
        #expect(control == Self.atsBlocked, "対照が -1022 にならない: この実行では ATS の判定ができない(control=\(String(describing: control)))")
        let probed = await Self.errorCode(fetching: target, timeout: 5)
        #expect(probed != Self.atsBlocked, "指定した宛先への平文の HTTP が ATS に止められた")
    }
}
