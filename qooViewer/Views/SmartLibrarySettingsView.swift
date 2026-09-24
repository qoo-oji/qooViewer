import SwiftUI

/// 環境設定ウインドウの「スマートライブラリ」画面(2026-09-23、利用者の要望)。
///
/// 項目は「カバーの形」「形の合わせ方」「切り取るときに残す位置」と「先頭の著者だけを使う」。機能そのものの ON/OFF(「スマートライブラリを有効にする」)は、ライブラリ・
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
                    help: "The shape of the covers in the smart library’s icon view. Match the Image shows each cover whole, in its own shape, inside a portrait (2:3) frame. With the other shapes, Fit to Shape decides what happens to a cover that doesn’t match."
                )
                // ライブラリの「形の合わせ方」を持ち込んだもの(2026-09-24、利用者の要望。CoverFit)。「実際の画像に合わせる」は
                // もともと切らないので押せない。
                SettingsPicker(
                    "Fit to Shape",
                    selection: $preferences.smartLibraryCoverFit,
                    help: "What to do with a cover whose proportions differ from the shape above. Crop to Fill fills the frame and crops what doesn’t fit. Add Margins shows the whole cover centered in the frame, with margins above and below or on both sides. By Orientation crops covers that face the same way as the shape (portrait or landscape) and adds margins to the others; it isn’t available for Square. Has no effect with Match the Image.",
                    // 正方形では「向きで切り替える」を選べない(CoverFit.byOrientation)。形を正方形にしたときの値の戻しは
                    // AppPreferences.smartLibraryCoverShape が持つ。
                    isOptionShown: { option in
                        option != .byOrientation || preferences.smartLibraryCoverShape.cropAspect
                            .map(CoverFit.allowsByOrientation(frameAspect:)) ?? true
                    }
                )
                .disabled(preferences.smartLibraryCoverShape == .matchImage)
                // ライブラリの「切り取るときに残す位置」を持ち込んだもの(2026-09-23、利用者の要望)。本ごとの指定(メタデータの編集
                // シートの表紙の右クリック)があればそちらが勝つ。切らない形・余白を付ける間は効かないので押せない。
                SettingsPicker(
                    "Keep When Cropping",
                    selection: $preferences.smartLibraryCoverCropAnchor,
                    help: "Which part of a cover to keep when it’s cropped to the shape above. A book can have its own setting: right-click its cover in Edit Metadata. Has no effect with Match the Image or Add Margins."
                )
                .disabled(preferences.smartLibraryCoverShape == .matchImage || preferences.smartLibraryCoverFit == .pad)
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
