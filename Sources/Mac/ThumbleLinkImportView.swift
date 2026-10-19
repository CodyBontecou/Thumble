import SwiftUI

struct ThumbleLinkImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = ""
    @State private var plan: ThumbleLinkImport.Plan?
    @State private var errorMessage: String?
    @State private var successMessage: String?
    let currentConfiguration: () throws -> Data
    let onImport: (ThumbleLinkImport.Plan) throws -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Thumble Link").font(.title2.weight(.semibold))
            if let successMessage {
                Label(successMessage, systemImage: "checkmark.circle")
                Text("Your setup is ready in the editor and will be delivered to your paired iPhone.")
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else if let plan {
                review(plan)
            } else {
                Text("In WoW Forever, type /thumble, generate an export, and copy the code. Paste it here to create or refresh your character’s phone setup.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 180)
                    .border(.secondary.opacity(0.3))
                    .accessibilityLabel("WoW Thumble Link export")
                TextField("Setup name (optional)", text: $name)
                Text("Version 1 imports existing keyboard bindings from Blizzard action bars and utility controls. Pictures and cooldowns are not synchronized.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Spacer()
                    Button("Review Import") { prepare() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(24)
        .frame(width: 660)
    }

    private func review(_ plan: ThumbleLinkImport.Plan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(plan.isRefresh ? "Refresh" : "Create") \(plan.profileName)").font(.headline)
            Text("\(plan.snapshot.character.classTag) · Forever \(plan.snapshot.client.version) · Exported \(Date(timeIntervalSince1970: TimeInterval(plan.snapshot.exportedAt)).formatted())")
                .font(.caption).foregroundStyle(.secondary)
            List(plan.rows) { row in
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.label)
                        Text(row.command).font(.caption).foregroundStyle(.secondary)
                        if let note = row.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(row.key ?? row.issue ?? "Skipped")
                        .foregroundStyle(row.key == nil ? .secondary : .primary)
                }
            }
            .frame(height: 230)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxHeight: 120)
            HStack {
                Button("Back") { self.plan = nil; errorMessage = nil }
                Spacer()
                Button(plan.isRefresh ? "Refresh Setup" : "Create Setup") {
                    do { successMessage = try onImport(plan); errorMessage = nil; text = "" }
                    catch { errorMessage = error.localizedDescription; self.plan = nil }
                }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func prepare() {
        do {
            plan = try ThumbleLinkImport.prepare(text: text, currentConfiguration: currentConfiguration(),
                name: name.isEmpty ? nil : name)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
