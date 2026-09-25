import Foundation
import SwiftUI

@testable import qooViewer

// MARK: - すべての設定を総なめにする

/// `AppPreferences`(または `AppearanceSettings`)のすべての `@Published` プロパティを「プロパティ名 → 文字列」に写し取る。
///
/// **Mirror で総なめにしているのが要**。設定を 1 つ足したときに、テスト側の書き写しが古いまま
/// 静かに素通りする(その項目だけ確認されない)のを防ぐため ―― 新しい設定はここに自動で載り、
/// 下の `mutateEverySetting` へ足し忘れていれば
/// `AppPreferencesTests.mutationTouchesEverySetting` がその名前を挙げて落ちる。
@MainActor
func settingsSnapshot(of preferences: some AnyObject) -> [String: String] {
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
    p.offersRemovingMissingCollectionBooks.toggle()
    p.libraryFeatureEnabled.toggle()
    p.smartLibraryFeatureEnabled.toggle()
    p.smartLibraryUsesFirstAuthorOnly.toggle()
    p.smartLibraryCoverShape = otherCase(p.smartLibraryCoverShape)
    p.smartLibraryCoverCropAnchor = otherCase(p.smartLibraryCoverCropAnchor)
    p.smartLibraryCoverFit = otherCase(p.smartLibraryCoverFit)
    p.fileBrowserFeatureEnabled.toggle()
    p.showRecentFavoritesOnWelcome.toggle()
    p.sidePanelFeatureEnabled.toggle()
    p.sidePanelPosition = otherCase(p.sidePanelPosition)
    p.sidePanelUsesDoubleClick.toggle()
    p.sidePanelSortOrder = otherCase(p.sidePanelSortOrder)
    p.siblingNavigationFollowsBrowserSort.toggle()

    // MARK: ファイルブラウザ
    p.fileBrowserStartupLocation = otherCase(p.fileBrowserStartupLocation)
    p.fileBrowserStartupFavoriteID += "-moved"
    p.fileBrowserFoldersFirst.toggle()
    p.fileBrowserExternalDropAction = otherCase(p.fileBrowserExternalDropAction)
    p.fileBrowserExpandsTreeToCurrentFolder.toggle()
    p.fileBrowserTreeFollowsListSort.toggle()
    p.fileBrowserCompressionFormat = otherCase(p.fileBrowserCompressionFormat)
    p.fileBrowserRevealDestination = otherCase(p.fileBrowserRevealDestination)
    p.fileBrowserVideoThumbnailsEnabled.toggle()
    p.fileBrowserReadOnly.toggle()
    p.fileBrowserImageFolderOpenAction = otherCase(p.fileBrowserImageFolderOpenAction)

    // MARK: 外観(揃いごとの設定は mutateEveryAppearanceSetting。シークレットの揃いは AppearanceSettingsTests が見る)
    mutateEveryAppearanceSetting(p.appearance)
    p.privateWindowsUseOwnAppearance.toggle()
    // 既定は nil(= 表示言語に合わせた「(シークレット)」)。文字を入れれば動いたことになる。
    p.privateWindowTitlePrefix = (p.privateWindowTitlePrefix ?? "") + "🕶️"

    // MARK: 本を開く
    p.reopenBehavior = otherCase(p.reopenBehavior)
    p.finderOpenBehavior = otherCase(p.finderOpenBehavior)
    p.favoriteOpenBehavior = otherCase(p.favoriteOpenBehavior)
    p.spreadBookmarkTargetBehavior = otherCase(p.spreadBookmarkTargetBehavior)
    p.defaultReadingDirectionSetting = otherCase(p.defaultReadingDirectionSetting)

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
    // 範囲(0〜1 秒)の中で動かす。読み直すと範囲へ収める(AppPreferences.storedDouble)ので、外へ出すと往復で変わる。
    p.thumbnailHoverPreviewDelay = p.thumbnailHoverPreviewDelay == 0.5 ? 0.6 : 0.5
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
    p.fileBrowserThumbnailCacheEnabled.toggle()
    p.fileBrowserThumbnailCacheLimitMB += 1

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
}

