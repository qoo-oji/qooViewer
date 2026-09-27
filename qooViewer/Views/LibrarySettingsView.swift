import SwiftUI

/// 環境設定ウインドウの「ライブラリ」画面(2026-09-27、利用者の指示)。
///
/// 「一般」の「ホーム」を大きな機能の ON/OFF だけにするため、そこにあった 2 項目をここへ移した。ファイルブラウザ・
/// スマートライブラリがそれぞれ画面を持っているのに揃えた(`SettingsPane.library` のコメント)。機能そのものの ON/OFF
/// (「ライブラリを有効にする」)は、ほかの 2 つと並べて「一般」に残してある。
///
/// 並びは、より根本的なものから(docs/09「項目の置き場所と並び」): クリックの意味(ホームの一覧を使うときの操作そのもの)→
/// 起動時の確認。
struct LibrarySettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsPaneContainer {
            Section {
                // 2026-09-27、利用者の決定(ホームの操作の統一)。既定はクリックで選び、ダブルクリックで開く(Finder と同じ)。
                // スマートライブラリにも効くが、コレクションが主な相手なのでこの画面に置く(吹き出しで両方に効くと言う)。
                // ライブラリもスマートライブラリも OFF の間は効かない(AppPreferences.homeOpensWithSingleClick)。
                SettingsToggle(
                    "Open Items with a Single Click",
                    isOn: $preferences.homeOpensWithSingleClick,
                    help: "Applies to collections and their books, and to the smart library. When on, a click opens the item; select with Command-click, Shift-click, dragging from an empty area, or the arrow keys. When off, a click selects and a double-click opens. The file browser always works like the Finder."
                )
                .disabled(!preferences.libraryFeatureEnabled && !preferences.smartLibraryFeatureEnabled)
            } header: {
                Text("Clicking")
            }

            Section {
                // ユーザー要望 2026-09-10。勝手に消す設定ではなく「起動時に一覧を出して尋ねる」
                // 設定なので、ラベルも Offer(尋ねる)にしてある。何を対象にするか
                // (外付けを外しているだけの本は対象外)は吹き出しへ。
                // ライブラリ機能がOFFの間は効かない設定なので無効にする。
                SettingsToggle(
                    "Offer to Remove Books That Are No Longer There",
                    isOn: $preferences.offersRemovingMissingCollectionBooks,
                    help: "At launch, lists the books in your collections whose file is gone even though the volume it was on is connected, and asks whether to remove them. Books on a volume you have disconnected are never listed, and nothing is removed until you choose Remove. A collection whose every book is gone is removed along with them."
                )
                .disabled(!preferences.libraryFeatureEnabled)
            } header: {
                Text("On Launch")
            }

            SettingsResetSection(
                help: "Restores every setting on this page. Your libraries and collections are not affected."
            ) {
                preferences.resetToDefaults(.library)
            }
        }
    }
}
