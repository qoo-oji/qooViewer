import Foundation
import Testing

@testable import qooViewer

/// 環境設定「外観」タブの設定一式(ViewModels/AppearanceSettings.swift)と、ノーマルウインドウ用・シークレットウインドウ用の
/// 2揃い(AppPreferences.appearance / privateAppearance / privateWindowsUseOwnAppearance)。2026-09-22。
///
/// AppPreferencesTests と同じく、総なめ(`mutateEveryAppearanceSetting` と Mirror の `settingsSnapshot`)で
/// 設定の足し忘れを名前を挙げて落とす。
@MainActor
struct AppearanceSettingsTests {

    // MARK: - 総なめ

    @Test("下ごしらえが外観のすべての設定を動かしている(設定を足したらここが落ちる)")
    func mutationTouchesEveryAppearanceSetting() {
        let suite = PreferencesSuite(label: "appearance")
        let a = suite.makePreferences().appearance
        let before = settingsSnapshot(of: a)
        mutateEveryAppearanceSetting(a)
        let after = settingsSnapshot(of: a)

        #expect(!before.isEmpty)
        let untouched = before.keys.filter { before[$0] == after[$0] }.sorted()
        #expect(untouched.isEmpty, "動かせていない設定: \(untouched.joined(separator: ", "))")
    }

    @Test("どちらの揃いも、すべての設定が保存され、開き直しても同じ値で戻る", arguments: AppearanceProfile.allCases)
    func everyAppearanceSettingSurvivesReopening(profile: AppearanceProfile) {
        let suite = PreferencesSuite(label: "appearance")
        let a = Self.settings(profile, in: suite.makePreferences())
        mutateEveryAppearanceSetting(a)

        let expected = settingsSnapshot(of: a)
        let actual = settingsSnapshot(of: Self.settings(profile, in: suite.makePreferences()))
        let lost = expected.keys.filter { expected[$0] != actual[$0] }.sorted()
        #expect(lost.isEmpty, "保存されていない設定: \(lost.joined(separator: ", "))")
    }

    @Test("「初期設定に戻す」は、その揃いの設定をひとつ残らず出荷時の値へ戻し、保存先とも一致する", arguments: AppearanceProfile.allCases)
    func resetRestoresEverySetting(profile: AppearanceProfile) {
        let shipping = settingsSnapshot(of: PreferencesSuite(label: "appearance").makePreferences().appearance)
        let suite = PreferencesSuite(label: "appearance")
        let a = Self.settings(profile, in: suite.makePreferences())
        mutateEveryAppearanceSetting(a)

        a.resetToDefaults()

        let after = settingsSnapshot(of: a)
        let notReset = after.keys.filter { after[$0] != shipping[$0] }.sorted()
        #expect(notReset.isEmpty, "戻っていない設定: \(notReset.joined(separator: ", "))")
        // allKeys に無い設定は、保存先に古い値が残って読み直しで戻ってくる(ユーザー報告:「文字の影」だけリセットされない)。
        let stored = settingsSnapshot(of: Self.settings(profile, in: suite.makePreferences()))
        let mismatched = after.keys.filter { after[$0] != stored[$0] }.sorted()
        #expect(mismatched.isEmpty, "保存先と食い違う設定: \(mismatched.joined(separator: ", "))")
    }

    @Test("copyValues はすべての設定を写す(設定を足したらここが落ちる)")
    func copyValuesCopiesEverySetting() {
        let suite = PreferencesSuite(label: "appearance")
        let p = suite.makePreferences()
        mutateEveryAppearanceSetting(p.appearance)

        p.privateAppearance.copyValues(from: p.appearance)

        #expect(settingsSnapshot(of: p.privateAppearance) == settingsSnapshot(of: p.appearance))
    }

    // MARK: - 2揃いの独立

    @Test("ノーマルの揃いは従来のキーに、シークレットの揃いは末尾に .privateWindow を付けたキーに保存する")
    func profilesUseTheirOwnKeys() {
        let suite = PreferencesSuite(label: "appearance")
        let p = suite.makePreferences()
        p.appearance.appAppearance = .dark
        p.privateAppearance.appAppearance = .light

        let stored = suite.storedDomain
        // ノーマルのキーは変えてはいけない(変えると既存の利用者の設定が消える)。
        #expect(stored["qooViewer.pref.appAppearance"] as? String == "dark")
        #expect(stored["qooViewer.pref.appAppearance.privateWindow"] as? String == "light")
        #expect(p.appearance.allKeys.allSatisfy { !$0.hasSuffix(".privateWindow") })
        #expect(p.privateAppearance.allKeys.allSatisfy { $0.hasSuffix(".privateWindow") })
    }

