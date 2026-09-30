import SwiftUI
import UIKit

@MainActor
final class SyncModel: ObservableObject {
    @Published var message = "Ready to index TMDB titles in Spotlight."
    @Published var busy = false
    @Published var progress = 0.0
    @Published var limit = UserDefaults.standard.object(forKey: "spotlight.rowLimit") as? Int ?? 30_000 {
        didSet { UserDefaults.standard.set(limit, forKey: "spotlight.rowLimit") }
    }
    @Published var fullIndex = UserDefaults.standard.object(forKey: "spotlight.fullIndex") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fullIndex, forKey: "spotlight.fullIndex") }
    }
    @Published var logText = ""
    private let logger = DiagnosticLog()
    private let appDelegate: AppDelegate

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        logText = logger.tail
    }

    func sync() {
        guard !busy else { return }
        busy = true
        progress = 0
        message = "Starting sync…"
        do {
            try appDelegate.startFullIndex(limit: fullIndex ? nil : max(1_000, limit), progress: { [weak self] done, total, text in
                Task { @MainActor [weak self] in
                    self?.progress = total == 0 ? 0 : Double(done) / Double(total)
                    self?.message = text
                    self?.logText = self?.logger.tail ?? ""
                }
            }, completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let result):
                    self.message = result.incremental
                        ? "Updated \(result.indexed) changed titles (\(result.movies) movies, \(result.series) series)."
                        : "Indexed \(result.indexed) titles (\(result.movies) movies, \(result.series) series)."
                    self.logger.write("UI", "Sync complete: incremental=\(result.incremental), indexed=\(result.indexed), movies=\(result.movies), series=\(result.series), skippedByLimit=\(result.skippedByLimit)")
                case .failure(let error):
                    self.message = "Sync failed: \(error.localizedDescription)"
                    self.logger.write("ERROR", "Sync failed: \(String(reflecting: error))")
                }
                self.logText = self.logger.tail
                self.busy = false
            })
        } catch {
            message = "Could not start indexing: \(error.localizedDescription)"
            logger.write("ERROR", "Could not submit continued indexing task: \(String(reflecting: error))")
            logText = logger.tail
            busy = false
        }
    }
}

struct ContentView: View {
    @StateObject private var model: SyncModel

    init(appDelegate: AppDelegate) {
        _model = StateObject(wrappedValue: SyncModel(appDelegate: appDelegate))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Make TMDB movies and TV series available in iOS Spotlight search.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Toggle("Index all available titles", isOn: $model.fullIndex).disabled(model.busy)
                if !model.fullIndex {
                    Stepper("Maximum titles: \(model.limit.formatted())", value: $model.limit, in: 1_000...150_000, step: 5_000)
                        .disabled(model.busy)
                }
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
                Text("A manual sync continues in the background with a system progress Live Activity. Poster covers are cached locally for Spotlight; a full sync downloads every available cover. iOS can still stop work under resource pressure, and the saved checkpoint lets you resume safely.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding().navigationTitle("TMDB Spotlight")
        }
    }
}
