import Foundation
import Testing

@testable import qooViewer

/// 自動アップデート(Sparkle)を起動してよいかの判定(Services/AppUpdater.swift の `UpdaterConfiguration`)と、
/// 出荷する Info.plist がその約束を満たしていること。
///
/// 約束の中身は Info.plist のコメントにある。ここが落ちたら、署名の確かめ・プライバシーに関わる設定を誰かが
/// 緩めたということ ―― 直すのはテストではなく設定のほう。配布前の .app は scripts/ci/check-release-app.sh が
/// 同じ約束を確かめる(Release の値 ―― 公開鍵・QOOUpdaterEnabled = YES ―― はそちらでしか見えない)。
struct UpdaterConfigurationTests {
    /// 32 バイトの適当な値(公開鍵の形だけ合っていればよい)。
    private static let sampleKey = Data(repeating: 7, count: 32).base64EncodedString()

    /// 約束をすべて満たす Info.plist(Release + 鍵を入れた後の形)。
    private static func validInfo() -> [String: Any] {
        [
            "QOOUpdaterEnabled": "YES",
            "SUFeedURL": "https://github.com/qoo-oji/qooViewer/releases/latest/download/appcast.xml",
            "SUPublicEDKey": sampleKey,
            "SUVerifyUpdateBeforeExtraction": true,
            "SURequireSignedFeed": true,
            "SUSignedFeedFailureExpirationInterval": 0,
            "SUEnableInstallerLauncherService": true,
            "SUEnableDownloaderService": true,
            "SUEnableSystemProfiling": false,
            "SUEnableJavaScript": false,
        ]
    }

    private static func validate(_ info: [String: Any]) -> Result<UpdaterConfiguration, UpdaterConfiguration.Refusal> {
        UpdaterConfiguration.validate(infoDictionary: info, isRunningTests: false)
    }

    private static func refusal(_ info: [String: Any]) -> UpdaterConfiguration.Refusal? {
        if case .failure(let refusal) = validate(info) { return refusal }
        return nil
    }

    @Test("約束をすべて満たせば起動してよく、配信元は Info.plist の URL")
    func aCompleteConfigurationIsAccepted() throws {
        let configuration = try Self.validate(Self.validInfo()).get()
        #expect(configuration.feedURL.absoluteString == "https://github.com/qoo-oji/qooViewer/releases/latest/download/appcast.xml")
        #expect(configuration.publicEDKey == Self.sampleKey)
    }

    @Test("テストの中・Debug(QOOUpdaterEnabled が YES でない)では起動しない")
    func testsAndDebugBuildsNeverStart() {
        #expect(UpdaterConfiguration.validate(infoDictionary: Self.validInfo(), isRunningTests: true) == .failure(.runningTests))
        for value: Any? in ["NO", "", false, nil, "maybe"] {
            var info = Self.validInfo()
            info["QOOUpdaterEnabled"] = value
            #expect(Self.refusal(info) == .disabledInThisBuild)
        }
        // 意図した止め方はログに残さない(配布物の誤りではない)。
        #expect(!UpdaterConfiguration.Refusal.disabledInThisBuild.isConfigurationError)
        #expect(!UpdaterConfiguration.Refusal.runningTests.isConfigurationError)
        #expect(UpdaterConfiguration.Refusal.missingPublicKey.isConfigurationError)
    }

    @Test(
        "配信元は利用者名やパスワードを含まない HTTPS の URL だけ",
        arguments: [
            "http://github.com/qoo-oji/qooViewer/releases/latest/download/appcast.xml",
            "file:///tmp/appcast.xml",
            "ftp://example.com/appcast.xml",
            "https:///appcast.xml",
            "https://user:secret@example.com/appcast.xml",
            "appcast.xml",
        ]
    )
    func onlyPlainHTTPSFeedsAreAccepted(feed: String) {
        var info = Self.validInfo()
        info["SUFeedURL"] = feed
        #expect(Self.refusal(info) == .insecureFeedURL(feed))
    }

    @Test("配信元が無ければ起動しない")
    func aMissingFeedIsRefused() {
        var info = Self.validInfo()
        info["SUFeedURL"] = nil
        #expect(Self.refusal(info) == .missingFeedURL)
        info["SUFeedURL"] = "  "
        #expect(Self.refusal(info) == .missingFeedURL)
    }

    @Test("公開鍵が空・base64 でない・32 バイトでなければ起動しない")
    func thePublicKeyMustBeAnEd25519Key() {
        var info = Self.validInfo()
        info["SUPublicEDKey"] = ""
        #expect(Self.refusal(info) == .missingPublicKey)
        info["SUPublicEDKey"] = nil
        #expect(Self.refusal(info) == .missingPublicKey)
        info["SUPublicEDKey"] = "not base64!"
        #expect(Self.refusal(info) == .malformedPublicKey)
        info["SUPublicEDKey"] = Data(repeating: 1, count: 31).base64EncodedString()
        #expect(Self.refusal(info) == .malformedPublicKey)
        info["SUPublicEDKey"] = Data(repeating: 1, count: 64).base64EncodedString()
        #expect(Self.refusal(info) == .malformedPublicKey)
    }