    @Test("片方の揃いを動かしても戻しても、もう片方は動かない", arguments: AppearanceProfile.allCases)
    func profilesAreIndependent(profile: AppearanceProfile) {
        let suite = PreferencesSuite(label: "appearance")
        let p = suite.makePreferences()
        let edited = Self.settings(profile, in: p)
        let other = Self.settings(profile == .normal ? .privateWindow : .normal, in: p)
        let otherBefore = settingsSnapshot(of: other)

        mutateEveryAppearanceSetting(edited)
        #expect(settingsSnapshot(of: other) == otherBefore)
        #expect(settingsSnapshot(of: Self.settings(other.profile, in: suite.makePreferences())) == otherBefore)

        mutateEveryAppearanceSetting(other)
        let otherMutated = settingsSnapshot(of: other)
        edited.resetToDefaults()
        #expect(settingsSnapshot(of: other) == otherMutated)
    }

    // MARK: - 「シークレットウインドウに別の外観を使う」

    @Test("OFF の間は、シークレットウインドウもノーマルの揃いを使う")
    func privateWindowsFollowNormalWhileOff() {
        let p = PreferencesSuite(label: "appearance").makePreferences()
        #expect(p.appearance(forPrivateWindow: false) === p.appearance)
        #expect(p.appearance(forPrivateWindow: true) === p.appearance)

        p.privateWindowsUseOwnAppearance = true
        #expect(p.appearance(forPrivateWindow: false) === p.appearance)
        #expect(p.appearance(forPrivateWindow: true) === p.privateAppearance)
    }

    @Test("初めて ON にしたとき、シークレットの揃いはノーマルの写しから始まる")
    func firstEnableCopiesTheNormalAppearance() {
        let suite = PreferencesSuite(label: "appearance")
        let p = suite.makePreferences()
        mutateEveryAppearanceSetting(p.appearance)

        p.privateWindowsUseOwnAppearance = true

        #expect(settingsSnapshot(of: p.privateAppearance) == settingsSnapshot(of: p.appearance))
        #expect(settingsSnapshot(of: suite.makePreferences().privateAppearance) == settingsSnapshot(of: p.appearance))
    }

    @Test("OFF にしてもシークレットの揃いは残り、ON に戻しても写し直さない")
    func reEnablingKeepsThePrivateAppearance() {
        let suite = PreferencesSuite(label: "appearance")
        let p = suite.makePreferences()
        p.privateWindowsUseOwnAppearance = true
        p.privateAppearance.titleBarColor = RGBColorValue(red: 1, green: 2, blue: 3)
        p.privateWindowsUseOwnAppearance = false
        p.appearance.titleBarColor = RGBColorValue(red: 200, green: 100, blue: 50)

        p.privateWindowsUseOwnAppearance = true
        #expect(p.privateAppearance.titleBarColor == RGBColorValue(red: 1, green: 2, blue: 3))

        // 開き直しても同じ(「写した」印も保存されている)。
        let reopened = suite.makePreferences()
        #expect(reopened.privateWindowsUseOwnAppearance)
        reopened.privateWindowsUseOwnAppearance = false
        reopened.privateWindowsUseOwnAppearance = true
        #expect(reopened.privateAppearance.titleBarColor == RGBColorValue(red: 1, green: 2, blue: 3))
    }

    @Test("どの画面の「初期設定に戻す」でも、スイッチもシークレットの揃いも動かない")
    func paneResetsLeaveThePrivateAppearanceAlone() {
        let p = PreferencesSuite(label: "appearance").makePreferences()
        p.privateWindowsUseOwnAppearance = true
        mutateEveryAppearanceSetting(p.privateAppearance)
        let privateBefore = settingsSnapshot(of: p.privateAppearance)

        for pane in SettingsPane.allCases { p.resetToDefaults(pane) }

        #expect(p.privateWindowsUseOwnAppearance)
        #expect(settingsSnapshot(of: p.privateAppearance) == privateBefore)
    }

    private static func settings(_ profile: AppearanceProfile, in p: AppPreferences) -> AppearanceSettings {
        switch profile {
        case .normal: p.appearance
        case .privateWindow: p.privateAppearance
        }
    }
}
