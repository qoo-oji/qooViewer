import SwiftUI

/// 環境設定ウインドウの「スマートライブラリ」画面(2026-09-23、利用者の要望)。
///
/// 項目は「表紙の形」と「先頭の著者だけを使う」。機能そのものの ON/OFF(「スマートライブラリを有効にする」)は、ライブラリ・
/// ファイルブラウザと並べて「一般」に残してある(`SettingsPane.smartLibrary` のコメント)。OFF の間もこの画面の設定は
/// 変えられる(変えても何も動かず、ON に戻したときに効く)。
struct SmartLibrarySettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsPaneContainer {
            // 2026-09-23、利用者の要望(ライブラリの「カバーの形」を持ち込む。SmartLibraryCoverShape)。
            Section {
                SettingsPicker(
                    "Cover Shape",
                    selection: $preferences.smartLibraryCoverShape,
                    help: "The shape of the covers in the smart library’s icon view. Match the Image shows each cover whole, in its own shape, inside a portrait (2:3) frame. The other shapes fill the frame with the cover and crop what doesn’t fit, keeping the center."
                )
            } header: {
                Text("Icon View")
            }

            Section {
                SettingsToggle(
                    "Use Only the First Author",
                    isOn: $preferences.smartLibraryUsesFirstAuthorOnly,
                    help: "Books with more than one author are treated as if they had only the first one: in the Authors metadata button, smart collection conditions, search, sorting and the Authors column of the list. The books’ metadata isn’t changed. Group by Author always uses the first author."
                )
            } header: {
                Text("Authors")
            }

            SettingsResetSection(
                help: "Restores every setting on this page. Your target folders and smart collections are not affected."
            ) {
                preferences.resetToDefaults(.smartLibrary)
            }
        }
    }
}
