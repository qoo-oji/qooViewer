import SwiftUI
import CoreGraphics

/// 実寸表示ウインドウの中身。画像を原寸大(拡大縮小なし)で表示し、
/// 画面より大きい場合はスクロールできるようにする。
struct ActualSizePageView: View {
    let image: CGImage
    var backgroundColor: Color = .black

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(decorative: image, scale: 1)
                .frame(width: CGFloat(image.width), height: CGFloat(image.height))
        }
        .background(backgroundColor)
    }
}
