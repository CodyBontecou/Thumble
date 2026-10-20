import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class IOSBuildRecoveryCoordinator: ObservableObject {
    @Published private(set) var records: [PendingProfileRecovery.Record] = []
    @Published var error: String?
    private let reader: PendingProfileRecovery?
    init() { reader = try? PendingProfileRecovery(rootURL: PendingProfileRecovery.defaultRootURL()) }
    init(rootURL: URL) { reader = PendingProfileRecovery(rootURL: rootURL) }
    func refresh() async {
        guard let reader else { error = "Saved builds could not be read. The originals have been kept."; return }
        do { records = try await Task.detached { try reader.list() }.value }
        catch { self.error = "Saved builds could not be read. The originals have been kept." }
    }
    func prepare(_ record: PendingProfileRecovery.Record) async -> PendingProfileRecovery.Export? {
        guard let reader else { return nil }
        do { return try await Task.detached { try reader.prepare(record) }.value }
        catch { self.error = "The export could not be prepared. Refresh and try again. The original files have been kept."; return nil }
    }
    @discardableResult func routeRetiredURL(_ value: String) -> Bool {
        guard value.utf8.count <= 4_096, let url = URLComponents(string: value),
              url.host?.lowercased() == "thumble-mcp-gateway.fly.dev" else { return false }
        error = "Hosted shared builds have been retired. You can export builds already saved on this iPhone."
        return true
    }
}

#if os(iOS)
private struct IOSRecoveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .zip] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct IOSBuildRecoverySheet: View {
    @ObservedObject var recovery: IOSBuildRecoveryCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var document: IOSRecoveryDocument?
    @State private var exporting = false
    @State private var preparing = false
    @State private var filename = "thumble-recovered"
    @State private var contentType = UTType.json
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Hosted shared builds have been retired. Export a saved profile file to import it locally on your Mac. Your originals stay on this iPhone.")
                    if let error = recovery.error { Text(error).foregroundStyle(.secondary) }
                    Button("Refresh") { Task { await recovery.refresh() } }.disabled(preparing)
                }
                ForEach(recovery.records) { record in
                    Section {
                        Text(record.name)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file)).foregroundStyle(.secondary)
                        if !record.isProfileFile { Text("This record needs manual recovery. Export keeps its original files together in an archive.") }
                        Button(record.isProfileFile ? "Save profile file" : "Save recovery archive") {
                            preparing = true
                            Task {
                                if let result = await recovery.prepare(record) {
                                    document = IOSRecoveryDocument(data: result.data)
                                    filename = (result.filename as NSString).deletingPathExtension
                                    contentType = result.isProfileFile ? .json : .zip
                                    exporting = true
                                }
                                preparing = false
                            }
                        }.disabled(preparing || exporting)
                    }
                }
                if recovery.records.isEmpty { Text("No saved builds to recover.") }
            }
            .navigationTitle("Recover saved builds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: document, contentType: contentType, defaultFilename: filename) { result in
                document = nil
                if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                    recovery.error = "The export could not be completed. The original saved build is still on this iPhone."
                }
            }
        }
    }
}

#endif
