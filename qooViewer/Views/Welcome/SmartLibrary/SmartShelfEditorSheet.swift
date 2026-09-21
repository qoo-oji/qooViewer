import SwiftUI

/// 編集するスマートシェルフ(新しく作るか、既にあるものを直すか)。
struct SmartShelfEditorTarget: Identifiable {
    var shelf: SmartShelf
    let isNew: Bool
    var id: UUID { shelf.id }
}

/// スマートシェルフの条件のシート(StackNest の SmartShelfEditorSheet と同じ形 ―― Apple Mail のルールの形)。
///
/// 上から: 名前 /「次の条件の [すべて / いずれか] に合う」/ 条件の行([欄] [演算子] [値] [−])/ [+] / キャンセル・保存。
/// 欄を替えても値の種類が同じなら演算子と値を保ち、種類が変わったときだけ既定へ戻す(StackNest と同じ)。
/// 保存できるのは、名前が空でなく、使える条件が 1 つ以上あるとき(**空の「含む」は全部に当たる**ので数えない)。
///
/// シートの中身は macOS が不透明に描くので、すりガラス面の輪郭は要らない(CLAUDE.md)。
struct SmartShelfEditorSheet: View {
    let target: SmartShelfEditorTarget
    let onSave: (SmartShelf) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var name = ""
    @State private var match: SmartShelfConditions.Match = .all
    @State private var rules: [SmartShelfRule] = []

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && rules.contains(where: \.isUsable)
    }

    var body: some View {
        let buttonWidth = MetadataButtonWidthEstimator.equalWidth(
            for: [String(localized: "Cancel", language: locale), String(localized: "Save", language: locale)],
            minWidth: 60, chrome: 0
        )
        VStack(alignment: .leading, spacing: 14) {
            Text(target.isNew ? "New Smart Library" : "Edit Smart Library")
                .font(.headline)
            HStack {
                Text("Name:")
                TextField("", text: $name, prompt: Text("Smart Library"))
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 6) {
                Text("Show books that match")
                Picker("", selection: $match) {
                    Text("all").tag(SmartShelfConditions.Match.all)
                    Text("any").tag(SmartShelfConditions.Match.any)
                }
                .labelsHidden()
                .fixedSize()
                Text("of the following conditions:")
            }
            VStack(spacing: 6) {
                ForEach($rules) { $rule in
                    SmartRuleRow(rule: $rule, canRemove: rules.count > 1) {
                        rules.removeAll { $0.id == rule.id }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            Button {
                rules.append(SmartShelfRule(field: .genre))
            } label: {
                Label("Add Condition", systemImage: "plus")
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(role: .cancel) { dismiss() } label: {
                    Text("Cancel").frame(width: buttonWidth)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    var shelf = target.shelf
                    shelf.name = name.trimmingCharacters(in: .whitespaces)
                    shelf.conditions = SmartShelfConditions(match: match, rules: rules.filter(\.isUsable))
                    onSave(shelf)
                    dismiss()
                } label: {
                    Text("Save").frame(width: buttonWidth)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            name = target.shelf.name
            match = target.shelf.conditions.match
            rules = target.shelf.conditions.rules.isEmpty ? [SmartShelfRule(field: .genre)] : target.shelf.conditions.rules
        }
    }
}

/// 条件の 1 行。
private struct SmartRuleRow: View {
    @Binding var rule: SmartShelfRule
    let canRemove: Bool
    let onRemove: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: fieldBinding) {
                ForEach(SmartField.allCases, id: \.self) { field in
                    Text(LocalizedStringKey(field.titleKey)).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 170)
            Picker("", selection: $rule.op) {
                ForEach(rule.field.valueType.operators, id: \.self) { op in
                    Text(LocalizedStringKey(op.titleKey)).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            valueEditor
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .opacity(canRemove ? 1 : 0)
            .disabled(!canRemove)
            .help("Remove This Condition")
        }
    }

    /// 欄を替えたとき、値の種類が変わるなら演算子と値を既定へ戻す。
    private var fieldBinding: Binding<SmartField> {
        Binding(get: { rule.field }, set: { field in
            let sameType = field.valueType == rule.field.valueType
            rule.field = field
            if !sameType || !field.valueType.operators.contains(rule.op) {
                rule.op = field.valueType.operators[0]
                rule.text = field.choices.first?.value ?? ""
                rule.number = field.valueType.defaultNumber
            } else if !field.choices.isEmpty, !field.choices.contains(where: { $0.value == rule.text }) {
                rule.text = field.choices.first?.value ?? ""
            }
        })
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch rule.field.valueType {
        case .text:
            if !rule.op.takesNoValue {
                TextField("", text: $rule.text)
                    .textFieldStyle(.roundedBorder)
            }
        case .number:
            TextField("", value: $rule.number, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
        case .days:
            HStack(spacing: 4) {
                TextField("", value: $rule.number, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Text("days")
            }
        case .choice:
            Picker("", selection: $rule.text) {
                ForEach(rule.field.choices, id: \.value) { choice in
                    Text(LocalizedStringKey(choice.titleKey)).tag(choice.value)
                }
            }
            .labelsHidden()
            .fixedSize()
            .onAppear {
                if !rule.field.choices.contains(where: { $0.value == rule.text }) {
                    rule.text = rule.field.choices.first?.value ?? ""
                }
            }
        case .flag:
            EmptyView()
        }
    }
}
