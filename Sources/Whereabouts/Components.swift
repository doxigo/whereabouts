import SwiftUI

enum Tone {
    case success, error, warning, neutral, loading

    var color: Color {
        switch self {
        case .success: .green
        case .error: .red
        case .warning: .orange
        case .neutral, .loading: .secondary
        }
    }
}

/// Colored dot + label, the status indicator used throughout.
struct StatusBadge: View {
    let tone: Tone
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            if tone == .loading {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(tone.color).frame(width: 7, height: 7)
            }
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// A tinted notice row for kill-switch states and errors.
struct Banner<Actions: View>: View {
    let color: Color
    let icon: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            actions
        }
        .listRowBackground(color.opacity(0.12))
    }
}

extension Banner where Actions == EmptyView {
    init(color: Color, icon: String, text: String) {
        self.init(color: color, icon: icon, text: text) { EmptyView() }
    }
}

/// A list row with a trailing remove button.
struct RemovableRow<Content: View>: View {
    let onRemove: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            HStack { content }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Remove")
        }
    }
}

/// A field + Add button that submits on Return.
struct AddField: View {
    let placeholder: String
    let onAdd: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack {
            TextField(placeholder, text: $text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Button("Add", action: submit).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        onAdd(value)
        text = ""
    }
}

/// Button that opens a searchable country list.
struct CountryPicker: View {
    var title = "Add Country…"
    var exclude: Set<String> = []
    let onPick: (String) -> Void
    @State private var shown = false
    @State private var query = ""

    private var results: [(code: String, name: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return Countries.all.filter {
            !exclude.contains($0.code) && (q.isEmpty || $0.name.lowercased().contains(q) || $0.code.lowercased() == q)
        }
    }

    var body: some View {
        Button(title) { shown = true }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    TextField("Search countries", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .padding(8)
                        .onSubmit { if let first = results.first { pick(first.code) } }
                    List(results, id: \.code) { country in
                        Button { pick(country.code) } label: {
                            HStack {
                                Text(Countries.flag(country.code))
                                Text(country.name)
                                Spacer()
                                Text(country.code).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 300, height: 340)
            }
    }

    private func pick(_ code: String) {
        onPick(code)
        shown = false
        query = ""
    }
}

/// Section footer, leading-aligned like System Settings.
struct Footer: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}
