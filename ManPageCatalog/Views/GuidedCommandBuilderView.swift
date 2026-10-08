import SwiftUI

/// Edits documented argument words; the session owns the exact generated preview and review state.
struct GuidedCommandBuilderView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1  Choose an action").font(.headline)
            Picker("Action", selection: Binding(get: { session.guidedRecipeID ?? "" }, set: { session.selectGuidedRecipe(id: $0) })) {
                ForEach(session.guidedRecipes) { recipe in Text(recipe.title).tag(recipe.id) }
            }.accessibilityIdentifier("guidedAction")
            if let recipe = session.guidedRecipe {
                Text(recipe.summary).textSelection(.enabled)
                Text("2  Fill in inputs and options").font(.headline)
                ForEach(recipe.inputs) { input in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(input.title + (input.required ? " (required)" : " (optional)")).font(.subheadline).fontWeight(.medium)
                        HStack {
                            TextField(input.placeholder, text: Binding(get: { session.guidedInputs[input.id] ?? "" }, set: { session.setGuidedInput(id: input.id, value: $0) }))
                                .textFieldStyle(.roundedBorder).accessibilityLabel(input.title)
                                .accessibilityIdentifier("guided-input-\(input.id)")
                            if input.kind != .text {
                                Button("Choose…") { chooseInput(input) }.accessibilityLabel("Choose \(input.title)")
                                    .accessibilityIdentifier("guided-choose-\(input.id)")
                            }
                        }
                    }
                }
                if recipe.inputs.isEmpty { Text("This action needs no additional input.").font(.caption).foregroundStyle(.secondary) }
                ForEach(recipe.options) { option in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(option.title + "  (\(option.flag))", isOn: Binding(get: { session.guidedOptions.contains(option.id) }, set: { session.setGuidedOption(id: option.id, selected: $0) }))
                            .toggleStyle(.checkbox).accessibilityIdentifier("guided-option-\(option.id)")
                        Text(option.explanation).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                    }
                }
                Text(recipe.reference.compatibilityExplanation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func chooseInput(_ input: GuidedCommandInput) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = input.kind == .file
        panel.canChooseDirectories = input.kind == .directory
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.directory
        panel.message = "Choose \(input.title) for the command preview."
        if panel.runModal() == .OK, let url = panel.url { session.setGuidedInput(id: input.id, value: url.path) }
    }
}
