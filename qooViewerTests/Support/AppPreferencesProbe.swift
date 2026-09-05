import Foundation
import SwiftUI

@testable import qooViewer

// MARK: - すべての設定を総なめにする

/// `AppPreferences` のすべての `@Published` プロパティを「プロパティ名 → 文字列」に写し取る。
///
/// **Mirror で総なめにしているのが要**。設定を 1 つ足したときに、テスト側の書き写しが古いまま
/// 静かに素通りする(その項目だけ確認されない)のを防ぐため ―― 新しい設定はここに自動で載り、
/// 下の `mutateEverySetting` へ足し忘れていれば
/// `AppPreferencesTests.mutationTouchesEverySetting` がその名前を挙げて落ちる。
@MainActor
func settingsSnapshot(of preferences: AppPreferences) -> [String: String] {
    var result: [String: String] = [:]
    for child in Mirror(reflecting: preferences).children {
        // `@Published var x` の実体は `_x: Published<T>`。それ以外の格納プロパティ
        // (`defaults` など)は設定ではないので見ない。
        guard let label = child.label, label.hasPrefix("_") else { continue }
        guard
            let storage = Mirror(reflecting: child.value).children
                .first(where: { $0.label == "storage" }),
            // `Published.storage` は `.value(T)` か `.publisher(...)` の列挙。`$x` を購読すると
            // 後者へ移る(そうなると値が取り出せない)。テストは購読しないので必ず前者。
            let payload = Mirror(reflecting: storage.value).children.first,
            payload.label == "value"
        else { continue }
        result[String(label.dropFirst())] = stableDescription(payload.value)
    }
    return result
}

/// 辞書の `description` は要素の順序が実行ごとに変わるため、要素を並べ替えてから文字列にする。
private func stableDescription(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .dictionary, .set:
        return mirror.children.map { String(describing: $0.value) }.sorted().joined(separator: " / ")
    default:
        return String(describing: value)
    }
}

// MARK: - すべての設定を既定値から動かす

