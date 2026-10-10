import AppKit
import Combine
import Foundation
import os
import Sparkle

/// 自動アップデート(Sparkle 2。2026-10-10)。アプリで 1 つ、`AppStores` が持つ。
///
/// ■ 何をするか
/// - Info.plist の約束(`UpdaterConfiguration`)を満たしているときだけ Sparkle を起動する。満たさなければ
///   何もしない(メニューの「アップデートを確認…」は淡色、環境設定の欄も淡色で理由を吹き出しに出す)。
/// - 環境設定「一般」▸「アップデート」の 2 つ(`AppPreferences.checksForUpdatesAutomatically` /
///   `installsUpdatesAutomatically`)を Sparkle へ流す。Sparkle の更新のウインドウのチェックボックスで変わった
///   「自動的にダウンロードしてインストール」は、逆向きに環境設定へ書き戻す。
/// - メニューの淡色に使う `canCheckForUpdates` を写して publish する(`AppStores.allObjectWillChangePublishers`
///   に並べてあるので、メニューの作り直しは MenuBarMenuGate を通る)。
///
/// ■ 通信はアプリ本体ではしない
/// このアプリはもともと一切通信しない(ネットワークの entitlement が無い)。Sparkle の Downloader.xpc に
/// 取りに行かせる(Info.plist の `SUEnableDownloaderService`)ので、本体のサンドボックスは今まで通り閉じたまま。
/// インストールも Installer.xpc 経由(`SUEnableInstallerLauncherService` + Configurations/qooViewer.entitlements)。
///
/// ■ テストの中では起動しない
/// テストは実物のアプリの中で走る(TEST_HOST)。テストホストは Debug なので `QOOUpdaterEnabled` が NO で
/// 起動しないが、念のため `RuntimeEnvironment.isRunningTests` でも止める(共有の状態に触らない・通信しない)。
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// いま「アップデートを確認…」を押せるか(Sparkle の `canCheckForUpdates` の写し。確認の最中は false)。
    @Published private(set) var canCheckForUpdates = false

    /// 起動しなかった理由(起動していれば nil)。環境設定の吹き出しの出し分けに使う。
    let refusal: UpdaterConfiguration.Refusal?

    /// Sparkle が動いているか。false の間は環境設定の欄とメニューの項目を淡色にする。
    var isAvailable: Bool { controller != nil }

    private let preferences: AppPreferences
    private let configuration: UpdaterConfiguration?
    private var controller: SPUStandardUpdaterController?
    private var subscriptions: Set<AnyCancellable> = []
    /// 環境設定の値を Sparkle へ書いている最中か。書いたことで Sparkle 側の KVO が返ってくるのを、
    /// 利用者が更新のウインドウで変えたものと取り違えて書き戻さないため。
    private var isApplyingPreferences = false

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "qooViewer", category: "Updater")

    init(
        preferences: AppPreferences,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        isRunningTests: Bool = RuntimeEnvironment.isRunningTests
    ) {
        self.preferences = preferences
        switch UpdaterConfiguration.validate(infoDictionary: infoDictionary, isRunningTests: isRunningTests) {
        case .success(let configuration):
            self.configuration = configuration
            self.refusal = nil
        case .failure(let refusal):
            self.configuration = nil
            self.refusal = refusal
        }
        super.init()
        guard configuration != nil else {
            if let refusal, refusal.isConfigurationError {
                // Release なのに約束を満たしていない = 配布物の作り方の誤り。黙って更新が止まるので、ログには残す。
                Self.logger.error("Updater not started: \(String(describing: refusal), privacy: .public)")
            }
            return
        }
        start()
    }

    /// メニューの「アップデートを確認…」。押せない状態(淡色のはず)で呼ばれたら鳴らす(CLAUDE.md「拒むときは知らせる」)。
    func checkForUpdates() {
        guard let controller, controller.updater.canCheckForUpdates else {
            NSSound.beep()
            return
        }
        controller.checkForUpdates(nil)
    }

    private func start() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        let updater = controller.updater
        // Sparkle は defaults に書かれた SUFeedURL を Info.plist より優先する(古い API の名残)。誰かが書いた値で
        // 別の配信元へ向けられないよう、起動のたびに消す(配信元はデリゲートの feedURLString でも固定している)。
        updater.clearFeedURLFromUserDefaults()
        applyPreferences(to: updater)
        do {
            try updater.start()
        } catch {
            // SPUStandardUpdaterController.startUpdater() は起動時にアラートを出すが、起動の直後に利用者へ出しても
            // できることが無い。ログに残し、メニューと環境設定を淡色にする(controller を持たない)。
            Self.logger.error("Updater failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.controller = controller

        // KVO の知らせは、値を書き換えたスレッドで届く。Sparkle はメインスレッドでしか書き換えないので、ふつうはそのまま
        // 受ける(`onMain`)。届いた値ではなく、受けた時点の Sparkle の値を読む ―― メインへ回した場合に、古い値で書き戻さない。
        updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .sink { @Sendable [weak self, weak updater] _ in
                AppUpdater.onMain { [weak self, weak updater] in
                    guard let self, let updater, self.canCheckForUpdates != updater.canCheckForUpdates else { return }
                    self.canCheckForUpdates = updater.canCheckForUpdates
                }
            }
            .store(in: &subscriptions)
        // Sparkle の更新のウインドウの「今後は自動的にダウンロードしてインストール」で変わった値を環境設定へ戻す。
        // 自動確認が OFF の間は Sparkle がこの値を常に NO と答える(保存値ではなく「今は効かない」の意味)ので、
        // そのときは書き戻さない ―― 書き戻すと、自動確認を OFF にしただけで利用者の選択が消える。
        updater.publisher(for: \.automaticallyDownloadsUpdates, options: [.new])
            .sink { @Sendable [weak self, weak updater] _ in
                AppUpdater.onMain { [weak self, weak updater] in
                    guard let self, let updater, !self.isApplyingPreferences,
                          updater.automaticallyChecksForUpdates else { return }
                    let value = updater.automaticallyDownloadsUpdates
                    guard self.preferences.installsUpdatesAutomatically != value else { return }
                    self.preferences.installsUpdatesAutomatically = value
                }
            }
            .store(in: &subscriptions)
        // 環境設定 → Sparkle。@Published は値が入る前に流れるので、受け取った値で組み立てる。
        preferences.$checksForUpdatesAutomatically
            .combineLatest(preferences.$installsUpdatesAutomatically)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .sink { [weak self, weak updater] checks, installs in
                guard let self, let updater else { return }
                self.apply(checks: checks, installs: installs, to: updater)
            }
            .store(in: &subscriptions)
    }

    private func applyPreferences(to updater: SPUUpdater) {
        apply(checks: preferences.checksForUpdatesAutomatically,
              installs: preferences.installsUpdatesAutomatically, to: updater)
    }

    private func apply(checks: Bool, installs: Bool, to updater: SPUUpdater) {
        isApplyingPreferences = true
        defer { isApplyingPreferences = false }
        if updater.automaticallyChecksForUpdates != checks {
            updater.automaticallyChecksForUpdates = checks
        }
        // 自動確認が OFF の間、Sparkle はこの書き込みを無視する(allowsAutomaticUpdates が NO)。ON に戻した
        // ときにここをもう一度通るので、利用者の選択はそこで効く(自動確認を切り替えると Sparkle は allowsAutomaticUpdates を
        // 計算し直す。自動確認 OFF のまま起動して途中で ON にした回も効くことを 2026-10-10 に実機で確かめた ―― 同じ日の監査で
        // 「計算し直さない」とソースから読んで SUAllowsAutomaticUpdates = YES を足したが、実測で誤りと分かり戻した)。
        if checks, updater.automaticallyDownloadsUpdates != installs {
            updater.automaticallyDownloadsUpdates = installs
        }
    }

    /// KVO の知らせを、メインアクターで受ける(届いたスレッドがメインならその場で、ほかならメインへ回して)。
    /// 以前は `MainActor.assumeIsolated` だけで、メイン以外で届けば落ちた(2026-10-10 の監査の 3。Sparkle 自身はメインでしか
    /// 書き換えないが、アプリの中のどこかがメイン以外で Sparkle の defaults を書けば、その KVO はそのスレッドで届く)。
    nonisolated private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    // MARK: - SPUUpdaterDelegate

    /// 配信元は Info.plist の値に固定する(defaults の値を使わせない。上の start のコメント)。
    func feedURLString(for updater: SPUUpdater) -> String? {
        configuration?.feedURL.absoluteString
    }

    /// 2 回目の起動で「自動的に確認しますか」と尋ねる Sparkle の既定の確認は出さない。確認するかどうかは
    /// 環境設定(既定 ON。利用者の判断 2026-10-10)が決め、起動の前に Sparkle へ流してある。
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }
}

