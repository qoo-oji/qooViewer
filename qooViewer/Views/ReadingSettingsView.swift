import SwiftUI
import Foundation

/// 環境設定ウインドウの「閲覧中の動作」画面。ページ送り・スライドショー・マウスカーソルの
/// 自動非表示など、画像そのものの描画内容ではなく閲覧中の操作・挙動に関する設定をまとめる。
struct ReadingSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsPaneContainer {
            Section {
                // 説明文はラベルの言い換えだったので落とした。
                // 「前のページへ」「次のページへ」は物語的な向きで、右開きの本で画面右の
                // ページへ進む操作なども含む(FirstPageBehavior/LastPageBehavior参照)。
                SettingsPicker("At the First Page", selection: $preferences.firstPageBehavior)
                SettingsPicker(
                    "At the Last Page", selection: $preferences.lastPageBehavior,
                    help: "“Close Book” closes this tab (the window too, if it is the only tab). “Return to Welcome Screen” keeps the window open."
                )
                SettingsToggle(
                    "Trackpad Flicks Turn Pages",
                    isOn: $preferences.treatTrackpadFlickAsWheel
                )
            } header: {
                Text("Page Turning")
            }

            Section {
                SettingsToggle(
                    "Invert Two-Finger Scrolling",
                    isOn: $preferences.invertTwoFingerScrolling,
                    help: "Reverses the direction the image moves — both vertically and horizontally — when you scroll with two fingers on a trackpad. The mouse wheel is not affected, and neither are the actions assigned to wheel or flick directions."
                )
            } header: {
                Text("Scrolling")
            }

            // プログレスバーのフィルムストリップの設定(ON/OFFも含めて)は、環境設定「外観」の
            // 「プログレスバーのフィルムストリップ」セクションへ移した ―― 枚数・文字の大きさ・
            // 強調の色と太さを足すにあたって、ON/OFFだけをこの画面に残すと
            // 「どれがどこに効くのか分からない」状態になるため(ページ一覧の拡大プレビューを
            // 「外観」へ移したときと同じ理由。AppPreferences.showProgressBarThumbnailPreviewの
            // コメント参照)。

            // ページ一覧(サムネイルグリッド)にしか効かない設定は、見た目(サムネイルの
            // 大きさ・間隔・余白・キャプション・枠の色)も、拡大プレビューのON/OFF・先読みも、
            // ホイール1ノッチのスクロール行数も、すべて「外観」画面の「ページ一覧」セクションへ
            // 集めてある。この画面に残しているのは**効く範囲が「すべての場所」のものだけ**。
            //
            // この切り分けはユーザーの指摘による(1つの見出しの下に、ページ一覧だけに効く項目と
            // 全箇所共通の項目が混ざっていて、どれがどこに効くのか分からない)。
            // **効く範囲が同じものだけを1つの見出しの下に置く**、という基準にしてある。
            // サムネイルのホバー拡大プレビューのうち、**4箇所すべてに共通で効くもの**だけを
            // ここに置く(ページ一覧・サイドパネルのページモード・ブックマーク/レイアウトの編集・
            // 書き出しウインドウ)。ページ一覧にしか効かないものは「外観」画面の
            // 「ページ一覧」セクションにある(すぐ上のコメント参照)。
            Section {
                SettingsSlider(
                    "Delay Before Showing",
                    value: $preferences.thumbnailHoverPreviewDelay,
                    in: AppPreferences.thumbnailHoverPreviewDelayRange,
                    step: 0.05,
                    help: "Applies to thumbnails in the page list, the side panel's page mode, the bookmark editor, and the export windows."
                ) { value in
                    String(format: "%.2f s", value)
                }
                // 大きさも遅延と同じく4箇所すべてで共通(ユーザーの指示)。既定値は、設定に
                // する前から各所に書かれていた440ptをそのまま引き継いでいる。
                SettingsSlider(
                    "Preview Size",
                    value: $preferences.thumbnailHoverPreviewSize,
                    in: AppPreferences.thumbnailHoverPreviewSizeRange,
                    step: 20,
                    help: "Applies to thumbnails in the page list, the side panel's page mode, the bookmark editor, and the export windows."
                ) { value in
                    "\(Int(value)) pt"
                }
            } header: {
                Text("Thumbnail Preview")
            }

            Section {
                // ユーザー要望: 特に10秒未満のときに0.1秒単位で詰めたい。
                // 0.1秒刻みだとスライダーの1ステップが1pt未満になり、ドラッグでは狙った値に
                // 止められないため、ステッパーを添えてある(SettingsSlider.showsStepper参照)。
                // 下限を1秒から0.5秒へ下げたのは、0.1秒単位で詰めたいのは短い側だという
                // 要望の趣旨に沿わせるため。
                //
                // スライダー本体だけ0.5秒刻みにしている。`Slider`は刻みの数だけ目盛りを描くので、
                // 0.1秒刻みのままだと295本が潰れて**1本の直線に見えていた**(ユーザー報告)。
                // ドラッグで0.1秒を狙えないのは元々承知の上でステッパーを添えているので、
                // 目盛りは読み取れる粗さにして、細かい調整はステッパーへ任せる。
                SettingsSlider(
                    "Interval",
                    value: $preferences.slideshowInterval,
                    in: 0.5...30,
                    step: 0.1,
                    showsStepper: true,
                    sliderStep: 0.5
                ) { value in
                    String(format: "%.1f s", value)
                }
            } header: {
                Text("Slideshow")
            }

            Section {
                // 「自動的に」が何を指すのか(=動かしていないあいだ)をラベルへ入れて、
                // 言い換えでしかなかった説明文を無くした。
                SettingsToggle(
                    "Hide the Pointer While You Are Not Moving It",
                    isOn: $preferences.autoHideCursor
                )
                SettingsSlider(
                    "Delay Before Hiding",
                    value: $preferences.cursorAutoHideDelay,
                    in: 0.5...10,
                    step: 0.5
                ) { value in
                    String(format: "%.1f s", value)
                }
                .disabled(!preferences.autoHideCursor)
            } header: {
                Text("Pointer")
            }

            SettingsResetSection(
                help: "Restores every setting on this page. Other pages, and your favorites, bookmarks and reading history, are not affected."
            ) {
                preferences.resetToDefaults(.reading)
            }
        }
    }
}
