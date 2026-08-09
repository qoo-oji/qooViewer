import Foundation

/// 画像のエクスポート機能(要望)。ファイルメニューの「画像のエクスポート」サブメニューから、
/// AppState.performImageExport経由でViewerViewへ橋渡しするための、この操作が指す対象。
///
/// メニューバー(QooViewerApp.swift)はクリック位置の情報を持たない(FocusedValue経由でしか
/// ViewerViewとやり取りできない)ため、単一ページ表示中は.currentPageのみを使い、見開き表示中は
/// .leftPage/.rightPageを両方とも項目として並べる(要望どおり)。
///
/// コンテキストメニュー(ViewerView.contextMenuContent)は、右クリックした位置(画面上の左半分/
/// 右半分)から対象のページ番号を自前で一意に解決できるため、この列挙は経由しない
/// (isLastContextClickOnLeftHalf参照)。
enum ImageExportKind {
    /// 単一ページ表示中の「このページをエクスポート」。
    case currentPage
    /// 見開き表示中の「左のページをエクスポート」。
    case leftPage
    /// 見開き表示中の「右のページをエクスポート」。
    case rightPage
    /// 見開き表示中の「見開きを結合してエクスポート」。
    case mergedSpread
}
