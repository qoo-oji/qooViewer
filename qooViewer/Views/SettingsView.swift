import SwiftUI

/// 環境設定ウインドウ(Cmd+, で開く)。一般設定・描画・閲覧・キー/マウス設定・アクセス権・
/// リセットのタブを持つ。以前は「一般」タブに画像描画やページ送り/スライドショーの設定も
/// 含まれていたが、項目が増えて長くなったため、「描画」(RenderingSettingsView)と
/// 「閲覧」(ReadingSettingsView)の2つのタブに分離した。
///
/// 「リセット」(ResetDataSettingsView)は、すべてのお気に入り・ブックマーク・読書履歴を
/// 強制的に削除する、非常に強力な操作専用のタブ。他のタブに混在させず独立させることで、
/// 誤って触れてしまう可能性を下げている(ユーザーからの要望)。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            RenderingSettingsView()
                .tabItem { Label("Rendering", systemImage: "paintpalette") }
            ReadingSettingsView()
                .tabItem { Label("Reading", systemImage: "book") }
            KeyBindingSettingsView()
                .tabItem { Label("Key & Mouse Bindings", systemImage: "keyboard") }
            AccessPermissionsSettingsView()
                .tabItem { Label("Access Permissions", systemImage: "lock.shield") }
            ResetDataSettingsView()
                .tabItem { Label("Reset", systemImage: "exclamationmark.triangle") }
        }
        .frame(width: 480, height: 460)
    }
}