/// 外観の揃い(AppearanceSettings)のすべての設定を、出荷時の既定値とは違う値へ動かす。
/// **設定を 1 つ足したらここにも足すこと** ―― 足し忘れは AppearanceSettingsTests が名前を挙げて教える。
@MainActor
func mutateEveryAppearanceSetting(_ a: AppearanceSettings) {
    a.appAppearance = otherCase(a.appAppearance)
    a.backgroundColorOption = otherCase(a.backgroundColorOption)
    a.customBackgroundColor = otherColor(a.customBackgroundColor)
    a.thumbnailGridCellSize += 1
    a.thumbnailGridHorizontalSpacing += 1
    a.thumbnailGridVerticalSpacing += 1
    a.thumbnailGridHorizontalMarginPercent += 1
    a.thumbnailGridVerticalMarginPercent += 1
    a.thumbnailGridCaptionStyle = otherCase(a.thumbnailGridCaptionStyle)
    a.thumbnailGridCaptionFontSize += 1
    a.thumbnailGridBorderColorOption = otherCase(a.thumbnailGridBorderColorOption)
    a.thumbnailGridBorderCustomColor = otherColor(a.thumbnailGridBorderCustomColor)
    a.thumbnailGridWheelScrollRows += 1
    a.showThumbnailHoverPreview.toggle()
    a.showProgressBarThumbnailPreview.toggle()
    a.filmstripThumbnailCount += 1
    a.filmstripCaptionStyle = otherCase(a.filmstripCaptionStyle)
    a.filmstripFontSize += 1
    a.filmstripDimsOtherPages.toggle()
    a.filmstripHighlightColorOption = otherCase(a.filmstripHighlightColorOption)
    a.filmstripHighlightCustomColor = otherColor(a.filmstripHighlightCustomColor)
    a.filmstripHighlightBorderWidth += 1
    a.toolbarRevealDelay += 1
    a.progressBarRevealDelay += 1
    a.sidePanelRevealDelay += 1
    a.toolbarDockedGlass.toggle()
    a.progressBarDockedGlass.toggle()
    a.sidePanelDockedGlass.toggle()
    a.welcomeGlass.toggle()
    a.collectionCoverCaptionStyle = otherCase(a.collectionCoverCaptionStyle)
    a.collectionCoverCaptionFontSize += 1
    a.collectionTileNameFontSize += 1
    a.collectionTileBadgeSize = otherCase(a.collectionTileBadgeSize)
    // 既定は nil(= 外観に追従する薄い地)なので、色を1つ入れれば動いたことになる。
    a.collectionTileBackgroundColor = a.collectionTileBackgroundColor.map(otherColor)
        ?? RGBColorValue(red: 20, green: 30, blue: 60)
    a.smartLibraryCaptionFontSize += 1
    a.smartLibraryBadgeSize = otherCase(a.smartLibraryBadgeSize)
    a.homeListWheelScrollRows += 1
    a.homeGridWheelScrollRows += 1
    a.smartLibrarySeriesSheetColor = a.smartLibrarySeriesSheetColor.map(otherColor)
        ?? RGBColorValue(red: 30, green: 60, blue: 20)
    // 既定は nil(= 白)。
    a.collectionCoverMarginColor = otherColor(a.collectionCoverMarginColor ?? AppearanceSettings.defaultCoverMarginRGB)
    a.smartLibraryCoverMarginColor = otherColor(a.smartLibraryCoverMarginColor ?? AppearanceSettings.defaultCoverMarginRGB)
    // 既定は nil(= システムの標準のタイトルバー)。札の地の色と同じ。
    a.titleBarColor = a.titleBarColor.map(otherColor) ?? RGBColorValue(red: 60, green: 20, blue: 30)
    for surface in PanelSurface.allCases {
        a.setSurfaceStyle(otherStyle(a.surfaceStyle(for: surface)), for: surface)
    }
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
