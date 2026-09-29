import SwiftUI

@MainActor
final class SyncModel: ObservableObject {
    @Published var message = "Ready to index TMDB titles in Spotlight."
    @Published var busy = false
    @Published var progress = 0.0
    @Published var limit = 30_000
    @Published var logText = ""
    private let logger = DiagnosticLog()

    init() { logText = logger.tail }

    func sync() {
        guard !busy else { return }
        busy = true
        progress = 0
        message = "Starting sync…"
        Task {
            do {
                let worker = SpotlightIndexer(logger: logger)
                let result = try await worker.sync(limit: max(1_000, limit)) { [weak self] done, total, text in
                    Task { @MainActor in
                        self?.progress = total == 0 ? 0 : Double(done) / Double(total)
                        self?.message = text
                        self?.logText = self?.logger.tail ?? ""
                    }
                }
                message = "Indexed \(result.indexed) titles (\(result.movies) movies, \(result.series) series)."
                logger.write("UI", "Sync complete: indexed=\(result.indexed), movies=\(result.movies), series=\(result.series), skippedByLimit=\(result.skippedByLimit)")
            } catch {
                message = "Sync failed: \(error.localizedDescription)"
                logger.write("ERROR", "Sync failed: \(String(reflecting: error))")
            }
            logText = logger.tail
            busy = false
        }
    }
}

struct ContentView: View {
    @StateObject private var model = SyncModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Make TMDB movies and TV series available in iOS Spotlight search.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Stepper("Maximum titles: \(model.limit.formatted())", value: $model.limit, in: 1_000...150_000, step: 5_000)
                    .disabled(model.busy)
                Button(action: model.sync) {
                    Label(model.busy ? "Indexing…" : "Sync TMDB index", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(model.busy)
                ProgressView(value: model.progress)
                Text(model.message).font(.callout)
                Text("Diagnostic log").font(.headline)
                ScrollView {
                    Text(model.logText.isEmpty ? "No log entries yet." : model.logText)
                        .font(.system(.caption2, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
                Text("iOS controls Spotlight storage and may evict or delay results. The app logs submission and error details; it cannot inspect Apple's private index or guarantee every item is surfaced.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding().navigationTitle("TMDB Spotlight")
        }
    }
}
