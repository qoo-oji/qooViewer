import SwiftUI

/// 既存の設定用enumを `SettingsOption` に適合させる。
///
/// 既存の `titleKey` はメニューバーやコンテキストメニューなど環境設定以外からも参照されうるため
/// **そのまま残し**、環境設定のポップアップ表示だけを `shortTitleKey` / `detailKey` に切り替える。
/// enum本体のファイルを触らずにここへ集約しているのは、
/// 「表示文言の設計」を1ファイルで見渡して調整できるようにするため。

// MARK: - 開く

extension ReopenBehavior: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .resume: return "Last Page"
        case .alwaysFromStart: return "Always First Page"
        case .fromStartIfFinishedLastTime: return "First Page if Finished"
        case .ask: return "Ask Each Time"
        }
    }

    var detailKey: LocalizedStringKey? {
        switch self {
        case .resume:
            return "Resumes from the page you were viewing last time."
        case .alwaysFromStart:
            return "Always shows page 1, no matter how far you read."
        case .fromStartIfFinishedLastTime:
            return "Shows page 1 only for books whose last page you had reached."
        case .ask:
            return "Asks every time whether to resume from the last page."
        }
    }
}

extension FinderOpenBehavior: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .replaceCurrentBook: return "Replace Current Book"
        case .newTab: return "New Tab"
        case .newWindow: return "New Window"
        }
    }
}

extension SpreadBookmarkTargetBehavior: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .defaultSide: return "Default Side"
        case .askEachTime: return "Ask Each Time"
        }
    }

    var detailKey: LocalizedStringKey? {
        switch self {
        case .defaultSide:
            return "Uses the side that matches the reading direction (right page for right-to-left books)."
        case .askEachTime:
            return "Asks which side of the spread to bookmark each time."
        }
    }
}

// MARK: - 一般

extension AppLanguage: SettingsOption {
    var shortTitleKey: LocalizedStringKey { titleKey }
}

extension SidePanelPosition: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .left: return "Left Side"
        case .right: return "Right Side"
        }
    }

    var detailKey: LocalizedStringKey? {
        switch self {
        case .left:
            return "Shows the side panel along the left edge of the window."
        case .right:
            return "Shows the side panel along the right edge of the window."
        }
    }
}

extension SidePanelSortOrder: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .foldersFirst: return "Folders First"
        case .mixedByName: return "Mixed by Name"
        }
    }

    var detailKey: LocalizedStringKey? {
        switch self {
        case .foldersFirst:
            return "Groups folders together above files, like Finder."
        case .mixedByName:
            return "Sorts folders and files together by name."
        }
    }
}

// MARK: - 描画

extension InterpolationQuality: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .high: return "High"
        case .defaultQuality: return "Standard"
        case .low: return "Low"
        }
    }

    var detailKey: LocalizedStringKey? {
        switch self {
        case .high: return "Sharpest result. Uses the most CPU."
        case .defaultQuality: return "Balanced quality and speed."
        case .low: return "Fastest. Best for large images on slower Macs."
        }
    }
}

extension BackgroundColorOption: SettingsOption {
    var shortTitleKey: LocalizedStringKey { titleKey }

    /// プリセットの色名は説明が要らないので、補足を出すのは「カスタム」だけ。
    /// 「カスタム」を選ぶと色を指定するダイアログが開くが、選び直しでまた開けることは
    /// 見ただけでは分からないため、それをここで伝える(RenderingSettingsViewの
    /// backgroundColorSelection参照)。
    var detailKey: LocalizedStringKey? {
        switch self {
        case .custom: return "Select Custom again to change the color."
        default: return nil
        }
    }
}

extension ScalingMode: SettingsOption {
    var shortTitleKey: LocalizedStringKey { titleKey }
}

// MARK: - 閲覧

extension LoopBehavior: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .loop: return "Loop"
        case .nextBookFirstPage: return "Next Book (First Page)"
        case .nextBook: return "Next Book"
        case .none: return "Do Nothing"
        }
    }
}

extension WheelScrollBehavior: SettingsOption {
    var shortTitleKey: LocalizedStringKey { titleKey }

    var detailKey: LocalizedStringKey? {
        switch self {
        case .scrollOnly: return "The wheel only scrolls; it never turns the page."
        case .scrollAndWrap: return "At the edge, moves one screen sideways without turning the page."
        case .scrollAndTurnPage: return "At the edge, moves sideways and then turns the page."
        case .turnPage: return "The wheel never scrolls; it always performs the action assigned to it on the Input tab."
        }
    }
}
