import Foundation
import Testing

@testable import qooViewer

/// キーボード/マウスの割り当て(ViewModels/KeyBindingStore.swift)。
///
/// 保存先は `init(defaults:)` で差し替える(`AppPreferences` と同じ理由 ―― テストは
/// TEST_HOST = 実物のアプリの中で走るので、既定のままでは利用者の割り当てを書き換える)。
@MainActor
struct KeyBindingStoreTests {
    private func makeStore(_ suite: PreferencesSuite) -> KeyBindingStore {
        KeyBindingStore(defaults: suite.defaults)
    }

    // MARK: - 既定値の補完(2条件)

    @Test("保存済みに無い既定は補うが、条件は2つとも満たす場合だけ")
    func missingDefaultsAreFilledUnderTwoConditions() {
        let defaults: [String: ViewerAction] = ["a": .moveNext, "b": .moveNext, "c": .toggleLoupe]

        // どちらの条件も満たす(cは使われておらず、toggleLoupeにも割り当てが無い)→ 補う。
        #expect(
            KeyBindingStore.fillingMissingDefaults(["a": .moveNext], defaults: defaults)
                == ["a": .moveNext, "c": .toggleLoupe]
        )
        // 条件1に反する: そのキーを別の操作へ割り当て直している → 奪わない。
        #expect(
            KeyBindingStore.fillingMissingDefaults(["c": .firstPage], defaults: defaults)["c"]
                == .firstPage
        )
        // 条件2に反する: その操作には既に別のキーが割り当たっている → 予備のキーは戻さない
        // (既定が a と b の2つある moveNext から、b だけ外した人に b は戻らない)。
        #expect(
            KeyBindingStore.fillingMissingDefaults(["a": .moveNext], defaults: defaults)["b"] == nil
        )
        // 唯一の割り当てを外した場合だけは復活する(外したのか一度も持っていなかったのかを、
        // 保存データからは区別できないため。新しい操作が手元に届くほうを優先している)。
        // 判定に使う「割り当て済みの操作」は補う前の保存データから一度だけ作るので、
        // 空の保存データには既定がそのまま全部戻る。
        #expect(KeyBindingStore.fillingMissingDefaults([:], defaults: defaults) == defaults)
    }

    @Test("表示モード別の上書きには、既定値の補完を適用しない")
    func theModeOverridesAreNotFilledWithDefaults() throws {
        let suite = PreferencesSuite()
        // 「項目が無いこと」自体が「基本の割り当てへフォールバックする」という意味を持つため、
        // 補うと意図的なフォールバックが上書きに変わってしまう。
        let stored: [String: [String: ViewerAction]] = [
            ScalingMode.fitWidth.rawValue: [RemappableKey.character("j").id: .moveNext]
        ]
        suite.defaults.set(try JSONEncoder().encode(stored), forKey: "qooViewer.modeKeyBindings.v1")

        let store = makeStore(suite)
        #expect(store.modeKeyBindings[.fitWidth]?.count == 1)
        #expect(store.modeKeyBindings[.fitWidth]?[RemappableKey.character("j").id] == .moveNext)
        // 基本のほうは(保存が無いので)既定値のまま。
        #expect(store.keyBindings == KeyBindingStore.defaultKeyBindings)
    }

    // MARK: - 旧形式(4択のトリガー)からの読み替え

    @Test("旧 InputTrigger の4択は、新しい MouseTrigger の識別子へ読み替える")
    func theLegacyMouseTriggersAreMigrated() {
        let migrated = KeyBindingStore.migratedLegacyMouseBindings([
            "clickLeftZone": .spatialLeft,
            "clickRightZone": .spatialRight,
            "wheelUp": .movePrevious,
            "wheelDown": .moveNext,
            "somethingBroken": .firstPage,
        ])

        // 当時のトリガーはどれも「左ボタン・修飾キー無し」に相当する。
        #expect(migrated[MouseTrigger(input: .click(.left, .leftHalf), modifiers: []).id] == .spatialLeft)
        #expect(migrated[MouseTrigger(input: .click(.left, .rightHalf), modifiers: []).id] == .spatialRight)
        #expect(migrated[MouseTrigger(input: .wheel(.up), modifiers: []).id] == .movePrevious)
        #expect(migrated[MouseTrigger(input: .wheel(.down), modifiers: []).id] == .moveNext)
        // 対応表に無いキー(壊れたデータ)は捨てる。
        #expect(migrated.count == 4)
    }

    @Test("旧キーしか無ければ読み替えたうえで、あとから増えた既定を補う")
    func aStoreWithOnlyLegacyDataIsMigratedAndFilled() throws {
        let suite = PreferencesSuite()
        let legacy: [String: ViewerAction] = ["clickLeftZone": .spatialRight]
        suite.defaults.set(try JSONEncoder().encode(legacy), forKey: "qooViewer.mouseBindings.v1")

        let store = makeStore(suite)
        // 読み替え: 旧「左半分のクリック」の割り当てはそのまま(操作は入れ替えてある)。
        #expect(
            store.mouseBindings[MouseTrigger(input: .click(.left, .leftHalf), modifiers: []).id]
                == .spatialRight
        )
        // 補完: 旧形式に無かった中ボタンのルーペは、作り直しで増えた既定として入る。
        #expect(
            store.mouseBindings[MouseTrigger(input: .click(.middle, .anywhere), modifiers: []).id]
                == .toggleLoupe
        )
        // 旧キーは読むだけで、書き換えない。
        #expect(suite.storedDomain["qooViewer.mouseBindings.v1"] != nil)
    }

    // MARK: - 解決の優先順位

    @Test("キーの解決は、表示モード別の上書きが基本の割り当てより優先される")
    func theModeOverrideWinsOverTheBaseBinding() {
        let store = makeStore(PreferencesSuite())
        store.addKeyBinding(.firstPage, for: .character("z"), in: .fitWidth)

        #expect(store.resolvedAction(for: .character("z"), in: .fitToScreen) == .moveNext)
        #expect(store.resolvedAction(for: .character("z"), in: .fitWidth) == .firstPage)
        // 上書きの無いキーは、そのモードでも基本へフォールバックする。
        #expect(store.resolvedAction(for: .character("x"), in: .fitWidth) == .movePrevious)
    }

    @Test("クリックの解決は、位置の指定が「全体」より優先される")
    func aZonedClickWinsOverAnywhere() {
        let store = makeStore(PreferencesSuite())
        store.addMouseBinding(
            .toggleLoupe, for: MouseTrigger(input: .click(.middle, .anywhere), modifiers: []),
            in: .fitToScreen
        )
        store.addMouseBinding(
            .firstPage, for: MouseTrigger(input: .click(.middle, .leftHalf), modifiers: []),
            in: .fitToScreen
        )

        #expect(
            store.resolvedClickAction(
                button: .middle, zone: .leftHalf, modifiers: [], in: .fitToScreen) == .firstPage
        )
        #expect(
            store.resolvedClickAction(
                button: .middle, zone: .rightHalf, modifiers: [], in: .fitToScreen) == .toggleLoupe
        )
        // 位置と表示モードの両方が効く(位置 > 全体、モード別 > 基本)。
        store.addMouseBinding(
            .lastPage, for: MouseTrigger(input: .click(.middle, .leftHalf), modifiers: []),
            in: .noScale
        )
        #expect(
            store.resolvedClickAction(
                button: .middle, zone: .leftHalf, modifiers: [], in: .noScale) == .lastPage
        )
        #expect(
            store.resolvedClickAction(
                button: .middle, zone: .rightHalf, modifiers: [], in: .noScale) == .toggleLoupe
        )
    }

    // MARK: - 保存と読み直し

    @Test("割り当ての変更は保存され、開き直しても同じ値で戻る")
    func bindingsSurviveReopening() {
        let suite = PreferencesSuite()
        let store = makeStore(suite)
        store.addKeyBinding(.toggleLoupe, for: .character("j"), in: .fitToScreen)
        store.removeKeyBinding(for: .character("x"), in: .fitToScreen)
        store.addMouseBinding(
            .firstPage, for: MouseTrigger(input: .click(.middle, .rightHalf), modifiers: []),
            in: .fitWidth
        )
        store.setWheelBehavior(.turnPage, in: .noScale)
        store.setScrollStep(42, in: .fitWidth)

        let reopened = makeStore(suite)
        #expect(reopened.keyBindings[RemappableKey.character("j").id] == .toggleLoupe)
        #expect(reopened.mouseBindings == store.mouseBindings)
        #expect(reopened.modeMouseBindings[.fitWidth] == store.modeMouseBindings[.fitWidth])
        #expect(reopened.wheelBehavior(in: .noScale) == .turnPage)
        #expect(reopened.scrollStep(in: .fitWidth) == 42)
        // 外したキーは、そのキーが既定として持っていた操作が別のキーにも残っているので
        // 復活しない(補完の条件2)。
        #expect(reopened.keyBindings[RemappableKey.character("x").id] == nil)
    }

    @Test("1つのキーに割り当てられる操作は1つ(付け替えると元の操作から外れる)")
    func aKeyCarriesOnlyOneAction() {
        let store = makeStore(PreferencesSuite())
        store.addKeyBinding(.toggleLoupe, for: .character("z"), in: .fitToScreen)

        #expect(store.keyBindings[RemappableKey.character("z").id] == .toggleLoupe)
        // moveNext には既定でもう1つ(space)が残っている。
        #expect(store.keys(for: .moveNext, in: .fitToScreen).contains(.space))
        #expect(store.keys(for: .moveNext, in: .fitToScreen).contains(.character("z")) == false)
    }

    @Test("モードごとの初期化は、そのモードの上書きだけを戻す")
    func resettingOneModeLeavesTheOthersAlone() {
        let suite = PreferencesSuite()
        let store = makeStore(suite)
        store.addKeyBinding(.toggleLoupe, for: .character("j"), in: .fitWidth)
        store.addKeyBinding(.toggleLoupe, for: .character("j"), in: .noScale)

        store.resetToDefaults(in: .fitWidth)

        #expect(store.modeKeyBindings[.fitWidth] == KeyBindingStore.defaultOverrideKeyBindings)
        #expect(store.modeKeyBindings[.noScale]?[RemappableKey.character("j").id] == .toggleLoupe)
        // 保存にも反映される。
        #expect(makeStore(suite).modeKeyBindings[.fitWidth] == KeyBindingStore.defaultOverrideKeyBindings)
    }

    @Test("テスト用の保存先を渡した割り当ては、実物のアプリの設定に触れない")
    func aTestSuiteStoreDoesNotWriteToTheStandardStore() {
        let watched = [
            "qooViewer.keyBindings.v1", "qooViewer.mouseTriggerBindings.v1",
            "qooViewer.modeKeyBindings.v1", "qooViewer.modeScrollSteps.v1",
        ]
        let before = watched.map { String(describing: UserDefaults.standard.data(forKey: $0)) }

        let store = makeStore(PreferencesSuite())
        store.addKeyBinding(.toggleLoupe, for: .character("j"), in: .fitToScreen)
        store.setScrollStep(99, in: .fitWidth)

        #expect(watched.map { String(describing: UserDefaults.standard.data(forKey: $0)) } == before)
    }
}
