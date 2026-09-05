import Foundation
import Testing

@testable import qooViewer

/// アプリ全体の環境設定(ViewModels/AppPreferences.swift)。
///
/// この型は**すべての設定の既定値の正典**で、旧キーの読み替えと、面ごとの
/// 「この画面を初期設定に戻す」もここにしか無い。保存先が `UserDefaults.standard` に
/// 固定されていた頃はテストから作れなかった(作れば利用者の環境設定が書き換わる)ので、
/// `init(defaults:)` で保存先だけ差し替えられるようにしてある。
///
/// テストはその場限りの suite を使う(`PreferencesSuite`)。総なめの 2 つ
/// (`mutationTouchesEverySetting` / 各画面の「初期設定に戻す」)は Mirror で全プロパティを
/// 見るので、設定を 1 つ足したときに書き忘れがあれば名前を挙げて落ちる。
@MainActor
struct AppPreferencesTests {

    // MARK: - 出荷時の既定値

    @Test("何も保存されていなければ、出荷時の既定値になる")
    func anEmptyStoreYieldsShippingDefaults() {
        let suite = PreferencesSuite()
        let p = suite.makePreferences()

        #expect(p.launchOpensLastBook == false)
        #expect(p.firstPageBehavior == .none)
        #expect(p.lastPageBehavior == .none)
        #expect(p.maxUpscalePercent == 200)
        #expect(p.interpolationQuality == .high)
        #expect(p.defaultScalingMode == .fitToScreen)
        #expect(p.backgroundColorOption == .black)
        #expect(p.reopenBehavior == .resume)
        #expect(p.finderOpenBehavior == .replaceCurrentBook)
        #expect(p.displayLanguage == .system)
        #expect(p.appAppearance == .system)
        #expect(p.usesFinderSortOrder == false)
        #expect(p.prefetchPageCount == 3)
        #expect(p.pageImageCacheLimitMB == AppPreferences.defaultPageImageCacheLimitMB)
        // ユーザー報告(黙って数百MB溜まる)を受けて既定 OFF にしたもの。
        #expect(p.thumbnailDiskCacheEnabled == false)
        #expect(p.missingLayoutAutoLayout == .none)
    }

    @Test("書き出しの既定値は形式ごとに違う(画像の連番付け直しは CBZ だけ ON)")
    func exportDefaultsDifferPerFormat() {
        let suite = PreferencesSuite()
        let p = suite.makePreferences()

        for format in BookExportFormat.allCases {
            #expect(p.bookExportDestinationMode(for: format) == .askEachTime)
            #expect(p.bookExportDataCleanup(for: format) == .keep)
            #expect(p.bookExportHistoryCleanup(for: format) == .keep)
            #expect(p.bookExportRenumbersImages(for: format) == (format == .cbz))
            #expect(p.bookExportIncludesExcludedPages(for: format) == false)
        }
    }

    // MARK: - 保存先

    @Test("保存する UserDefaults のキーは変えてはいけない(変えると利用者の設定が消える)")
    func storedKeysAreFrozen() {
        let suite = PreferencesSuite()
        let p = suite.makePreferences()
        p.maxUpscalePercent = 321
        p.appAppearance = .dark
        p.thumbnailDiskCacheEnabled = true
        p.usesFinderSortOrder = true
        p.displayLanguage = .japanese

        let stored = suite.storedDomain
        #expect(stored["qooViewer.pref.maxUpscalePercent"] as? Double == 321)
        #expect(stored["qooViewer.pref.appAppearance"] as? String == "dark")
        #expect(stored["qooViewer.pref.thumbnailDiskCacheEnabled"] as? Bool == true)
        #expect(stored[AppLanguage.defaultsKey] as? String == "japanese")
        // 並び順のキーだけは PageOrder 側に実体がある(nonisolated なコードが同じ値を読むため)。
        #expect(stored[PageOrder.defaultsKey] as? Bool == true)
    }

