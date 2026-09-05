import Foundation

@testable import qooViewer

/// 環境設定 1 テストぶんの保存先。
///
/// `AppPreferences` は既定では `UserDefaults.standard` を読み書きする ―― テストは
/// TEST_HOST = 実物のアプリの中で走るので、そのまま作ると**利用者の環境設定を書き換えてしまう**。
/// その場限りの suite を作って `AppPreferences(defaults:)` へ渡し、最後に領域ごと消す。
///
/// テスト用の suite を渡したインスタンスは、保存先の外へ出ていく副作用
/// (サムネイルのディスクキャッシュの設定・`NSApp.appearance`・2 つの通知)を行わない
/// (`AppPreferences.sharesGlobalState` のコメント参照)。
@MainActor
final class PreferencesSuite {
    let name: String
    let defaults: UserDefaults

    init(label: String = "preferences") {
        name = "qooViewerTests.\(label).\(UUID().uuidString)"
        // suiteName が既存のドメイン名と衝突しない限り nil にはならない(UUID 付き)。
        defaults = UserDefaults(suiteName: name) ?? .standard
    }

    deinit {
        // `InMemoryLibrary` と同じ後始末。suite はファイルとして残るので明示的に消す。
        UserDefaults().removePersistentDomain(forName: name)
    }

    /// この保存先から作った環境設定。何も書かれていなければ出荷時の既定値になる。
    func makePreferences() -> AppPreferences {
        AppPreferences(defaults: defaults)
    }

    /// この保存先に実際に書かれている値(`persistentDomain`)。
    /// `object(forKey:)` は NSGlobalDomain へ抜けることがあるため、
    /// 「この領域に書かれたか」を見るときはこちらを使う(`AppleLanguages` で実際に踏んだ)。
    var storedDomain: [String: Any] {
        UserDefaults().persistentDomain(forName: name) ?? [:]
    }
}
