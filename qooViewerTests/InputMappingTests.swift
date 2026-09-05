import AppKit
import Foundation
import Testing

@testable import qooViewer

/// キー割り当ての識別(Models/RemappableKey.swift)。
///
/// `id` は UserDefaults に保存される安定した識別子なので、変えると利用者の割り当てが消える。
/// `from(nsEvent:)` の方は、SwiftUI の `.onKeyPress` に矢印キーが届かない環境があったため
/// 後から足した経路で、修飾キーの付随フラグ(macOS が矢印キーに勝手に立てる `.numericPad` /
/// `.function`)に引っかからないことが要件。
struct RemappableKeyTests {
    private func keyEvent(
        keyCode: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
    }

    // MARK: - 安定した識別子

    @Test("id は保存されるので変えられない")
    func identifiersAreFrozen() {
        #expect(RemappableKey.leftArrow.id == "leftArrow")
        #expect(RemappableKey.shiftRightArrow.id == "shiftRightArrow")
        #expect(RemappableKey.optionSpace.id == "optionSpace")
        #expect(RemappableKey.character("a").id == "char:a")
        #expect(RemappableKey.optionCharacter("a").id == "optionChar:a")
        #expect(RemappableKey.controlCharacter("a").id == "controlChar:a")
    }

    @Test("選択肢は重複せず、特殊キー 17 + 英数 36 × 3 通り")
    func theSelectableListIsComplete() {
        #expect(RemappableKey.selectable.count == 17 + 36 * 3)
        #expect(Set(RemappableKey.selectable.map(\.id)).count == RemappableKey.selectable.count)
    }

    @Test("Codable で往復する(UserDefaults へ入る値)")
    func codableRoundTrip() throws {
        let key = RemappableKey.optionCharacter("z")
        let data = try JSONEncoder().encode(key)
        #expect(try JSONDecoder().decode(RemappableKey.self, from: data) == key)
    }

    // MARK: - NSEvent からの判定

    @Test("矢印キーは、macOS が勝手に立てる付随フラグがあっても認識する")
    func arrowKeysSurviveIncidentalModifierFlags() {
        // ここが「flags.isEmpty」だったころ、無修飾の矢印キーが一切効かなかった。
        let incidental: NSEvent.ModifierFlags = [.numericPad, .function]
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 123, flags: incidental)) == .leftArrow)
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 124, flags: incidental)) == .rightArrow)
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 126, flags: incidental)) == .upArrow)
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 125, flags: incidental)) == .downArrow)
    }

    @Test("矢印キーの shift / option 付き")
    func arrowKeysWithModifiers() {
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 123, flags: .shift)) == .shiftLeftArrow)
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 124, flags: .option)) == .optionRightArrow)
        // control + 矢印は Mission Control と衝突するので選択肢に無い。
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 123, flags: .control)) == nil)
        // 上下の矢印には修飾キー付きの選択肢が無い。
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 126, flags: .shift)) == nil)
    }

    @Test("space と tab")
    func spaceAndTab() {
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 49, characters: " ")) == .space)
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 49, characters: " ", flags: .shift)) == .shiftSpace)
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 49, characters: " ", flags: .option)) == .optionSpace)
        // control + space は入力ソース切替。
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 49, characters: " ", flags: .control)) == nil)
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 48, characters: "\t")) == .tab)
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 48, characters: "\t", flags: .shift)) == .shiftTab)
    }

    @Test("文字キーは大文字小文字を区別しない")
    func characterKeysIgnoreCase() {
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 0, characters: "a")) == .character("a"))
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 0, characters: "A", flags: .shift)) == .character("a"))
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 0, characters: "a", flags: .option)) == .optionCharacter("a"))
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 0, characters: "a", flags: .control)) == .controlCharacter("a"))
    }

    @Test("command 付き・修飾キー 2 つ以上・記号は認識しない")
    func unsupportedCombinationsAreRejected() {
        // command はメニューバーのショートカットと衝突しやすいので対象外。
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 0, characters: "a", flags: .command)) == nil)
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 123, flags: [.shift, .option])) == nil)
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 0, characters: "-")) == nil)
        #expect(RemappableKey.from(nsEvent: keyEvent(keyCode: 0, characters: "")) == nil)
    }
}

/// マウス操作の割り当て(Models/MouseTrigger.swift)。
struct MouseTriggerTests {
    // MARK: - 安定した識別子

