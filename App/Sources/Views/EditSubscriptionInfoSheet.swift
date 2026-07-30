import SwiftUI

/// Edits a subscription's name, update URL, and auto-update cadence only — the
/// YAML body is left untouched (that's what the pencil / `YamlEditorView` is
/// for). A changed URL is picked up on the next refresh, not immediately. See
/// issue #182.
struct EditSubscriptionInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionService.self) private var service
    let profile: Profile
    @Binding var error: String?
    @State private var name: String
    @State private var url: String
    @State private var updateInterval: ProfileUpdateInterval

    init(profile: Profile, error: Binding<String?>) {
        self.profile = profile
        _error = error
        _name = State(initialValue: profile.name)
        _url = State(initialValue: profile.url)
        _updateInterval = State(initialValue: profile.updateInterval)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("subscriptions.add.field.name", text: $name)
                        .accessibilityIdentifier("subscriptions.editInfo.nameField")
                    TextField("subscriptions.add.field.url", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier("subscriptions.editInfo.urlField")
                } footer: {
                    Text("subscriptions.editInfo.footer")
                }
                // A cadence needs a URL to fetch, so the picker follows what's
                // typed in the field rather than what was saved: attaching a
                // URL to a local import reveals it, clearing one hides it (and
                // `updateInfo` forces `.manual` to match).
                if !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Picker("subscriptions.editInfo.updateInterval", selection: $updateInterval) {
                            ForEach(ProfileUpdateInterval.allCases) { interval in
                                Text(LocalizedStringKey(interval.titleKey)).tag(interval)
                            }
                        }
                        .accessibilityIdentifier("subscriptions.editInfo.updateIntervalPicker")
                        .accessibilityHint(Text("subscriptions.editInfo.a11y.updateIntervalHint"))
                    } footer: {
                        Text("subscriptions.editInfo.updateInterval.footer")
                    }
                }
            }
            .navigationTitle("subscriptions.editInfo.nav.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("subscriptions.editInfo.button.save") {
                        do {
                            try service.updateInfo(
                                profile,
                                name: name,
                                url: url,
                                updateInterval: updateInterval,
                            )
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("subscriptions.editInfo.saveButton")
                }
            }
        }
    }
}