/// Sparkle を起動してよいかを Info.plist の値だけで決める(副作用なし。`UpdaterConfigurationTests`)。
///
/// Info.plist のコメントに書いた約束を、アプリ自身も起動の前に確かめる。どれかが崩れていたら(誰かが緩めた・
/// 作り方を誤った)更新そのものをしない ―― 署名の確かめを緩めたまま更新を受け入れるより、更新が止まるほうが安全。
/// 同じ約束を配布前の .app に対して `scripts/ci/check-release-app.sh` も確かめる。
nonisolated struct UpdaterConfiguration: Equatable, Sendable {
    let feedURL: URL
    let publicEDKey: String

    enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        /// Debug ビルドなど、そもそも更新しない作り(`QOOUpdaterEnabled` が YES でない)。
        case disabledInThisBuild
        /// テストホストの中。
        case runningTests
        case missingFeedURL
        /// HTTPS でない・ホストが無い・URL に利用者名やパスワードが入っている。
        case insecureFeedURL(String)
        /// 公開鍵が空(鍵を作る前のビルド)。
        case missingPublicKey
        /// base64 で 32 バイト(Ed25519 の公開鍵)にならない。
        case malformedPublicKey
        /// 署名の確かめ・プライバシーに関わる設定が約束と違う(キーの名前)。
        case insecureSetting(String)

        /// 配布物の作り方の誤り(ログに残すもの)か。Debug・テストは意図どおりなので違う。
        var isConfigurationError: Bool {
            switch self {
            case .disabledInThisBuild, .runningTests: false
            default: true
            }
        }

        var description: String {
            switch self {
            case .disabledInThisBuild: "disabled in this build"
            case .runningTests: "running tests"
            case .missingFeedURL: "SUFeedURL is missing"
            case .insecureFeedURL(let url): "SUFeedURL is not a plain HTTPS URL: \(url)"
            case .missingPublicKey: "SUPublicEDKey is empty"
            case .malformedPublicKey: "SUPublicEDKey is not a base64 Ed25519 public key"
            case .insecureSetting(let key): "\(key) does not have the required value"
            }
        }
    }

    static func validate(infoDictionary info: [String: Any], isRunningTests: Bool) -> Result<UpdaterConfiguration, Refusal> {
        if isRunningTests { return .failure(.runningTests) }
        guard bool(info["QOOUpdaterEnabled"]) == true else { return .failure(.disabledInThisBuild) }

        guard let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces), !feed.isEmpty else {
            return .failure(.missingFeedURL)
        }
        guard let components = URLComponents(string: feed), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let feedURL = components.url else {
            return .failure(.insecureFeedURL(feed))
        }

        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if key.isEmpty { return .failure(.missingPublicKey) }
        guard let keyData = Data(base64Encoded: key), keyData.count == 32 else {
            return .failure(.malformedPublicKey)
        }

        // 必ず YES でなければならないもの(Info.plist のコメント)。
        for required in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed",
                         "SUEnableInstallerLauncherService", "SUEnableDownloaderService"]
            where bool(info[required]) != true {
            return .failure(.insecureSetting(required))
        }
        // YES にしてはならないもの(無ければ Sparkle の既定の NO)。
        for forbidden in ["SUEnableSystemProfiling", "SUEnableJavaScript"] where bool(info[forbidden]) == true {
            return .failure(.insecureSetting(forbidden))
        }
        // 署名の合わない appcast を、期限が過ぎたら受け入れる逃げ道を閉じておく(0 = 期限切れにしない)。
        // 無いと Sparkle の既定の 20 日になるので、「無い」も認めない。
        guard let interval = info["SUSignedFeedFailureExpirationInterval"] as? NSNumber, interval.doubleValue == 0 else {
            return .failure(.insecureSetting("SUSignedFeedFailureExpirationInterval"))
        }
        return .success(UpdaterConfiguration(feedURL: feedURL, publicEDKey: key))
    }

    /// Info.plist の真偽値。`<true/>` は NSNumber、ビルド設定から入れた値は "YES" / "NO" の文字列で来る。
    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: number.boolValue
        case let string as String:
            switch string.lowercased() {
            case "yes", "true", "1": true
            case "no", "false", "0", "": false
            default: nil
            }
        default: nil
        }
    }
}
