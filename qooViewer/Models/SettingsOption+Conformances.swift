import SwiftUI

/// 既存の設定用enumを `SettingsOption` に適合させる。
///
/// 既存の `titleKey` はメニューバーやコンテキストメニューなど環境設定以外からも参照されうるため
/// **そのまま残し**、環境設定のポップアップ表示だけを `shortTitleKey` に切り替える。
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
}

extension SidePanelSortOrder: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .foldersFirst: return "Folders First"
        case .mixedByName: return "Mixed by Name"
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
}

extension BackgroundColorOption: SettingsOption {
    var shortTitleKey: LocalizedStringKey { titleKey }
}

extension ScalingMode: SettingsOption {
    var shortTitleKey: LocalizedStringKey { titleKey }
}

// MARK: - 閲覧

extension FirstPageBehavior: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .loop: return "Loop"
        case .previousBookLastPage: return "Previous Book (Last Page)"
        case .previousBook: return "Previous Book"
        case .none: return "Do Nothing"
        case .ask: return "Ask Each Time"
        }
    }
}

extension LastPageBehavior: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .loop: return "Loop"
        case .nextBookFirstPage: return "Next Book (First Page)"
        case .nextBook: return "Next Book"
        case .closeBook: return "Close Book"
        case .returnToWelcome: return "Return to Welcome Screen"
        case .none: return "Do Nothing"
        case .ask: return "Ask Each Time"
        }
    }
}

extension WheelScrollBehavior: SettingsOption {
    var shortTitleKey: LocalizedStringKey { titleKey }
}

// MARK: - 外観

extension ThumbnailCaptionStyle: SettingsOption {
    var shortTitleKey: LocalizedStringKey { titleKey }
}

extension PageBorderColorOption: SettingsOption {
    var shortTitleKey: LocalizedStringKey { titleKey }
}

// MARK: - レイアウト

extension MissingLayoutAutoLayout: SettingsOption {
    /// 「1ページ目を単ページとして」「1ページ目を見開きとして」まで書くと閉じた状態で
    /// 省略されるため、**何がその1ページ目になるか**だけを名前にしてある
    /// (行のラベルが「レイアウトの無い本を開いたとき」なので、これで意味が通る)。
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .none: return "Do Nothing"
        case .firstPageSingle: return "First Page as Single"
        case .firstPageSpread: return "First Page as Spread"
        }
    }
}

extension BookExportDestinationMode: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .askEachTime: return "Ask Each Time"
        case .fixedFolder: return "Set a Default Export Folder"
        }
    }
}

extension BookExportCleanup: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .keep: return "Do Nothing"
        case .delete: return "Delete"
        }
    }
}

extension BookExportCompletionBehavior: SettingsOption {
    /// `LastPageBehavior`の同じ選択肢と同じ短い名前を使う(片方だけ別の言い回しにしない)。
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .none: return "Do Nothing"
        case .nextBookFirstPage: return "Next Book (First Page)"
        case .nextBook: return "Next Book"
        case .closeBook: return "Close Book"
        case .returnToWelcome: return "Return to Welcome Screen"
        case .ask: return "Ask Each Time"
        }
    }
}
