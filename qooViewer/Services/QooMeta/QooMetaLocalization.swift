import Foundation
import QooMetaKit
import SwiftUI

// qooMeta のアプリから移した画面(メタデータの編集・解析の設定・抽出の設定)の言葉の引き方。
//
// qooMeta の画面は、鍵(英語)を変数で持つ所で `"…".ui` と `Text(key:)` を使う。qooMeta では `Bundle.main` のクラスを
// 差し替えて言語を選んでいたが、qooViewer は表示言語を `AppLanguage`(環境設定)で選び、その言語の `.lproj` から
// 引く(`String(localized:language:)` と同じ道。Models/AppLanguage.swift)。訳は Localizable.xcstrings に
// qooMeta の訳を合流させてある。

extension String {
    /// 画面に出す言葉(鍵は英語)。`Text` に渡せない所(取り消しの名前、誤りの文、`NSOpenPanel` の言葉)で使う。
    nonisolated var ui: String {
        AppLanguage.currentLocale.displayLanguageBundle.localizedString(forKey: self, value: nil, table: nil)
    }

    /// 値を挟む言葉。鍵の `%@` `%lld` に、渡した値が入る。
    nonisolated func ui(_ arguments: any CVarArg...) -> String {
        String(format: ui, locale: AppLanguage.currentLocale, arguments: arguments)
    }
}

extension Text {
    /// 変数に入った鍵(英語)から作る。`Text(String)` は訳さないので、鍵を変数で持つ所はこの口を通す。
    init(key: String) { self.init(LocalizedStringKey(key)) }
}

extension Label where Title == Text, Icon == Image {
    /// 変数に入った鍵(英語)から作る見出し。
    init(key: String, systemImage: String) { self.init { Text(key: key) } icon: { Image(systemName: systemImage) } }
}

extension QooMetaKit.BookMetadata.Field {
    /// 画面に出す言葉の鍵(英語)。訳は Localizable.xcstrings。
    nonisolated var labelKey: String {
        switch self {
        case .title: "Title"
        case .authors: "Authors"
        case .genre: "Genre"
        case .event: "Event"
        case .source: "Source work"
        case .info: "Info"
        case .series: "Series"
        case .volume: "Volume (as written)"
        }
    }
}
