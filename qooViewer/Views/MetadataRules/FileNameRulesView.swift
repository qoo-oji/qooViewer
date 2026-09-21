import QooMetaKit
import SwiftUI

/// **ファイル名の解析**の窓(filename-formats)。プリセット(型の並び)を見て・作って・消して・直す。
///
/// **シリーズと巻数の規則は別の窓**(`SeriesRulesView`)。当たる処理の段が違うので、混ぜない
/// (2026-09-21、利用者の指示)。流れの段 2「解析方法を選ぶ」から開く ―― 結果がいまいちなら、その場で
/// 理由を見て直せるように。
struct FileNameRulesView: View {
    static let windowID = "filename-rules"

    @Bindable var settings: MetadataRulesStore
    @State private var pane: Pane = .presets
    @State private var editing: RulesEditing
    @State private var confirmsReset = false

    init(settings: MetadataRulesStore) {
        self.settings = settings
        _editing = State(initialValue: RulesEditing(settings: settings))
    }

    enum Pane: String, CaseIterable, Identifiable {
        case presets, json
        var id: String { rawValue }

        var title: String { self == .presets ? "Rule sets" : "Your changes (JSON)" }
        var symbol: String { self == .presets ? "textformat.abc" : "curlybraces" }
    }

    var body: some View {
        VStack(spacing: 0) {
            PhaseBanner(flow: "File name → fields (title, authors, genre, …)",
                        fileName: "filename-formats.json", symbol: "doc.text.magnifyingglass")
            Divider()
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Label(LocalizedStringKey($0.title), systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 8)
            Divider()
            Group {
                switch pane {
                case .presets: FormatsPane(editing: editing, catalog: settings.rules.presetCatalog,
                                           isVolume: settings.rules.formats[nil].isVolume)
                case .json: DiffPane(editing: editing, half: .fileNames)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(editing: editing, half: .fileNames, confirmsReset: $confirmsReset)
        }
        .navigationTitle("File name parsing")
        .confirmationDialog("Reset every rule set to the default?", isPresented: $confirmsReset) {
            Button("Reset to the default", role: .destructive) { editing.reset(.fileNames) }
        } message: {
            Text("The rule sets you saved under a name of your own are deleted, and the bundled ones go back to their bundled contents.")
        }
    }
}