    @Test("テスト用の保存先を渡したインスタンスは、実物のアプリの設定に触れない")
    func aTestSuiteInstanceDoesNotWriteToTheStandardStore() {
        // 実物のアプリ(TEST_HOST)の設定を覗いて、前後で変わっていないことを見る。
        let watched = [
            "qooViewer.pref.maxUpscalePercent", "qooViewer.pref.appAppearance",
            "qooViewer.pref.thumbnailDiskCacheEnabled", "qooViewer.pref.defaultReadingDirection",
            AppLanguage.defaultsKey, PageOrder.defaultsKey, "AppleLanguages",
        ]
        let before = watched.map { String(describing: UserDefaults.standard.object(forKey: $0)) }

        let suite = PreferencesSuite()
        let p = suite.makePreferences()
        mutateEverySetting(p)
        for pane in SettingsPane.allCases { p.resetToDefaults(pane) }

        let after = watched.map { String(describing: UserDefaults.standard.object(forKey: $0)) }
        #expect(before == after)
    }

    // MARK: - 旧設定の読み替え(最初/最後のページで共通だった頃)

    @Test(
        "旧 loopBehavior は前後それぞれの設定へ読み替えられる",
        arguments: [
            ("loop", FirstPageBehavior.loop, LastPageBehavior.loop),
            ("nextBookFirstPage", .previousBookLastPage, .nextBookFirstPage),
            ("nextBook", .previousBook, .nextBook),
            ("none", .none, .none),
            ("klingon", .none, .none),
        ]
    )
    func theLegacyLoopBehaviorIsMigrated(
        stored: String, first: FirstPageBehavior, last: LastPageBehavior
    ) {
        let suite = PreferencesSuite()
        suite.defaults.set(stored, forKey: "qooViewer.pref.loopBehavior")

        let p = suite.makePreferences()
        #expect(p.firstPageBehavior == first)
        #expect(p.lastPageBehavior == last)
    }

    @Test("読み替えは旧キーをその場で消し、新しい2つのキーへ書き込む")
    func theMigrationRemovesTheLegacyKeyAndPersistsTheResult() {
        let suite = PreferencesSuite()
        suite.defaults.set("nextBook", forKey: "qooViewer.pref.loopBehavior")

        _ = suite.makePreferences()

        // 旧キーが残っていると、「初期設定に戻す」のたびに旧設定が復活してしまう
        // (新しい2つのキーを消して作り直すため)。読んだその場で消すのが要。
        #expect(suite.storedDomain["qooViewer.pref.loopBehavior"] == nil)
        // init 内の代入では didSet が走らないので、UserDefaults へ直接書いている。
        // 書けていないと、旧キーは消えた後なので次回起動で二度と復元できない。
        #expect(suite.storedDomain["qooViewer.pref.firstPageBehavior"] as? String == "previousBook")
        #expect(suite.storedDomain["qooViewer.pref.lastPageBehavior"] as? String == "nextBook")

        // 2 回目は読み替えるものが無い(1 回目の結果がそのまま残る)。
        let second = suite.makePreferences()
        #expect(second.firstPageBehavior == .previousBook)
        #expect(second.lastPageBehavior == .nextBook)
    }

    @Test("分離後に設定し直した値は、旧設定で上書きしない")
    func theMigrationDoesNotOverwriteNewerValues() {
        let suite = PreferencesSuite()
        suite.defaults.set("loop", forKey: "qooViewer.pref.loopBehavior")
        suite.defaults.set("closeBook", forKey: "qooViewer.pref.lastPageBehavior")

        let p = suite.makePreferences()
        // 新しいキーが無かった側だけ読み替えが効く。
        #expect(p.firstPageBehavior == .loop)
        #expect(p.lastPageBehavior == .closeBook)
    }

    // MARK: - 初回起動の既定の読み方向

    @Test("保存済みの読み方向があれば、システムの言語を見ずにそれを使う")
    func aStoredReadingDirectionWins() {
        for direction in ReadingDirection.allCases {
            let suite = PreferencesSuite()
            suite.defaults.set(direction.rawValue, forKey: "qooViewer.pref.defaultReadingDirection")
            #expect(suite.makePreferences().defaultReadingDirection == direction)
        }
    }

