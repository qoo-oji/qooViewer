import SwiftUI

/// 環境設定ウインドウ(Cmd+, で開く)。一般設定・描画・閲覧・キー/マウス設定・アクセス権の
/// タブを持つ。以前は「一般」タブに画像描画やページ送り/スライドショーの設定も含まれていたが、
/// 項目が増えて長くなったため、「描画」(RenderingSettingsView)と「閲覧」(ReadingSettingsView)
/// の2つのタブに分離した。
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
        }
        .frame(width: 480, height: 460)
    }
}