    @Test(
        "署名の確かめとサンドボックスに要る設定は、無くても NO でも起動しない",
        arguments: ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed",
                    "SUEnableInstallerLauncherService", "SUEnableDownloaderService"]
    )
    func requiredSettingsMustBeOn(key: String) {
        var info = Self.validInfo()
        info[key] = false
        #expect(Self.refusal(info) == .insecureSetting(key))
        info[key] = nil
        #expect(Self.refusal(info) == .insecureSetting(key))
    }

    @Test(
        "Mac の情報を送る・リリースノートでスクリプトを動かす設定が ON なら起動しない",
        arguments: ["SUEnableSystemProfiling", "SUEnableJavaScript"]
    )
    func forbiddenSettingsMustBeOff(key: String) {
        var info = Self.validInfo()
        info[key] = true
        #expect(Self.refusal(info) == .insecureSetting(key))
        info[key] = "YES"
        #expect(Self.refusal(info) == .insecureSetting(key))
        // 無い = Sparkle の既定の NO なのでよい。
        info[key] = nil
        #expect(Self.refusal(info) == nil)
    }

    @Test("署名の合わない appcast を期限切れで受け入れる逃げ道は 0(閉じている)でなければ起動しない")
    func theSignedFeedFallbackMustBeClosed() {
        var info = Self.validInfo()
        info["SUSignedFeedFailureExpirationInterval"] = nil  // 無ければ Sparkle の既定の 20 日になる
        #expect(Self.refusal(info) == .insecureSetting("SUSignedFeedFailureExpirationInterval"))
        info["SUSignedFeedFailureExpirationInterval"] = 1_728_000
        #expect(Self.refusal(info) == .insecureSetting("SUSignedFeedFailureExpirationInterval"))
    }

    // MARK: - 出荷する Info.plist

    /// テストホストは Debug ビルドの実物のアプリなので、`Bundle.main` の Info.plist は出荷するものと同じ
    /// ファイルから作られている(違うのはビルド設定から入る値だけ)。
    @Test("出荷する Info.plist は、鍵と Release の切り替え以外の約束をすべて満たしている")
    func theShippedInfoPlistKeepsThePromises() throws {
        var info = try #require(Bundle.main.infoDictionary)
        // Debug ではアップデーターを起動しない(Release だけ YES。check-release-app.sh が見る)。
        #expect(info["QOOUpdaterEnabled"] as? String == "NO")
        // 鍵と切り替えだけ差し替えれば通る = それ以外の値はすべて約束どおり。
        info["QOOUpdaterEnabled"] = "YES"
        if (info["SUPublicEDKey"] as? String ?? "").isEmpty {
            info["SUPublicEDKey"] = Self.sampleKey
        }
        let configuration = try Self.validate(info).get()
        #expect(configuration.feedURL.host() == "github.com")
        // 期限切れの逃げ道の値は「無い」ではなく 0 が書いてあること(上の validate が見ているが、意図を明記)。
        #expect((Bundle.main.infoDictionary?["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.intValue == 0)
    }

    @Test("「自動でダウンロードしてインストール」は自動確認の ON/OFF に依らせない(SUAllowsAutomaticUpdates = YES)")
    func automaticInstallsDoNotDependOnTheLaunchTimeCheckSetting() throws {
        // 2026-10-10 の監査の 2: 無いと Sparkle 2.10 はこれを起動時の自動確認の値に固定し、自動確認 OFF で起動した回は
        // 途中で ON にしても「自動でインストール」の書き込みを無視した(AppUpdater.apply のコメント)。
        let info = try #require(Bundle.main.infoDictionary)
        #expect((info["SUAllowsAutomaticUpdates"] as? NSNumber)?.boolValue == true)
    }

    @Test("ビルド番号はバージョンと同じ(Sparkle は CFBundleVersion で新旧を比べる)")
    func theBuildNumberFollowsTheMarketingVersion() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let version = try #require(info["CFBundleShortVersionString"] as? String)
        #expect(info["CFBundleVersion"] as? String == version)
    }

    @Test("テストの中ではアップデーターは動かない")
    @MainActor
    func theUpdaterStaysOffUnderTests() {
        let suite = PreferencesSuite()
        let updater = AppUpdater(preferences: suite.makePreferences())
        #expect(!updater.isAvailable)
        #expect(!updater.canCheckForUpdates)
        #expect(updater.refusal == .runningTests)
    }
}
