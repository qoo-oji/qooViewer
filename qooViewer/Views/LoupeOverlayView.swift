import AppKit
import SwiftUI

/// 拡大鏡(ルーペ)のオーバーレイ本体。マウスカーソル位置を中心に、その位置に対応する
/// 画像の一部を円形に拡大表示する。
///
/// マウス移動のたびにSwiftUIの@Stateを更新して画面を再描画すると、その積み重ねでメイン
/// スレッドを圧迫しハングしたように見えることがある(ProgressBarView.swiftの
/// onContinuousHoverのコメント参照)。拡大鏡は本質的にマウス移動のたびに再描画が必要な
/// 機能のため、この教訓を踏まえ、SwiftUIの状態更新を一切経由しない生のNSView自前描画で
/// 実装する(ClickZoneArea/PageAreaFrameAccessorが同種の理由で既に生NSViewを使っているのと
/// 同じ考え方)。
///
/// ViewerView.pageAreaのimagesRow(見開き中でも左右の画像をまとめて描画するHStack)に
/// そのまま`.overlay`として重ねて使う。imagesRow自身の実際のレイアウト後のサイズ・位置に
/// 自動的に一致する(画面に収めるモードでの中央寄せ、横幅フィット/拡大縮小しないモードでの
/// ScrollView内スクロールのどちらでも、SwiftUIのレイアウトエンジンがオーバーレイの位置・
/// サイズを画像そのものと常に一致させてくれるため、座標変換をこちら側で個別に持つ必要が無い)。
struct LoupeOverlayView: NSViewRepresentable {
    /// 見開き内のスロット列(画面上の左→右の順。ViewerView.orderedCurrentSlots参照)。
    let slots: [SpreadPageSlot]
    /// 各スロットの実際の表示幅(pt、既にrenderScale適用後)。slotsと同じ順序・要素数。
    let slotWidths: [CGFloat]
    /// スロット列に共通の表示高さ(pt、既にrenderScale適用後)。
    let contentHeight: CGFloat
    /// 拡大率(1.0 = 等倍。preferences.loupeMagnificationPercent / 100)。
    let magnification: CGFloat
    /// レンズの直径(pt)。
    let diameter: CGFloat
    /// レンズを閉じる(拡大鏡をOFFにする)ためのクロージャ。
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> LoupeNSView {
        let view = LoupeNSView()
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: LoupeNSView, context: Context) {
        nsView.slots = slots
        nsView.slotWidths = slotWidths
        nsView.contentHeight = contentHeight
        nsView.magnification = magnification
        nsView.diameter = diameter
        nsView.onDismiss = onDismiss
        // キーボードショートカットで拡大鏡をONにした直後(まだマウスを1pxも動かしていない)
        // 時点でも、現在のカーソル位置にすぐレンズが出るようにしておく。この時点ではまだ
        // AppKit側のviewDidMoveToWindow()が発火しておらずwindowがnilのことがある
        // (WindowYPositionAccessor/PageAreaFrameAccessorと同じ理由の保険)ため、
        // 次のランループでも再試行しておく。
        if nsView.hasMouseLocation == false {
            nsView.refreshMouseLocationFromScreen()
            DispatchQueue.main.async {
                if nsView.hasMouseLocation == false {
                    nsView.refreshMouseLocationFromScreen()
                }
            }
        }
        nsView.needsDisplay = true
    }
}

/// LoupeOverlayViewが実際に使うNSView本体。
final class LoupeNSView: NSView {
    var slots: [SpreadPageSlot] = []
    var slotWidths: [CGFloat] = []
    var contentHeight: CGFloat = 0
    var magnification: CGFloat = 2.5
    var diameter: CGFloat = 400
    var onDismiss: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var lastMouseLocation: CGPoint?
    var hasMouseLocation: Bool { lastMouseLocation != nil }
    /// レンズ内の描画に使う、Core Image(GPU)ベースの拡大処理(GPUImageUpscaler.swift参照)。
    /// CIContextの生成コストは高いため、draw(_:)のたびに作り直さずこのビューの寿命の間
    /// 使い回す。
    private let upscaler = GPUImageUpscaler()