    @Test("初回起動で決めた読み方向は保存され、次回は再判定しない")
    func theFirstLaunchReadingDirectionIsPersisted() {
        let suite = PreferencesSuite()
        let first = suite.makePreferences()
        // システムの言語(日本語なら右→左)から一度だけ決める。何に決まったかは環境次第なので、
        // ここで固定するのは「決めた値が保存されること」。
        let determined = first.defaultReadingDirection
        #expect(suite.storedDomain["qooViewer.pref.defaultReadingDirection"] as? String
            == determined.rawValue)

        // 保存済みの値を人が変えた場合に、次の起動で判定し直して上書きしないこと。
        let flipped = otherCase(determined)
        suite.defaults.set(flipped.rawValue, forKey: "qooViewer.pref.defaultReadingDirection")
        #expect(suite.makePreferences().defaultReadingDirection == flipped)
    }

    // MARK: - 総なめ

    @Test("下ごしらえがすべての設定を動かしている(設定を足したらここが落ちる)")
    func mutationTouchesEverySetting() {
        let suite = PreferencesSuite()
        let p = suite.makePreferences()
        let before = settingsSnapshot(of: p)
        mutateEverySetting(p)
        let after = settingsSnapshot(of: p)

        #expect(!before.isEmpty)
        let untouched = before.keys.filter { before[$0] == after[$0] }.sorted()
        // 名前を挙げて落とす ―― 新しい設定を `mutateEverySetting` へ足し忘れると、
        // 下の「初期設定に戻す」の網羅もその項目だけ素通りしてしまうため。
        #expect(untouched.isEmpty, "動かせていない設定: \(untouched.joined(separator: ", "))")
    }

    @Test("すべての設定が保存され、開き直しても同じ値で戻る")
    func everySettingSurvivesReopening() {
        let suite = PreferencesSuite()
        let p = suite.makePreferences()
        mutateEverySetting(p)

        let reopened = suite.makePreferences()
        let expected = settingsSnapshot(of: p)
        let actual = settingsSnapshot(of: reopened)
        let lost = expected.keys.filter { expected[$0] != actual[$0] }.sorted()
        #expect(lost.isEmpty, "保存されていない設定: \(lost.joined(separator: ", "))")
    }

    /// 各画面が「初期設定に戻す」で戻すべき設定(プロパティ名)。
    ///
    /// `AppPreferences` の `keys(for:)` / `apply(_:for:)` とは**別に**、テスト側から
    /// 「その画面で何が戻るべきか」を宣言する。片方にしか書かれていない設定は、
    /// 保存先を見ているだけでは見つからない ―― `apply` にあって `keys(for:)` に無い設定は、
    /// 消し忘れたキーの古い値を `apply` が読み直して戻してしまい、画面も保存先も
    /// 「戻っていない」で一致するため(ユーザー報告:「文字の影」だけリセットされない)。
    private static let paneSettings: [SettingsPane: Set<String>] = [
        .general: [
            "displayLanguage", "launchOpensLastBook", "launchFullScreen", "launchInPrivateMode",
            "quitWhenLastWindowClosed", "confirmBeforeClosingMultipleTabsWindow",
            "showRecentFilesOnWelcome", "showRecentFavoritesOnWelcome", "sidePanelFeatureEnabled",
            "sidePanelPosition", "sidePanelUsesDoubleClick", "sidePanelSortOrder",
            "siblingNavigationFollowsBrowserSort", "usesFinderSortOrder",
        ],
        .appearance: [
            "appAppearance", "backgroundColorOption", "customBackgroundColor",
            "thumbnailGridCellSize", "thumbnailGridHorizontalSpacing", "thumbnailGridVerticalSpacing",
            "thumbnailGridHorizontalMarginPercent", "thumbnailGridVerticalMarginPercent",
            "thumbnailGridCaptionStyle", "thumbnailGridCaptionFontSize",
            "thumbnailGridBorderColorOption", "thumbnailGridBorderCustomColor",
            "showThumbnailHoverPreview", "thumbnailGridWheelScrollRows",
            "showProgressBarThumbnailPreview", "filmstripThumbnailCount", "filmstripCaptionStyle",
            "filmstripFontSize", "filmstripDimsOtherPages", "filmstripHighlightColorOption",
            "filmstripHighlightCustomColor", "filmstripHighlightBorderWidth",
            "toolbarRevealDelay", "progressBarRevealDelay", "sidePanelRevealDelay",
            "toolbarDockedGlass", "progressBarDockedGlass", "sidePanelDockedGlass", "welcomeGlass",
            "pageListSurfaceStyle", "toolbarSurfaceStyle", "progressBarSurfaceStyle",
            "sidePanelSurfaceStyle", "welcomeSurfaceStyle", "overlaySurfaceStyle",
        ],
        .opening: [
            "reopenBehavior", "finderOpenBehavior", "favoriteOpenBehavior",
            "spreadBookmarkTargetBehavior",
        ],
        .rendering: [
            "defaultScalingMode", "maxUpscalePercent", "maxPinchZoomPercent", "interpolationQuality",
            "loupeMagnificationPercent", "loupeDiameter", "singlePageAspectRatioThreshold",
        ],
        .reading: [
            "firstPageBehavior", "lastPageBehavior", "treatTrackpadFlickAsWheel",
            "invertTwoFingerScrolling", "thumbnailHoverPreviewDelay", "thumbnailHoverPreviewSize",
            "slideshowInterval", "autoHideCursor", "cursorAutoHideDelay",
        ],
        .cache: [
            "pageImageCacheLimitMB", "nestedArchiveMemoryLimitMB", "prefetchPageCount",
            "preloadThumbnailGridPreviews", "thumbnailDiskCacheEnabled", "thumbnailDiskCacheLimitMB",
        ],
        .layout: [
            "missingLayoutAutoLayout", "bookExportCompletionBehavior", "bookExportDestinationModes",
            "bookExportDataCleanups", "bookExportHistoryCleanups", "bookExportRenumbersImages",
            "bookExportIncludesExcludedPages", "bookExportWritesVolumeElement",
        ],
        // キー・マウスの割り当ては KeyBindingStore が持つ(各画面が自分で store 側を呼ぶ)。
        // 「フォルダのアクセス権」「リセット」には戻すべき設定が無い。
        .keyboard: [], .mouse: [], .modeInput: [], .access: [], .reset: [],
    ]

    /// どの画面の「初期設定に戻す」でも戻さない設定。
    private static let unmanagedSettings: Set<String> = [
        // 意図的な対象外 ―― 下げると保存済みのデータがその場で消えるため(keys(for:) のコメント)。
        "maxTrackedBooksCount", "recentFilesLimit",
        // 環境設定の画面には並んでいない(「表示」メニューやパネル自身・ブラウザの列で変える値)。
        "hideToolbar", "hideProgressBar", "hideSidePanel", "sidePanelWidth", "sidePanelMode",
        "folderBrowserSortKey", "folderBrowserSortDirection",
        // 初回起動でシステムの言語から一度だけ決める値(環境設定の画面には無い)。
        "defaultReadingDirection",
    ]

    @Test("すべての設定が、いずれかの画面か「戻さない」のどちらかに割り当てられている")
    func everySettingIsAssignedToAPaneOrDeclaredUnmanaged() {
        let suite = PreferencesSuite()
        let all = Set(settingsSnapshot(of: suite.makePreferences()).keys)
        let assigned = Self.paneSettings.values.reduce(into: Set<String>()) { $0.formUnion($1) }

        // 設定を 1 つ足したときに、担当する画面(または「戻さない」)を決めさせるための番人。
        #expect(
            all.subtracting(assigned).subtracting(Self.unmanagedSettings).sorted() == [],
            "どの画面のものか決まっていない設定がある"
        )
        #expect(assigned.subtracting(all).sorted() == [], "もう存在しない設定が表に残っている")
        #expect(assigned.intersection(Self.unmanagedSettings).sorted() == [], "表と「戻さない」が重複")
    }

    @Test(
        "「この画面を初期設定に戻す」は、その画面の設定だけをひとつ残らず出荷時の値へ戻す",
        arguments: SettingsPane.allCases
    )
    func eachPaneResetsExactlyTheSettingsItOwns(pane: SettingsPane) {
        let shipping = settingsSnapshot(of: PreferencesSuite().makePreferences())
        let suite = PreferencesSuite()
        let p = suite.makePreferences()
        mutateEverySetting(p)
        let mutated = settingsSnapshot(of: p)

        p.resetToDefaults(pane)

        let owned = Self.paneSettings[pane] ?? []
        let after = settingsSnapshot(of: p)
        let notReset = owned.filter { after[$0] != shipping[$0] }.sorted()
        #expect(notReset.isEmpty, "\(pane) で戻っていない設定: \(notReset.joined(separator: ", "))")

        let collateral = after.keys
            .filter { !owned.contains($0) && after[$0] != mutated[$0] }
            .sorted()
        #expect(
            collateral.isEmpty,
            "\(pane) の担当でないのに戻ってしまった設定: \(collateral.joined(separator: ", "))"
        )

        // 画面の値と保存先も一致していること(`keys(for:)` にあって `apply(_:for:)` に無い設定は、
        // 保存先だけ既定値に戻り、画面の値は動かないというずれとして現れる)。
        let stored = settingsSnapshot(of: suite.makePreferences())
        let mismatched = after.keys.filter { after[$0] != stored[$0] }.sorted()
        #expect(
            mismatched.isEmpty,
            "\(pane) の「初期設定に戻す」で保存先と食い違う設定: \(mismatched.joined(separator: ", "))"
        )
    }

    @Test("保管件数の2つは、意図的に「初期設定に戻す」の対象外")
    func theTwoRetentionLimitsAreDeliberatelyExcluded() {
        let suite = PreferencesSuite()
        let p = suite.makePreferences()
        p.maxTrackedBooksCount = 2000
        p.recentFilesLimit = 200

        p.resetToDefaults(.general)

        // 値を下げると保存済みのデータ(本ごとの読書位置・履歴)がその場で消える設定なので、
        // 確認ダイアログの無いボタン 1 つで巻き込んではいけない。
        #expect(p.maxTrackedBooksCount == 2000)
        #expect(p.recentFilesLimit == 200)
    }

    @Test("ある画面を戻しても、他の画面の設定は動かない")
    func resettingOnePaneLeavesTheOthersAlone() {
        let suite = PreferencesSuite()
        let p = suite.makePreferences()
        mutateEverySetting(p)
        let mutated = settingsSnapshot(of: p)

        p.resetToDefaults(.rendering)

        let after = settingsSnapshot(of: p)
        // 「画像の見え方」の設定だけが戻り、それ以外は動かしたまま。
        #expect(after["maxUpscalePercent"] != mutated["maxUpscalePercent"])
        #expect(after["interpolationQuality"] != mutated["interpolationQuality"])
        #expect(after["slideshowInterval"] == mutated["slideshowInterval"])
        #expect(after["appAppearance"] == mutated["appAppearance"])
        #expect(after["thumbnailDiskCacheEnabled"] == mutated["thumbnailDiskCacheEnabled"])
        #expect(after["bookExportWritesVolumeElement"] == mutated["bookExportWritesVolumeElement"])
    }

    @Test("すりガラスの面ごとの設定は4項目とも保存され、外観の初期設定で戻る")
    func panelSurfaceStylesRoundTripAndReset() {
        let suite = PreferencesSuite()
        let p = suite.makePreferences()
        let style = PanelSurfaceStyle(
            materialOpacity: 0.25, tintColor: RGBColorValue(red: 12, green: 34, blue: 56),
            tintOpacity: 0.75, contentShadowLevel: 4
        )
        for surface in PanelSurface.allCases { p.setSurfaceStyle(style, for: surface) }

        let reopened = suite.makePreferences()
        for surface in PanelSurface.allCases {
            // ユーザー報告: 「文字の影」(contentShadowLevel)だけリセットされなかった。
            // 面ごとの設定を足したら keys(for:) にも足すこと。
            #expect(reopened.surfaceStyle(for: surface) == style)
        }

        p.resetToDefaults(.appearance)
        for surface in PanelSurface.allCases {
            #expect(p.surfaceStyle(for: surface) == surface.defaultStyle)
            #expect(suite.makePreferences().surfaceStyle(for: surface) == surface.defaultStyle)
        }
    }
}