    @Test("id は入力と修飾キーから組み立てる(保存されるので変えられない)")
    func identifiersAreFrozen() {
        #expect(MouseTrigger(input: .click(.left, .rightHalf), modifiers: []).id
            == "click:b0:rightHalf:none")
        #expect(MouseTrigger(input: .click(.middle, .anywhere), modifiers: [.shift]).id
            == "click:b2:anywhere:shift")
        #expect(MouseTrigger(input: .wheel(.up), modifiers: [.option]).id == "wheel:up:option")
        // 修飾キーの順序は固定 ―― 揺れると同じ組み合わせが別の id になる。
        #expect(MouseTrigger(input: .drag(.left, .right), modifiers: [.option, .shift]).id
            == MouseTrigger(input: .drag(.left, .right), modifiers: [.shift, .option]).id)
        #expect(MouseTrigger(input: .drag(.left, .right), modifiers: [.shift, .option]).id
            == "drag:b0:right:shift+option")
    }

    @Test("選択肢は重複しない")
    func theSelectableListHasNoDuplicates() {
        #expect(!MouseTrigger.selectable.isEmpty)
        #expect(Set(MouseTrigger.selectable.map(\.id)).count == MouseTrigger.selectable.count)
        #expect(MouseTrigger.groups.flatMap(\.triggers).count == MouseTrigger.selectable.count)
    }

    @Test("ホイールには shift 付きの選択肢を作らない")
    func wheelTriggersNeverCarryShift() {
        // macOS は shift 押下でスクロールの軸を入れ替えるため、shift 付きは作らない。
        let wheel = MouseTrigger.selectable.filter {
            if case .wheel = $0.input { return true }
            return false
        }
        #expect(!wheel.isEmpty)
        #expect(wheel.allSatisfy { !$0.modifiers.contains(.shift) })
    }

    // MARK: - ドラッグの判定

    @Test("30 ポイントを超えて動いたときだけ、優勢な軸の向きになる")
    func dragNeedsToPassTheMinimumDistance() {
        // cooViewer と同じ判定(30 ポイント・1 秒以内)。手ぶれでページ送りが効かなくなると困る。
        #expect(MouseTrigger.DragDirection.from(dx: 31, dy: 0, duration: 0.2) == .right)
        #expect(MouseTrigger.DragDirection.from(dx: -31, dy: 0, duration: 0.2) == .left)
        #expect(MouseTrigger.DragDirection.from(dx: 0, dy: 31, duration: 0.2) == .up)
        #expect(MouseTrigger.DragDirection.from(dx: 0, dy: -31, duration: 0.2) == .down)
        // ちょうど 30 は「超えて」いない。
        #expect(MouseTrigger.DragDirection.from(dx: 30, dy: 0, duration: 0.2) == nil)
        #expect(MouseTrigger.DragDirection.from(dx: 29, dy: 29, duration: 0.2) == nil)
    }

    @Test("斜めは移動量の大きい軸で決める")
    func diagonalDragsPickTheDominantAxis() {
        #expect(MouseTrigger.DragDirection.from(dx: 50, dy: 40, duration: 0.2) == .right)
        #expect(MouseTrigger.DragDirection.from(dx: 40, dy: 50, duration: 0.2) == .up)
        // 同じ長さなら横を優先する(abs(dx) >= abs(dy))。
        #expect(MouseTrigger.DragDirection.from(dx: 40, dy: 40, duration: 0.2) == .right)
    }

    @Test("1 秒を超えたらジェスチャーではない")
    func slowDragsAreNotGestures() {
        // 押したまま考えていた/掴んだまま止まっていた、という操作を弾く。
        #expect(MouseTrigger.DragDirection.from(dx: 100, dy: 0, duration: 1.01) == nil)
        #expect(MouseTrigger.DragDirection.from(dx: 100, dy: 0, duration: 1) == .right)
    }

    @Test("片方の軸だけが大きい場合、もう一方が閾値未満でも成立する")
    func oneAxisIsEnough() {
        #expect(MouseTrigger.DragDirection.from(dx: 100, dy: 5, duration: 0.2) == .right)
        #expect(MouseTrigger.DragDirection.from(dx: 5, dy: 100, duration: 0.2) == .up)
    }

    // MARK: - 修飾キーの照合

    @Test("control / command が押されていたら「修飾キー無し」ではなく nil")
    func controlAndCommandAreRejectedRatherThanIgnored() {
        // 呼び出し側は nil を「何もしない」と扱う ―― control+クリックはコンテキストメニュー。
        #expect(MouseTrigger.Modifiers.from(.control, allowsShift: true) == nil)
        #expect(MouseTrigger.Modifiers.from(.command, allowsShift: true) == nil)
        #expect(MouseTrigger.Modifiers.from([.shift, .control], allowsShift: true) == nil)
    }

    @Test("shift を受け付けない経路(ホイール)では、shift 付きは nil")
    func shiftIsRejectedWhereItIsNotAllowed() {
        #expect(MouseTrigger.Modifiers.from(.shift, allowsShift: false) == nil)
        #expect(MouseTrigger.Modifiers.from(.option, allowsShift: false) == [.option])
        #expect(MouseTrigger.Modifiers.from([], allowsShift: false) == [])
    }

    @Test("付随フラグ(caps lock など)は無視する")
    func incidentalFlagsAreIgnored() {
        #expect(MouseTrigger.Modifiers.from([.shift, .option], allowsShift: true) == [.shift, .option])
        #expect(MouseTrigger.Modifiers.from([.capsLock], allowsShift: true) == [])
    }

    @Test("表示名は翻訳しないキー名そのもの")
    func modifierDisplayNames() {
        #expect(MouseTrigger.Modifiers([]).displayName == nil)
        #expect(MouseTrigger.Modifiers([.shift]).displayName == "shift")
        #expect(MouseTrigger.Modifiers([.shift, .option]).displayName == "shift + option")
    }
}