    /// 座標系を、他の座標(orderedCurrentSlots由来の幅・高さ、EventのlocationInWindow等)と
    /// 同じ「原点が左上、Yが下に向かって増える」向きに揃える。
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    /// ウインドウへ実際に組み込まれたタイミング(AppKit視点で自身のconvert(_:to:)等が
    /// 使えるようになる瞬間)で、まだマウス位置を把握していなければ現在のカーソル位置を
    /// 取得しておく。updateNSView側の保険(まだwindowが無い早い段階での呼び出し)より
    /// こちらの方が確実に発火するタイミング。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !hasMouseLocation {
            refreshMouseLocationFromScreen()
        }
    }

    /// 現在のスクリーン上のカーソル位置を自身のローカル座標へ変換して反映する
    /// (LoupeOverlayView.updateNSView参照。ONにした直後、まだmouseMovedが1度も
    /// 発生していない間の初期表示のために使う)。
    func refreshMouseLocationFromScreen() {
        guard let window else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        lastMouseLocation = convert(windowPoint, from: nil)
        needsDisplay = true
    }

    // ClickZoneViewと同じ理由(既定値のacceptsFirstMouse(for:) == falseのまま)で、
    // ウインドウが非アクティブな状態での最初のクリックはウインドウをアクティブにするだけに
    // 留め、拡大鏡を閉じる動作(mouseDown/rightMouseDown)は発火させない。

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onDismiss?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let lastMouseLocation,
              let context = NSGraphicsContext.current?.cgContext,
              let source = sourcePixel(at: lastMouseLocation)
        else { return }

        let lensRect = CGRect(
            x: lastMouseLocation.x - diameter / 2,
            y: lastMouseLocation.y - diameter / 2,
            width: diameter,
            height: diameter
        )

        context.saveGState()
        context.addEllipse(in: lensRect)
        context.clip()

        context.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        context.fill(lensRect)

        // このスロットの「表示高さ ÷ 画像本来のピクセル高さ」に、環境設定の拡大率を
        // 掛けたものが、このレンズが実際に画像を描画するときの倍率になる(見開き内で左右の
        // 画像のピクセル解像度が異なる場合でも、画面上に表示されている見た目の大きさを
        // 基準に一貫した拡大率になる)。
        let totalZoom = source.slotDisplayScale * magnification
        // レンズの直径(画面上のpt)を倍率で割り戻した、画像本来のピクセル空間で実際に必要な
        // クロップ範囲(正方形の一辺)。レンズの見た目の大きさによらず、実際にサンプリングする
        // 元画像の範囲はごく小さい(数百px四方程度)ため、ページ全体には重すぎるCore Imageの
        // 高品質補間(Lanczos、GPU)でも、この範囲に限定すればマウス移動のたびに実行して
        // 十分な速度で行える(GPUImageUpscaler.swift参照)。
        let cropSize = diameter / totalZoom
        if let upscaled = upscaler.upscaledCrop(
            from: source.image,
            centerPixel: source.pixel,
            cropSize: cropSize,
            targetSize: diameter
        ) {
            let resultSize = CGSize(width: upscaled.width, height: upscaled.height)
            let drawOrigin = CGPoint(
                x: lastMouseLocation.x - resultSize.width / 2,
                y: lastMouseLocation.y - resultSize.height / 2
            )
            // CGContext.draw(_:in:)は、このビューがisFlipped(Y下向き)であっても、画像データの
            // 先頭行(画像の視覚的な上端)をrectの「Yが大きい側」に描画するという、Core Graphicsの
            // 低レベルAPI特有の挙動がある(NSImage.draw(in:)のような高レベルAPIとは異なり、
            // isFlippedに応じた自動補正が効かない。Core Imageで生成したCGImageでも同様。
            // 実機検証で確認済み)。そのため描画直前だけこのビュー自身の反転を打ち消す
            // ローカルな変換をかけ、向きを正しくしてから描画する。
            context.saveGState()
            context.translateBy(x: 0, y: drawOrigin.y + resultSize.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(upscaled, in: CGRect(x: drawOrigin.x, y: 0, width: resultSize.width, height: resultSize.height))
            context.restoreGState()
        }

        context.restoreGState()

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: 6,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
        )
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: lensRect.insetBy(dx: 1, dy: 1))
        context.restoreGState()
    }

    /// レンズの中心(このビューのローカル座標)から、対象スロットの画像・そのスロットの
    /// 表示倍率(スロットの表示高さ ÷ 画像本来のピクセル高さ)・画像内のピクセル座標を求める。
    /// EPUBの空白スロット(SpreadPageSlot.blank)上、またはスロット列の外(見開きの外側の
    /// 余白など)の場合はnilを返す(この回はレンズを描画しない)。
    private func sourcePixel(
        at location: CGPoint
    ) -> (image: CGImage, slotDisplayScale: CGFloat, pixel: CGPoint)? {
        guard contentHeight > 0, location.y >= 0, location.y <= contentHeight else { return nil }
        var localX = location.x
        for (index, width) in slotWidths.enumerated() {
            guard width > 0 else { continue }
            if localX >= 0, localX <= width {
                guard index < slots.count, case .image(let image) = slots[index], image.height > 0 else {
                    return nil
                }
                let slotDisplayScale = contentHeight / CGFloat(image.height)
                let pixel = CGPoint(
                    x: (localX / width) * CGFloat(image.width),
                    y: (location.y / contentHeight) * CGFloat(image.height)
                )
                return (image, slotDisplayScale, pixel)
            }
            localX -= width
        }
        return nil
    }
}
