import SwiftUI
import AppKit

/// 同じ行に並べるボタンの幅を揃えるための、ラベル文字列からの幅の見積もり
/// (ユーザー要望: 「ボタンの幅は３つとも揃えること」「ボタン幅は初期化ボタンと揃えること」)。
///
/// 前者の「3つとも揃えること」はメタデータ編集ウインドウ上部に並べていた3つのボタンへの要望
/// だった(そのボタン群と、3つのフォーマット編集ダイアログは 2026-09-21 に qooMeta の規則の窓へ置き換えて廃止)。
/// 今はほかの一覧ウインドウ・シートのボタンの組が使う。
///
/// `.frame(maxWidth: .infinity)`で揃える方法もあるが、それだと親の幅いっぱいまで
/// 引き伸ばされてしまい、ウインドウ幅によってボタンが不自然に間延びする。
/// ExportColumnWidthEstimatorと同じくNSStringの実測を使い、「一番長いラベルが
/// 収まる幅」を求めて全ボタンへ同じ値を指定する。
enum MetadataButtonWidthEstimator {
    /// ボタンのラベル以外に必要な左右の余白(macOSの標準ボタンのパディング相当)。
    static let chrome: CGFloat = 34
    /// `.controlSize(.small)`のボタン用の余白。標準サイズよりベゼルの左右が詰まる
    /// (実機のスクリーンショットを実測して合わせた値)。
    static let smallChrome: CGFloat = 16

    /// フォントと余白を差し替えられるようにしてあるのは、小さいサイズのボタン
    /// (メタデータ編集ウインドウの登録/削除ボタン)の列幅も同じ見積もりで求めるため。
    static func equalWidth(
        for labels: [String],
        minWidth: CGFloat = 120,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        chrome: CGFloat = MetadataButtonWidthEstimator.chrome
    ) -> CGFloat {
        let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(minWidth, (widest + chrome).rounded(.up))
    }
}
