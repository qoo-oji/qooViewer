import Combine
import SwiftUI
import CoreGraphics

/// 実寸表示ウインドウの中身。画像を原寸大(拡大縮小なし)で表示し、
/// 画面より大きい場合はスクロールできるようにする。
struct ActualSizePageView: View {
    let image: CGImage
    var backgroundColor: Color = .black
    /// 表示言語の変化(`AppPreferences.$displayLanguage`)と、変わったときに窓の題を付け直す閉包(2026-10-04 の監査 M-7)。
    /// 窓は SwiftUI のシーンでなく `NSWindow` を直に作っている(ViewerView.showActualSizeWindow)ので、題は開いたときの言語のまま
    /// 残っていた。閉包は窓を弱く持つこと(この中身は窓が持つ)。
    var displayLanguageChanges: AnyPublisher<AppLanguage, Never>?
    var onDisplayLanguageChange: ((AppLanguage) -> Void)?

    /// リソースモニタの「メモリ」の内訳への届け出(MemoryUsageRegistry)。画像は表示用とは別に元の大きさで読み直したもので、
    /// 窓を閉じるまで残る(2026-10-11 のリソースモニタの点検。以前はどこにも出ていなかった)。窓が消えれば中身ごと解放され、
    /// 届け出も外れる(onDisappear と、取りこぼしても deinit)。
    @State private var memoryRegistration = MemoryUsageRegistration()

    var body: some View {
        // ■ 画像がウインドウより小さいときは中央に置く(2026-09-18、macOS 27 で実測)
        // 縦横どちらにもスクロールする`ScrollView`は、中身が表示域より小さいとき、macOS 26 までは中央に、
        // macOS 27 SDK + macOS 27 では**左上**に置く(リリースノート 171755081)。ウインドウを画像より大きく
        // 広げると、画像が左上に寄って右と下に余白が付いていた。中身の最小の大きさを表示域に合わせ、その中央へ
        // 画像を置いておけば、OS の既定に依らず中央になる。画像のほうが大きいときはこの指定は効かず、
        // これまでどおり画像の大きさでスクロールする。
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                Image(decorative: image, scale: 1)
                    .frame(width: CGFloat(image.width), height: CGFloat(image.height))
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
        }
        .background(backgroundColor)
        .onReceive(displayLanguageChanges ?? Empty().eraseToAnyPublisher()) { language in
            onDisplayLanguageChange?(language)
        }
        .onAppear {
            let bytes = image.bytesPerRow * image.height
            memoryRegistration.activate(in: MemoryUsageRegistry.forCurrentProcess, role: .actualSize) {
                [MemoryUsageItem(kind: .actualSizeImage, usedBytes: bytes, count: 1)]
            }
        }
        .onDisappear { memoryRegistration.end() }
    }
}
