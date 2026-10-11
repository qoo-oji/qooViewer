import AppKit
import Foundation
import Testing

@testable import qooViewer

/// Debug ビルドだけの制御口(App/DebugControlPort.swift)。テストホストの中では聞き始めないので、頼みの実行と状態の書き出しを
/// 直に呼んで確かめる。実物のアプリを外から動かす確かめは CI の起動の確かめ(scripts/ci/smoke-control-port.sh)。
@MainActor
struct DebugControlPortTests {
    private func makePort(_ harness: AppStoresHarness) -> DebugControlPort {
        DebugControlPort(directory: harness.temporary.file("control"), stores: harness.stores)
    }

    @Test("設定の切り替えは、設定の画面と同じ値を書き、AppStores の購読まで届く")
    func setPreferenceReachesTheStores() async throws {
        let harness = try AppStoresHarness(label: "debug-port-preference")
        defer { harness.close() }
        let port = makePort(harness)

        let result = try await port.perform("setPreference", arguments: ["key": "libraryFeatureEnabled", "value": false])
        #expect((result as? [String: Bool]) == ["libraryFeatureEnabled": false])
        #expect(harness.stores.preferences.libraryFeatureEnabled == false)
        #expect(harness.stores.collectionStore.isLibraryFeatureEnabled == false)

        await #expect(throws: DebugControlPort.Failure.self) {
            _ = try await port.perform("setPreference", arguments: ["key": "displayLanguage", "value": true])
        }
    }

    @Test("知らない頼み・足りない引数・相手の窓が無い頼みは、理由を付けて断る")
    func badRequestsAreRefusedWithAReason() async throws {
        let harness = try AppStoresHarness(label: "debug-port-refusals")
        defer { harness.close() }
        let port = makePort(harness)
        for (command, arguments) in [
            ("noSuchCommand", [:]),
            ("perform", ["action": "noSuchAction"]),
            ("open", [:]),
            ("closeBook", [:]),
            ("selectHomeMode", ["mode": "nowhere"]),
        ] as [(String, [String: Any])] {
            await #expect(throws: DebugControlPort.Failure.self, "\(command)") {
                _ = try await port.perform(command, arguments: arguments)
            }
        }
    }

    @Test("状態の書き出しは JSON にでき、機能の ON/OFF と生きているインスタンスの数を含む")
    func stateDumpIsJSON() async throws {
        let harness = try AppStoresHarness(label: "debug-port-state")
        defer { harness.close() }
        let state = try #require(try await makePort(harness).perform("state", arguments: [:]) as? [String: Any])
        #expect(JSONSerialization.isValidJSONObject(state))
        let features = try #require(state["features"] as? [String: Bool])
        #expect(features["library"] == true)
        #expect(state["liveInstances"] is [String: Int])
    }

    @Test("メニューの木は、題・淡色・キー・入れ子を書き出す")
    func menuTreeDescribesItems() throws {
        let menu = NSMenu(title: "root")
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Open", action: nil, keyEquivalent: "o")
        open.isEnabled = false
        menu.addItem(open)
        menu.addItem(.separator())
        let parent = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "More")
        submenu.addItem(NSMenuItem(title: "Inner", action: nil, keyEquivalent: ""))
        parent.submenu = submenu
        menu.addItem(parent)

        let tree = DebugStateDump.menuTree(menu)
        #expect(JSONSerialization.isValidJSONObject(tree))
        #expect(tree.map { $0["title"] as? String } == ["Open", "", "More"])
        #expect(tree[0]["isEnabled"] as? Bool == false)
        #expect(tree[0]["keyEquivalent"] as? String == "o")
        #expect(tree[1]["isSeparator"] as? Bool == true)
        let inner = try #require(tree[2]["items"] as? [[String: Any]])
        #expect(inner.first?["title"] as? String == "Inner")
    }

    @Test("返事のファイル名は頼みのファイル名だけ(outbox の外を指す名前・隠しファイル・区切りを含む名前は使わない)")
    func replyNamesStayInsideTheOutbox() {
        #expect(DebugControlPort.isSafeReplyName("1791678932904-c3d37685"))
        for unsafe in ["", "../ready", ".hidden", "a/b", "..", "名前", String(repeating: "a", count: 200)] {
            #expect(DebugControlPort.isSafeReplyName(unsafe) == false, "\(unsafe)")
        }
    }

    @Test("生きているインスタンスの数は、作った数と手放した数の差")
    func liveInstancesCountCreatesAndReleases() {
        let name = "Probe-\(UUID().uuidString)"
        DebugLiveInstances.didCreate(name)
        DebugLiveInstances.didCreate(name)
        DebugLiveInstances.didRelease(name)
        #expect(DebugLiveInstances.snapshot[name] == 1)
    }
}
