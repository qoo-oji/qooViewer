import SwiftUI

/// 組のボタン(キャンセル / 実行)の幅をそろえる(ユーザー指摘の繰り返し。MetadataButtonWidthEstimator.equalWidth)。
private func pairedButtonWidth(_ labels: [String]) -> CGFloat {
    MetadataButtonWidthEstimator.equalWidth(for: labels, minWidth: 80, chrome: 0)
}

/// 今ある項目に掛ける前の確認(docs/plans/auto-rename-study.md §8 の 2)。変わる名前と、変えずに見送る項目を並べる。
struct AutoRenameConfirmationSheet: View {
    @EnvironmentObject private var service: AutoRenameService
    @EnvironmentObject private var store: AutoRenameStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    /// 開いた時点の確認待ちの対象(開いている間に増えたものは次の確認へ回す)。
    let targetIDs: Set<UUID>

    @State private var items: [AutoRenameService.PreviewItem]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Items Already in the Folders?")
                .font(.headline)
            Text("These rules apply to items that are already in their target folders. Items added later are renamed without asking.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let items {
                    Table(items) {
                        TableColumn("Folder") { item in
                            Text(verbatim: item.folder)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .help(Text(verbatim: item.folder))
                        }
                        TableColumn("Current Name") { item in
                            Text(verbatim: item.name).lineLimit(1).truncationMode(.middle)
                        }
                        TableColumn("New Name") { item in
                            if let newName = item.newName {
                                Text(verbatim: newName).lineLimit(1).truncationMode(.middle)
                            } else if let message = item.skipMessage {
                                Label(message, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .help(Text(verbatim: message))
                            }
                        }
                        TableColumn("Rules") { item in
                            Text(verbatim: item.ruleNames.joined(separator: ", "))
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 260)
            HStack {
                if let items {
                    Text(String(
                        format: String(localized: "%1$lld items will be renamed · %2$lld left as they are", language: locale),
                        items.filter { $0.newName != nil }.count, items.filter { $0.newName == nil }.count
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                let width = pairedButtonWidth([
                    String(localized: "Not Now", language: locale), String(localized: "Rename", language: locale),
                ])
                Button {
                    dismiss()
                } label: {
                    Text("Not Now").frame(minWidth: width)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    service.confirm(targetIDs: targetIDs)
                    dismiss()
                } label: {
                    Text("Rename").frame(minWidth: width)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(items == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 440)
        .task {
            items = await service.preview(targetIDs: targetIDs)
        }
    }
}

/// 移動したと思われる対象の提案(§6.3)。行はフォルダ単位、対象ごとに更新を選ぶ。
struct AutoRenameMoveSuggestionsSheet: View {
    @EnvironmentObject private var service: AutoRenameService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var chosen: Set<String> = []
    @State private var rowSelection: Set<String> = []
    @State private var didInitialize = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Target Folders That Seem to Have Moved")
                .font(.headline)
            Text("These target folders weren’t found where they were, so they were turned off. Choose the ones to update to the new location. Rules that were on go back on after you check the changes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Table(service.moveSuggestions, selection: $rowSelection) {
                TableColumn("Update") { suggestion in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(suggestion.id) },
                        set: { isOn in
                            if isOn { chosen.insert(suggestion.id) } else { chosen.remove(suggestion.id) }
                        }
                    )) {
                        EmptyView()
                    }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(suggestion.status != .updatable)
                }
                .width(52)
                TableColumn("Original Location") { suggestion in
                    Text(verbatim: suggestion.originalPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(Text(verbatim: suggestion.originalPath))
                }
                TableColumn("Found At") { suggestion in
                    foundText(suggestion)
                }
                TableColumn("Rules") { suggestion in
                    Text(verbatim: suggestion.ruleNames.joined(separator: ", "))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Don’t Suggest Again") {
                    service.suppressMoveSuggestions(service.moveSuggestions.filter { ids.contains($0.id) })
                    chosen.subtract(ids)
                }
                .disabled(ids.isEmpty)
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                let width = pairedButtonWidth([
                    String(localized: "Cancel", language: locale), String(localized: "Update", language: locale),
                ])
                Button {
                    dismiss()
                } label: {
                    Text("Cancel").frame(minWidth: width)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    let selected = service.moveSuggestions.filter { chosen.contains($0.id) && $0.status == .updatable }
                    Task {
                        await service.applyMoveSuggestions(selected)
                        dismiss()
                    }
                } label: {
                    Text("Update").frame(minWidth: width)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 380)
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            chosen = Set(service.moveSuggestions.filter { $0.status == .updatable }.map(\.id))
        }
        .onChange(of: service.moveSuggestions) { _, suggestions in
            if suggestions.isEmpty { dismiss() }
            chosen.formIntersection(suggestions.map(\.id))
        }
    }

    @ViewBuilder
    private func foundText(_ suggestion: AutoRenameService.MoveSuggestion) -> some View {
        switch suggestion.status {
        case .updatable:
            Text(verbatim: suggestion.foundPath ?? "")
                .lineLimit(1)
                .truncationMode(.head)
                .help(Text(verbatim: suggestion.foundPath ?? ""))
        case .inTrash:
            reason(String(localized: "In the Trash", language: locale))
        case .outsideFavorites:
            reason(String(localized: "Not in Favorite Locations", language: locale))
        case .networkVolume:
            reason(String(localized: "On a network volume", language: locale))
        case .noAccess:
            reason(String(localized: "No access", language: locale))
        case .notFound:
            reason(String(localized: "Couldn’t be found", language: locale))
        }
    }

    private func reason(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(.secondary)
    }
}

/// 実行ログ(§8 の 7・9)。
struct AutoRenameActivityLogSheet: View {
    @EnvironmentObject private var log: AutoRenameActivityLog
    @EnvironmentObject private var service: AutoRenameService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var selection: Set<UUID> = []
    @State private var confirmsClear = false
    @State private var restoreProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity Log")
                .font(.headline)
            Table(log.entries, selection: $selection) {
                TableColumn("Date") { entry in
                    Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Folder") { entry in
                    Text(verbatim: entry.folderPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(Text(verbatim: entry.folderPath))
                }
                TableColumn("Name") { entry in
                    Text(verbatim: entry.originalName).lineLimit(1).truncationMode(.middle)
                }
                TableColumn("Result") { entry in
                    resultText(entry)
                }
                TableColumn("Rules") { entry in
                    Text(verbatim: entry.ruleNames.joined(separator: ", "))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 300)
            if let restoreProblem {
                Label(restoreProblem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text(String(format: String(localized: "%lld entries", language: locale), log.entries.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Original Names") {
                    Task { restoreProblem = await service.restore(entryIDs: selection) }
                }
                .disabled(!log.entries.contains { selection.contains($0.id) && $0.isRestorable })
                .help(Text("Puts the selected renamed items back to their original names. The rules won’t rename them again."))
                Button("Delete Log…") { confirmsClear = true }
                    .disabled(log.entries.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 460)
        .confirmationDialog("Delete the activity log?", isPresented: $confirmsClear) {
            Button("Delete", role: .destructive) { log.removeAll() }
        } message: {
            Text("This action can’t be undone.")
        }
    }

    @ViewBuilder
    private func resultText(_ entry: AutoRenameActivityLog.Entry) -> some View {
        switch entry.outcome {
        case .renamed(let newName):
            Label { Text(verbatim: newName) } icon: { Image(systemName: "arrow.right") }
                .lineLimit(1)
        case .skipped(let result, let reason):
            Label(String(format: String(localized: "Left as it is: %@", language: locale), reason), systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(Text(verbatim: "\(result)\n\(reason)"))
        case .failed(let newName, let message):
            Label(String(format: String(localized: "Couldn’t rename to “%1$@”: %2$@", language: locale), newName, message),
                  systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(Text(verbatim: message))
        case .restored(let fromName):
            Label(String(format: String(localized: "Restored from “%@”", language: locale), fromName), systemImage: "arrow.uturn.backward")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

extension AutoRenameActivityLog.Entry {
    /// 元の名前に戻せる行か(名前を変えた行だけ)。
    var isRestorable: Bool {
        if case .renamed = outcome { return true }
        return false
    }
}