/// すべての設定を、出荷時の既定値とは違う値へ動かす。
///
/// 「初期設定に戻す」の網羅(`keys(for:)` と `apply(_:for:)` の両方に足したか)を確かめるための
/// 下ごしらえ。**設定を 1 つ足したらここにも足すこと** ―― 足し忘れは
/// `AppPreferencesTests.mutationTouchesEverySetting` が名前を挙げて教える。
@MainActor
func mutateEverySetting(_ p: AppPreferences) {
    // MARK: 一般
    p.launchOpensLastBook.toggle()
    p.launchFullScreen.toggle()
    p.launchInPrivateMode.toggle()
    p.quitWhenLastWindowClosed.toggle()
    p.confirmBeforeClosingMultipleTabsWindow.toggle()
    p.displayLanguage = otherCase(p.displayLanguage)
    p.maxTrackedBooksCount += 1
    p.recentFilesLimit += 1
    p.showRecentFilesOnWelcome.toggle()
    p.showRecentFavoritesOnWelcome.toggle()
    p.sidePanelFeatureEnabled.toggle()
    p.sidePanelPosition = otherCase(p.sidePanelPosition)
    p.sidePanelUsesDoubleClick.toggle()
    p.sidePanelSortOrder = otherCase(p.sidePanelSortOrder)
    p.siblingNavigationFollowsBrowserSort.toggle()
    p.usesFinderSortOrder.toggle()

    // MARK: 外観
    p.appAppearance = otherCase(p.appAppearance)
    p.backgroundColorOption = otherCase(p.backgroundColorOption)
    p.customBackgroundColor = otherColor(p.customBackgroundColor)
    p.thumbnailGridCellSize += 1
    p.thumbnailGridHorizontalSpacing += 1
    p.thumbnailGridVerticalSpacing += 1
    p.thumbnailGridHorizontalMarginPercent += 1
    p.thumbnailGridVerticalMarginPercent += 1
    p.thumbnailGridCaptionStyle = otherCase(p.thumbnailGridCaptionStyle)
    p.thumbnailGridCaptionFontSize += 1
    p.thumbnailGridBorderColorOption = otherCase(p.thumbnailGridBorderColorOption)
    p.thumbnailGridBorderCustomColor = otherColor(p.thumbnailGridBorderCustomColor)
    p.thumbnailGridWheelScrollRows += 1
    p.showThumbnailHoverPreview.toggle()
    p.showProgressBarThumbnailPreview.toggle()
    p.filmstripThumbnailCount += 1
    p.filmstripCaptionStyle = otherCase(p.filmstripCaptionStyle)
    p.filmstripFontSize += 1
    p.filmstripDimsOtherPages.toggle()
    p.filmstripHighlightColorOption = otherCase(p.filmstripHighlightColorOption)
    p.filmstripHighlightCustomColor = otherColor(p.filmstripHighlightCustomColor)
    p.filmstripHighlightBorderWidth += 1
    p.toolbarRevealDelay += 1
    p.progressBarRevealDelay += 1
    p.sidePanelRevealDelay += 1
    p.toolbarDockedGlass.toggle()
    p.progressBarDockedGlass.toggle()
    p.sidePanelDockedGlass.toggle()
    p.welcomeGlass.toggle()
    for surface in PanelSurface.allCases {
        p.setSurfaceStyle(otherStyle(p.surfaceStyle(for: surface)), for: surface)
    }

    // MARK: 本を開く
    p.reopenBehavior = otherCase(p.reopenBehavior)
    p.finderOpenBehavior = otherCase(p.finderOpenBehavior)
    p.favoriteOpenBehavior = otherCase(p.favoriteOpenBehavior)
    p.spreadBookmarkTargetBehavior = otherCase(p.spreadBookmarkTargetBehavior)

    // MARK: 画像の見え方
    p.defaultScalingMode = otherCase(p.defaultScalingMode)
    p.maxUpscalePercent += 1
    p.maxPinchZoomPercent += 1
    p.interpolationQuality = otherCase(p.interpolationQuality)
    p.loupeMagnificationPercent += 1
    p.loupeDiameter += 1
    p.singlePageAspectRatioThreshold += 1

    // MARK: 閲覧中の動作
    p.firstPageBehavior = otherCase(p.firstPageBehavior)
    p.lastPageBehavior = otherCase(p.lastPageBehavior)
    p.treatTrackpadFlickAsWheel.toggle()
    p.invertTwoFingerScrolling.toggle()
    p.thumbnailHoverPreviewDelay += 1
    p.thumbnailHoverPreviewSize += 1
    p.slideshowInterval += 1
    p.autoHideCursor.toggle()
    p.cursorAutoHideDelay += 1

    // MARK: キャッシュ
    p.pageImageCacheLimitMB += 1
    p.nestedArchiveMemoryLimitMB += 1
    p.prefetchPageCount += 1
    p.preloadThumbnailGridPreviews.toggle()
    p.thumbnailDiskCacheEnabled.toggle()
    p.thumbnailDiskCacheLimitMB += 1

    // MARK: レイアウトと書き出し
    p.missingLayoutAutoLayout = otherCase(p.missingLayoutAutoLayout)
    p.bookExportCompletionBehavior = otherCase(p.bookExportCompletionBehavior)
    p.bookExportWritesVolumeElement.toggle()
    for format in BookExportFormat.allCases {
        p.setBookExportDestinationMode(otherCase(p.bookExportDestinationMode(for: format)), for: format)
        p.bookExportDataCleanupBinding(for: format).wrappedValue =
            otherCase(p.bookExportDataCleanup(for: format))
        p.bookExportHistoryCleanupBinding(for: format).wrappedValue =
            otherCase(p.bookExportHistoryCleanup(for: format))
        p.bookExportRenumbersImagesBinding(for: format).wrappedValue.toggle()
        p.bookExportIncludesExcludedPagesBinding(for: format).wrappedValue.toggle()
    }

    // MARK: 環境設定の画面には無い(「表示」メニューやパネル自身が変える)設定
    p.hideToolbar.toggle()
    p.hideProgressBar.toggle()
    p.hideSidePanel.toggle()
    p.sidePanelWidth += 1
    p.sidePanelMode = otherCase(p.sidePanelMode)
    p.folderBrowserSortKey = otherCase(p.folderBrowserSortKey)
    p.folderBrowserSortDirection = otherCase(p.folderBrowserSortDirection)
    p.defaultReadingDirection = otherCase(p.defaultReadingDirection)
}

/// いまの値とは違う case。
@MainActor
func otherCase<T: CaseIterable & Equatable>(_ current: T) -> T {
    T.allCases.first { $0 != current } ?? current
}

private func otherColor(_ current: RGBColorValue) -> RGBColorValue {
    let candidate = RGBColorValue(red: 12, green: 34, blue: 56)
    let alternate = RGBColorValue(red: 210, green: 180, blue: 140)
    return current == candidate ? alternate : candidate
}

private func otherStyle(_ current: PanelSurfaceStyle) -> PanelSurfaceStyle {
    PanelSurfaceStyle(
        materialOpacity: current.materialOpacity == 0.5 ? 0.25 : 0.5,
        tintColor: otherColor(current.tintColor),
        tintOpacity: current.tintOpacity == 0.75 ? 0.4 : 0.75,
        contentShadowLevel: current.contentShadowLevel == 3 ? 4 : 3
    )
}
