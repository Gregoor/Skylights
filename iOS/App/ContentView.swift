import SwiftUI
import CoreSpotlight
#if canImport(UIKit)
import UIKit
typealias SkylightsImage = UIImage
extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#else
import AppKit
typealias SkylightsImage = NSImage
extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#endif

private extension ToolbarItemPlacement {
    static var skylightsTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
    static var skylightsLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .cancellationAction
        #endif
    }
}

private extension View {
    @ViewBuilder func skylightsHideNavigationBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
    @ViewBuilder func skylightsInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    @ViewBuilder func skylightsDisableAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
    @ViewBuilder func skylightsCapsuleGlass() -> some View {
        #if os(iOS)
        self.glassEffect(.regular, in: Capsule())
        #else
        if #available(macOS 26.0, *) { self.glassEffect(.regular, in: Capsule()) }
        else { self.background(.ultraThinMaterial, in: Capsule()) }
        #endif
    }
    @ViewBuilder func skylightsCircleGlass() -> some View {
        #if os(iOS)
        self.glassEffect(.regular, in: Circle())
        #else
        if #available(macOS 26.0, *) { self.glassEffect(.regular, in: Circle()) }
        else { self.background(.ultraThinMaterial, in: Circle()) }
        #endif
    }
    @ViewBuilder func skylightsURLKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.URL)
        #else
        self
        #endif
    }
}

@MainActor
final class SyncModel: ObservableObject {
    @Published var message = "Ready to index TMDB titles in Spotlight."
    @Published var busy = false
    @Published var progress = 0.0
    @Published var logText = ""
    private let logger = DiagnosticLog()
    lazy var popfeedLiveSync = PopfeedLiveSync(logger: logger)
    lazy var popfeedRecordSync = PopfeedRecordSync(logger: logger)
    private let appDelegate: AppDelegate
    private let automaticCheckKey = "spotlight.automaticCheck.lastSuccess"
    private let automaticCheckInterval: TimeInterval = 6 * 60 * 60

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        logText = logger.tail
    }

    func startPopfeedLiveSyncIfConfigured() {
        guard let did = UserDefaults.standard.string(forKey: "popfeed.sync.did"), !did.isEmpty else { return }
        popfeedLiveSync.start(did: did)
    }

    func refreshLog() { logText = logger.tail }

    func sync() {
        guard !busy else { return }
        busy = true
        progress = 0
        message = "Starting sync…"
        do {
            try appDelegate.startFullIndex(limit: nil, progress: { [weak self] done, total, text in
                Task { @MainActor [weak self] in
                    self?.progress = total == 0 ? 0 : Double(done) / Double(total)
                    self?.message = text
                    self?.logText = self?.logger.tail ?? ""
                }
            }, completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let result):
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.automaticCheckKey)
                    self.message = result.incremental
                        ? "Updated \(result.indexed) changed titles (\(result.movies) movies, \(result.series) series)."
                        : "Indexed \(result.indexed) titles (\(result.movies) movies, \(result.series) series)."
                    self.logger.write("UI", "Sync complete: incremental=\(result.incremental), indexed=\(result.indexed), movies=\(result.movies), series=\(result.series), skippedByLimit=\(result.skippedByLimit)")
                case .failure(let error):
                    self.message = error is CancellationError
                        ? "Indexing paused. Your checkpoint is saved; tap Sync TMDB index to resume."
                        : "Sync failed: \(error.localizedDescription)"
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

    func checkForUpdatesIfDue() {
        guard !busy else {
            logger.write("INFO", "Foreground update check skipped: another sync is active")
            return
        }
        let lastSuccess = UserDefaults.standard.double(forKey: automaticCheckKey)
        let elapsed = Date().timeIntervalSince1970 - lastSuccess
        guard lastSuccess == 0 || elapsed >= automaticCheckInterval else {
            logger.write("INFO", "Foreground update check skipped: last successful check was \(Int(elapsed / 60)) minutes ago")
            return
        }

        busy = true
        progress = 0
        message = "Checking for TMDB updates…"
        logger.write("INFO", "Starting throttled foreground incremental check; lastSuccessEpoch=\(lastSuccess == 0 ? "never" : String(Int(lastSuccess)))")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await SpotlightIndexer(logger: self.logger).sync(limit: nil, incrementalOnly: true) { [weak self] done, total, text in
                    Task { @MainActor [weak self] in
                        self?.progress = total == 0 ? 0 : Double(done) / Double(total)
                        self?.message = text
                        self?.logText = self?.logger.tail ?? ""
                    }
                }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.automaticCheckKey)
                self.message = result.indexed == 0
                    ? "Spotlight is already current."
                    : "Updated \(result.indexed) changed titles (\(result.movies) movies, \(result.series) series)."
                self.logger.write("UI", "Foreground check complete: indexed=\(result.indexed), movies=\(result.movies), series=\(result.series)")
            } catch {
                if error is IndexerError, case IndexerError.fullRebuildRequired = error {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.automaticCheckKey)
                    self.message = "A full sync is needed. Tap Sync TMDB index to rebuild."
                } else {
                    self.message = "Update check failed: \(error.localizedDescription)"
                }
                self.logger.write("ERROR", "Foreground incremental check failed: \(String(reflecting: error))")
            }
            self.logText = self.logger.tail
            self.busy = false
        }
    }
}

struct ContentView: View {
    @StateObject private var model: SyncModel
    @StateObject private var reviewChangeController: UnsavedReviewChangeController
    @ObservedObject private var appDelegate: AppDelegate
    @ObservedObject private var popfeedRecordSync: PopfeedRecordSync
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: SpotlightTitle?
    @State private var availableWidth: CGFloat = .greatestFiniteMagnitude
    @State private var lastSplitLayout: Bool?
    @State private var compactPath: [SpotlightTitle] = []
    @State private var showSyncSettings = false
    @State private var query = ""
    @State private var results: [SpotlightTitle] = []
    @State private var indexedReviewTitles: [String: SpotlightTitle] = [:]
    @State private var searching = false
    @State private var searchError: String?
    @State private var didPrepareSpotlightSearch = false
    @State private var resultsAtTop = true
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool
    @Namespace private var resultTransitionNamespace

    private var usesSplitLayout: Bool {
        shouldUseSplitLayout(for: availableWidth)
    }

    private func shouldUseSplitLayout(for width: CGFloat) -> Bool {
        guard width >= 900 else { return false }
        #if os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }
    private var isShowingCompactDetail: Bool { !usesSplitLayout && selection != nil }
    private var columnSeparatorColor: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let model = SyncModel(appDelegate: appDelegate)
        _model = StateObject(wrappedValue: model)
        _reviewChangeController = StateObject(wrappedValue: UnsavedReviewChangeController(writes: model.popfeedRecordSync))
        _popfeedRecordSync = ObservedObject(wrappedValue: model.popfeedRecordSync)
    }

    private var guardedCompactPath: Binding<[SpotlightTitle]> {
        Binding(get: { compactPath }, set: { proposedPath in
            let proposed = proposedPath.last
            reviewChangeController.requestNavigation(to: proposed) {
                compactPath = proposedPath
                selection = proposed
            }
        })
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if usesSplitLayout {
                    NavigationSplitView {
                        searchColumn
                    } detail: {
                        detailColumn
                    }
                    .navigationSplitViewStyle(.balanced)
                    #if os(macOS)
                    .searchable(text: $query, isPresented: $searchPresented, placement: .toolbar, prompt: "Movies and TV series")
                    .searchFocused($searchFocused)
                    .onChange(of: query) { _, text in
                        if !text.isEmpty { searchPresented = true }
                    }
                    .onChange(of: searchFocused) { _, isFocused in
                        if !isFocused && query.isEmpty { searchPresented = false }
                    }
                    #else
                    .searchable(text: $query, placement: .toolbar, prompt: "Movies and TV series")
                    .searchToolbarBehavior(.minimize)
                    .searchFocused($searchFocused)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            syncButton
                        }
                    }
                } else {
                    NavigationStack(path: guardedCompactPath) {
                        searchColumn
                            .navigationDestination(for: SpotlightTitle.self) { title in
                                detailView(for: title)
                            }
                    }
                }
            }
            .onAppear { updateAvailableWidth(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in updateAvailableWidth(width) }
            .onChange(of: horizontalSizeClass) { _, _ in updateAvailableWidth(geometry.size.width) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !usesSplitLayout {
                searchBar
            }
        }
        .onOpenURL { url in
            guard url.scheme == "net.jsdelivr.cdn", url.path == "/oauth/callback" else { return }
            Task { await model.popfeedRecordSync.completeLogin(callback: url) }
        }
        .sheet(isPresented: $showSyncSettings) {
            #if os(macOS)
            SyncSettingsView(model: model)
            #else
            NavigationStack {
                SyncSettingsView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .skylightsTrailing) {
                            Button("Done") { showSyncSettings = false }
                        }
                    }
            }
            #endif
        }
        .task {
            guard !didPrepareSpotlightSearch else { return }
            didPrepareSpotlightSearch = true
            CSUserQuery.prepare()
            appDelegate.logger.write("INFO", "Prepared Core Spotlight user search")
        }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { results = []; searchError = nil; searching = false; return }
            do {
                // Keep current rows visible while typing and while Spotlight prepares
                // results for the debounced query.
                searching = true
                searchError = nil
                try await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let started = Date()
                let context = CSUserQueryContext()
                context.fetchAttributes = ["title", "contentDescription", "contentType", "rating", "thumbnailData", "keywords"]
                context.maxResultCount = 60
                context.maxSuggestionCount = 0
                context.enableRankedResults = true
                let spotlightQuery = CSUserQuery(userQueryString: text, userQueryContext: context)
                var identifiers: [String] = []
                var hits: [SpotlightTitle] = []
                try await withTaskCancellationHandler {
                    for try await response in spotlightQuery.responses {
                        guard !Task.isCancelled else { break }
                        if case .item(let item) = response {
                            let searchableItem = item.item
                            let identifier = searchableItem.uniqueIdentifier
                            identifiers.append(identifier)
                            guard
                                let separator = identifier.firstIndex(of: "-"),
                                let tmdbID = UInt32(identifier[identifier.index(after: separator)...]),
                                let title = searchableItem.attributeSet.title
                            else { continue }
                            let mediaType: UInt8
                            switch String(identifier[..<separator]) {
                            case "movie": mediaType = 0
                            case "tv": mediaType = 1
                            default: continue
                            }
                            let descriptionParts = searchableItem.attributeSet.contentDescription?.components(separatedBy: " · ") ?? []
                            let year = descriptionParts.dropFirst().first.flatMap(UInt16.init) ?? 0
                            let rating = searchableItem.attributeSet.rating.map { UInt8(max(0, min(100, ($0.doubleValue * 10).rounded()))) }
                            let descriptionScore = descriptionParts.first(where: { $0.contains("%") }).flatMap { part -> UInt8? in
                                UInt8(part.filter(\.isNumber))
                            }
                            let score = rating ?? descriptionScore
                            let thumbnailData = searchableItem.attributeSet.thumbnailData
                            let keywords = searchableItem.attributeSet.keywords ?? []
                            let posterPath = SpotlightIndexer.keywordValue("poster", in: keywords) ?? ""
                            let votes = UInt32(SpotlightIndexer.keywordValue("votes", in: keywords) ?? "0") ?? 0
                            let seasons = UInt16(SpotlightIndexer.keywordValue("seasons", in: keywords) ?? "0") ?? 0
                            hits.append(SpotlightTitle(mediaType: mediaType, tmdbID: tmdbID, title: title, year: year, posterPath: posterPath, rottenTomatoesScore: score, voteCount: votes, blurredPosterData: thumbnailData, spotlightQuery: text, seasonCount: seasons))
                        }
                    }
                } onCancel: {
                    spotlightQuery.cancel()
                }
                guard !Task.isCancelled else { return }
                results = Self.reranked(hits, for: text)
                searching = false
                appDelegate.logger.write("INFO", "Core Spotlight search finished: queryLength=\(text.count), hits=\(identifiers.count), elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                searchError = "Core Spotlight search failed: \(error.localizedDescription)"
                appDelegate.logger.write("ERROR", "Core Spotlight search failed: queryLength=\(text.count), error=\(String(reflecting: error))")
                searching = false
            }
        }
        .onChange(of: appDelegate.selectedTitle?.id, initial: true) { _, _ in
            guard let selected = appDelegate.selectedTitle else { return }
            appDelegate.logger.write("INFO", "Navigating to native detail view: id=\(selected.id), titleAvailable=\(!selected.title.isEmpty)")
            requestSelection(selected)
            appDelegate.selectedTitle = nil
        }
        .onAppear { appDelegate.reviewChangeController = reviewChangeController }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            if newPhase == .active {
                model.checkForUpdatesIfDue()
                model.startPopfeedLiveSyncIfConfigured()
            } else {
                model.popfeedLiveSync.stop()
            }
        }
        #if os(macOS)
        .background {
            WindowCloseGuard(controller: reviewChangeController)
                .frame(width: 1, height: 1)
                .hidden()
        }
        #endif
    }

    private func updateAvailableWidth(_ width: CGFloat) {
        let isSplit = shouldUseSplitLayout(for: width)
        if lastSplitLayout != isSplit {
            compactPath = isSplit ? [] : (selection.map { [$0] } ?? [])
        }
        availableWidth = width
        lastSplitLayout = isSplit
    }

    private func requestSelection(_ proposed: SpotlightTitle?) {
        reviewChangeController.requestNavigation(to: proposed) {
            commitSelection(proposed)
        }
    }

    private func commitSelection(_ proposed: SpotlightTitle?) {
        selection = proposed
        if !usesSplitLayout {
            compactPath = proposed.map { [$0] } ?? []
        }
    }

    private var searchColumn: some View {
            VStack(spacing: 0) {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchResultsList(expandOnlyWhenAtTop: false) {
                        Section {
                            if popfeedRecordSync.reviews.isEmpty {
                                ContentUnavailableView("No Reviews Yet", systemImage: "star", description: Text("Your Popfeed reviews will show here."))
                                    .listRowSeparator(.hidden)
                            } else {
                                ForEach(popfeedRecordSync.reviews) { review in
                                    let title = indexedReviewTitles[review.title.id] ?? review.title
                                    if usesSplitLayout {
                                        SelectableTitleRow(isSelected: selection?.id == title.id) {
                                            requestSelection(title)
                                        } content: {
                                            YourReviewRow(
                                                review: review,
                                                indexedTitle: indexedReviewTitles[review.title.id],
                                                onTitleResolved: { resolvedTitle in
                                                    indexedReviewTitles[review.title.id] = resolvedTitle
                                                    if selection?.id == review.title.id { commitSelection(resolvedTitle) }
                                                },
                                                logger: appDelegate.logger,
                                                transitionNamespace: resultTransitionNamespace
                                            )
                                        }
                                    } else {
                                        NavigationLink(value: title) {
                                            YourReviewRow(
                                                review: review,
                                                indexedTitle: indexedReviewTitles[review.title.id],
                                                onTitleResolved: { resolvedTitle in
                                                    indexedReviewTitles[review.title.id] = resolvedTitle
                                                    if selection?.id == review.title.id { commitSelection(resolvedTitle) }
                                                },
                                                logger: appDelegate.logger,
                                                transitionNamespace: resultTransitionNamespace
                                            )
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("Your reviews")
                        }
                    }
                } else {
                    searchResultsList(expandOnlyWhenAtTop: true) {
                        if results.isEmpty && !searching {
                            ContentUnavailableView {
                                Label(searchError == nil ? "No Results" : "Search Unavailable", systemImage: searchError == nil ? "magnifyingglass" : "exclamationmark.magnifyingglass")
                            } description: {
                                Text(searchError ?? "No matching titles are available in the Spotlight index yet. Sync the TMDB index and try again.")
                            }
                            .listRowSeparator(.hidden)
                        } else {
                            ForEach(results) { title in
                                if usesSplitLayout {
                                    SelectableTitleRow(isSelected: selection?.id == title.id) {
                                        requestSelection(title)
                                    } content: {
                                        SearchResultRow(title: title, logger: appDelegate.logger, transitionNamespace: resultTransitionNamespace)
                                    }
                                } else {
                                    NavigationLink(value: title) {
                                        SearchResultRow(title: title, logger: appDelegate.logger, transitionNamespace: resultTransitionNamespace)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .navigationSplitViewColumnWidth(min: 360, ideal: 400, max: 480)
    }

    private func searchResultsList<Content: View>(
        expandOnlyWhenAtTop: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        List { content() }
            .listStyle(.sidebar)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y <= -geometry.contentInsets.top + 1
            } action: { _, isAtTop in
                resultsAtTop = isAtTop
            }
            .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { gesture in
                guard selection == nil, abs(gesture.translation.width) < 45 else { return }
                if gesture.translation.height < -35 {
                    searchFocused = false
                } else if gesture.translation.height > 60 && (!expandOnlyWhenAtTop || resultsAtTop) {
                    searchFocused = true
                }
            })
    }

    private var detailColumn: some View {
        Group {
            if let title = selection {
                detailView(for: title)
            } else {
                ContentUnavailableView("Select a title", systemImage: "film", description: Text("Choose a movie or TV series from search."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .leading) {
            Rectangle().fill(columnSeparatorColor).frame(width: 1).allowsHitTesting(false)
        }
    }

    @ViewBuilder private func detailView(for title: SpotlightTitle) -> some View {
        let detail = TitleDetailView(title: title, logger: appDelegate.logger, writes: model.popfeedRecordSync) { id, draft in
            reviewChangeController.updateDraft(draft, for: id)
        }
        if usesSplitLayout {
            detail
        } else {
            detail
            #if os(iOS)
            .navigationTransition(.zoom(sourceID: title.id, in: resultTransitionNamespace))
            #endif
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .animation(.smooth(duration: 0.22), value: selection?.id)
        }
    }


    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                if isShowingCompactDetail {
                    Button {
                        searchFocused = false
                        requestSelection(nil)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 24, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to search")
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    TextField("Movies and TV series", text: $query)
                        .focused($searchFocused)
                        .skylightsDisableAutocapitalization()
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    if !query.isEmpty {
                        Button {
                            query = ""
                            if usesSplitLayout { requestSelection(nil) }
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                                .frame(width: 24, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                if selection != nil && (isShowingCompactDetail || query.isEmpty) {
                    Button {
                        requestSelection(nil)
                        if isShowingCompactDetail { query = "" }
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 24, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear selected title")
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .overlay {
                if isShowingCompactDetail, let selected = selection {
                    Text(selected.title)
                        .font(.body)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 52)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .skylightsCapsuleGlass()
            .animation(.easeInOut(duration: 0.2), value: selection?.id)

            syncButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var syncButton: some View {
        Button {
            searchFocused = false
            showSyncSettings = true
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sync and diagnostics")
    }

    private static func reranked(_ titles: [SpotlightTitle], for query: String) -> [SpotlightTitle] {
        let items = titles.map {
            SpotlightRankingItem(
                id: $0.id,
                title: $0.title,
                year: Int($0.year),
                voteCount: Int($0.voteCount),
                rottenTomatoesScore: $0.rottenTomatoesScore.map(Int.init)
            )
        }
        let byID = Dictionary(uniqueKeysWithValues: titles.map { ($0.id, $0) })
        return SpotlightRanking.orderedIDs(items, for: query).compactMap { byID[$0] }
    }
}

#if os(macOS)
struct UnsavedReviewDraft {
    let title: SpotlightTitle
    let rating: Int?
    let text: String
    let originalRating: Int?
    let originalText: String
}

@MainActor
final class UnsavedReviewChangeController: NSObject, ObservableObject, NSWindowDelegate {
    private enum PromptChoice { case save, discard, cancel }
    private enum PendingAction { case navigate(() -> Void), closeWindow, terminate }

    @Published private var currentDraft: UnsavedReviewDraft?
    private let writes: PopfeedRecordSync
    private weak var window: NSWindow?
    private weak var previousWindowDelegate: NSWindowDelegate?
    private var pendingAction: PendingAction?
    private var isPromptPresented = false
    private var allowNextClose = false

    init(writes: PopfeedRecordSync) {
        self.writes = writes
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previousWindowDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let previousWindowDelegate, previousWindowDelegate.responds(to: selector) {
            return previousWindowDelegate
        }
        return super.forwardingTarget(for: selector)
    }

    var hasUnsavedChanges: Bool { currentDraft != nil }

    func updateDraft(_ draft: UnsavedReviewDraft?, for titleID: String) {
        if let draft {
            currentDraft = draft
        } else if currentDraft?.title.id == titleID {
            currentDraft = nil
        }
    }

    func requestNavigation(to proposed: SpotlightTitle?, proceed: @escaping () -> Void) {
        guard !isPromptPresented else { return }
        guard let draft = currentDraft, draft.title.id != proposed?.id else {
            proceed()
            return
        }
        presentPrompt(for: draft, reason: "switching to another title", action: .navigate(proceed))
    }

    func requestTermination() {
        guard let draft = currentDraft, !isPromptPresented else { return }
        presentPrompt(for: draft, reason: "quitting Skylights", action: .terminate)
    }

    func attach(to window: NSWindow) {
        if self.window !== window {
            self.window = window
            previousWindowDelegate = window.delegate
        } else if window.delegate !== self {
            previousWindowDelegate = window.delegate
        }
        if window.delegate !== self { window.delegate = self }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowNextClose {
            allowNextClose = false
            return previousWindowDelegate?.windowShouldClose?(sender) ?? true
        }
        guard let draft = currentDraft else {
            return previousWindowDelegate?.windowShouldClose?(sender) ?? true
        }
        guard !isPromptPresented else { return false }
        window = sender
        presentPrompt(for: draft, reason: "closing this window", action: .closeWindow)
        return false
    }

    private func presentPrompt(for draft: UnsavedReviewDraft, reason: String, action: PendingAction) {
        guard let window = window ?? NSApp.keyWindow else { return }
        isPromptPresented = true
        pendingAction = action

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unsaved Review"
        alert.informativeText = "Save your changes to “\(draft.title.title)” before \(reason)?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let choice: PromptChoice
            switch response {
            case .alertFirstButtonReturn: choice = .save
            case .alertSecondButtonReturn: choice = .discard
            default: choice = .cancel
            }
            self.resolvePrompt(choice, draft: draft)
        }
    }

    private func resolvePrompt(_ choice: PromptChoice, draft: UnsavedReviewDraft) {
        guard let action = pendingAction else { return }
        pendingAction = nil

        guard choice != .cancel else {
            isPromptPresented = false
            return
        }

        Task { @MainActor in
            if choice == .save {
                await writes.saveReview(for: draft.title, rating: draft.rating, text: draft.text)
            }
            updateDraft(nil, for: draft.title.id)
            isPromptPresented = false

            switch action {
            case .navigate(let proceed): proceed()
            case .closeWindow:
                allowNextClose = true
                window?.performClose(nil)
            case .terminate:
                NSApp.terminate(nil)
            }
        }
    }
}

private final class WindowCloseGuardNSView: NSView {
    var controller: UnsavedReviewChangeController? {
        didSet { if let window { controller?.attach(to: window) } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { controller?.attach(to: window) }
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let controller: UnsavedReviewChangeController

    func makeNSView(context: Context) -> WindowCloseGuardNSView {
        let view = WindowCloseGuardNSView(frame: .zero)
        view.controller = controller
        return view
    }

    func updateNSView(_ nsView: WindowCloseGuardNSView, context: Context) {
        nsView.controller = controller
    }
}
#endif

private enum SearchPosterLayout {
    case square
    case portrait

    var size: CGSize {
        switch self {
        case .square: CGSize(width: 62, height: 62)
        case .portrait: CGSize(width: 54, height: 81)
        }
    }
}

private struct SearchTitleMetadata: View {
    let title: SpotlightTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.title).font(.headline).lineLimit(2)
            TitleMetadataDetails(title: title)
        }
    }
}

private struct TitleMetadataDetails: View {
    let title: SpotlightTitle

    var body: some View {
        HStack(spacing: 5) {
            Text([title.isMovie ? "Movie" : "TV series", title.year > 0 ? String(title.year) : nil, !title.isMovie && title.seasonCount > 0 ? "\(title.seasonCount) seasons" : nil].compactMap { $0 }.joined(separator: " · "))
            if let score = title.rottenTomatoesScore {
                Text("·")
                    .accessibilityHidden(true)
                Image(score >= 60 ? "RottenTomatoesFresh" : "RottenTomatoesRotten")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)
                Text("\(score)%")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct TitlePosterPlaceholder: View {
    let title: SpotlightTitle
    var iconFont: Font = .body
    var cachedBlurData: Data? = nil

    var body: some View {
        Group {
            if let data = cachedBlurData ?? title.blurredPosterData, let image = SkylightsImage(data: data) {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary).overlay {
                    Image(systemName: title.isMovie ? "film" : "tv")
                        .font(iconFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TitlePosterThumbnail: View {
    let title: SpotlightTitle
    let logger: DiagnosticLog
    let transitionNamespace: Namespace.ID
    let layout: SearchPosterLayout

    var body: some View {
        ProgressivePosterImage(
            titleID: title.id,
            blurredURL: title.blurredPosterURL,
            fullURL: title.miniPosterURL,
            cachedBlurData: title.blurredPosterData,
            logger: logger,
            placeholder: TitlePosterPlaceholder(title: title)
        )
        .frame(width: layout.size.width, height: layout.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .matchedTransitionSource(id: title.id, in: transitionNamespace)
    }
}

private struct SearchResultRow: View {
    let title: SpotlightTitle
    let logger: DiagnosticLog
    let transitionNamespace: Namespace.ID

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TitlePosterThumbnail(title: title, logger: logger, transitionNamespace: transitionNamespace, layout: .square)
            SearchTitleMetadata(title: title)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

}

private struct SelectableTitleRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            content()
                .environment(\.colorScheme, isSelected ? .dark : colorScheme)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isSelected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct YourReviewRow: View {
    let review: PopfeedReview
    let indexedTitle: SpotlightTitle?
    let onTitleResolved: (SpotlightTitle) -> Void
    let logger: DiagnosticLog
    let transitionNamespace: Namespace.ID

    private var displayedTitle: SpotlightTitle { indexedTitle ?? review.title }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TitlePosterThumbnail(title: displayedTitle, logger: logger, transitionNamespace: transitionNamespace, layout: .portrait)

            VStack(alignment: .leading, spacing: 5) {
                SearchTitleMetadata(title: displayedTitle)
                HStack(spacing: 8) {
                    if let rating = review.rating {
                        ReviewRatingStars(rating: rating)
                    }
                    Text(review.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !review.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(review.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .task(id: review.title.id) {
            guard indexedTitle == nil else { return }
            let lookupID = review.seriesTMDBID.map { "tv-\($0)" } ?? review.title.id
            let lookupTMDBID = review.seriesTMDBID ?? review.title.tmdbID
            guard let title = await SpotlightIndexer.indexedTitle(
                identifier: lookupID,
                query: "TMDB \(lookupTMDBID)",
                logger: logger
            ) else { return }
            // Season reviews have their own review identity and poster, while the local
            // Spotlight index contains the parent series. Borrow series metadata only for
            // missing fields, retaining the season ID, title and artwork from Popfeed.
            let resolved = SpotlightTitle(
                mediaType: review.title.mediaType,
                tmdbID: review.title.tmdbID,
                title: review.title.title,
                year: review.title.year > 0 ? review.title.year : title.year,
                posterPath: review.title.posterPath.isEmpty ? title.posterPath : review.title.posterPath,
                rottenTomatoesScore: title.rottenTomatoesScore,
                voteCount: title.voteCount,
                blurredPosterData: title.blurredPosterData,
                seasonCount: title.seasonCount,
                posterURLOverride: review.title.posterURLOverride
            )
            onTitleResolved(resolved)
        }
    }

}

private struct ReviewRatingStars: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: RatingSymbol.name(for: star, rating: rating))
                    .foregroundStyle(.yellow)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let value = rating.isMultiple(of: 2) ? String(rating / 2) : String(format: "%.1f", Double(rating) / 2)
        return "Rated \(value) out of 5 stars"
    }
}

private enum RatingSymbol {
    static func name(for star: Int, rating: Int) -> String {
        if rating >= star * 2 { return "star.fill" }
        if rating == star * 2 - 1 { return "star.leadinghalf.filled" }
        return "star"
    }
}

@MainActor
private struct ProgressivePosterImage<Placeholder: View>: View {
    let titleID: String
    let blurredURL: URL?
    let fullURL: URL?
    let cachedBlurData: Data?
    let logger: DiagnosticLog
    let placeholder: Placeholder
    @State private var blurredImage: SkylightsImage?
    @State private var fullImage: SkylightsImage?
    @State private var revealsFullImage = false

    private var taskID: String { "\(titleID)|\(blurredURL?.absoluteString ?? "")|\(fullURL?.absoluteString ?? "")" }

    var body: some View {
        ZStack {
            if let blurredImage {
                Image(platformImage: blurredImage).resizable().scaledToFill()
            } else {
                placeholder
            }
            if let fullImage {
                Image(platformImage: fullImage)
                    .resizable()
                    .scaledToFill()
                    .opacity(revealsFullImage ? 1 : 0)
            }
        }
        .task(id: taskID) {
            blurredImage = cachedBlurData.flatMap { SkylightsImage(data: $0) }
            if let fullURL, let cachedImage = PosterImageMemoryCache.image(for: fullURL) {
                fullImage = cachedImage
                revealsFullImage = true
                return
            }
            fullImage = nil
            revealsFullImage = false

            let blurTask: Task<Void, Never>?
            if blurredImage == nil, let blurredURL {
                blurTask = Task { @MainActor in
                    let started = Date()
                    do {
                        let (data, response) = try await PosterThumbnailService.fetch(blurredURL)
                        guard !Task.isCancelled, let image = SkylightsImage(data: data) else { return }
                        // Don't replace a local blur or a full image that has already appeared.
                        guard blurredImage == nil, !revealsFullImage else { return }
                        blurredImage = image
                        let cache = response.value(forHTTPHeaderField: "X-Poster-Cache") ?? "unknown"
                        logger.write("INFO", "Blurred result poster ready: id=\(titleID), cache=\(cache), bytes=\(data.count), elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
                    } catch {
                        guard !Task.isCancelled else { return }
                        logger.write("WARN", "Blurred result poster failed: id=\(titleID), error=\(String(reflecting: error))")
                    }
                }
            } else {
                blurTask = nil
            }
            defer { blurTask?.cancel() }

            guard let fullURL else { return }
            let started = Date()
            do {
                let (data, _) = try await PosterThumbnailService.fetch(fullURL)
                guard !Task.isCancelled, let image = SkylightsImage(data: data) else { return }
                PosterImageMemoryCache.insert(image, for: fullURL)
                if blurredImage == nil,
                   let fallbackData = await Task.detached(priority: .userInitiated, operation: {
                       SpotlightIndexer.preblurredPoster(from: data)
                   }).value,
                   let fallbackImage = SkylightsImage(data: fallbackData) {
                    blurredImage = fallbackImage
                }
                fullImage = image
                logger.write("INFO", "Full result poster ready: id=\(titleID), bytes=\(data.count), elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.45)) { revealsFullImage = true }
            } catch {
                guard !Task.isCancelled else { return }
                logger.write("WARN", "Full result poster failed: id=\(titleID), error=\(String(reflecting: error))")
            }
        }
    }
}

private struct SyncSettingsView: View {
    @ObservedObject var model: SyncModel
    @ObservedObject private var popfeedRecordSync: PopfeedRecordSync
    @State private var selection: SyncDestination? = .spotlight
    @Environment(\.dismiss) private var dismiss

    init(model: SyncModel) {
        self.model = model
        _popfeedRecordSync = ObservedObject(wrappedValue: model.popfeedRecordSync)
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Sync").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            NavigationSplitView {
                List(selection: $selection) {
                    Section("Services") {
                        Label("TMDB index", systemImage: "magnifyingglass")
                            .tag(SyncDestination.spotlight)
                        Label("Popfeed", systemImage: "arrow.triangle.2.circlepath")
                            .tag(SyncDestination.popfeed)
                    }
                    Section("Developer") {
                        Label("Diagnostics", systemImage: "stethoscope")
                            .tag(SyncDestination.diagnostics)
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 250)
            } detail: {
                Group {
                    switch selection {
                    case .spotlight:
                        SpotlightSyncSettingsView(model: model)
                    case .popfeed:
                        PopfeedSyncSettingsView(model: model)
                    case .diagnostics:
                        SyncDiagnosticsView(model: model)
                    case nil:
                        ContentUnavailableView("Choose a sync area", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 980, minHeight: 600)
        #else
        List {
            Section("Services") {
                NavigationLink {
                    SpotlightSyncSettingsView(model: model)
                } label: {
                    SyncDestinationRow(
                        title: "TMDB index",
                        detail: model.busy ? "Indexing titles…" : "Spotlight search index",
                        systemImage: "magnifyingglass"
                    )
                }
                NavigationLink {
                    PopfeedSyncSettingsView(model: model)
                } label: {
                    SyncDestinationRow(
                        title: "Popfeed",
                        detail: popfeedRecordSync.connected ? "Account connected" : "Account and live sync",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
            }

            Section("Developer") {
                NavigationLink {
                    SyncDiagnosticsView(model: model)
                } label: {
                    SyncDestinationRow(
                        title: "Diagnostics",
                        detail: "Logs and indexing details",
                        systemImage: "stethoscope"
                    )
                }
            }
        }
        .navigationTitle("Sync")
        .skylightsInlineNavigationTitle()
        #endif
    }
}

private enum SyncDestination: Hashable {
    case spotlight
    case popfeed
    case diagnostics
}

private struct SyncDestinationRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage).frame(width: 24)
        }
        .padding(.vertical, 3)
    }
}

private struct SpotlightSyncSettingsView: View {
    @ObservedObject var model: SyncModel

    var body: some View {
        Form {
            Section {
                Button(action: model.sync) {
                    Label(model.busy ? "Indexing…" : "Sync TMDB index", systemImage: "arrow.triangle.2.circlepath")
                        #if os(iOS)
                        .frame(maxWidth: .infinity)
                        #endif
                }.buttonStyle(.borderedProminent).disabled(model.busy)
                ProgressView(value: model.progress)
                Text(model.message).font(.callout)
            } header: { Text("Spotlight index") } footer: {
                Text("The app streams every published title into Spotlight. Apple manages Spotlight storage and may evict items.")
            }
        }
        .navigationTitle("TMDB index")
        .skylightsInlineNavigationTitle()
    }
}

private struct PopfeedSyncSettingsView: View {
    @ObservedObject private var popfeedLiveSync: PopfeedLiveSync
    @ObservedObject private var popfeedRecordSync: PopfeedRecordSync
    @State private var popfeedDID = UserDefaults.standard.string(forKey: "popfeed.sync.did") ?? ""
    @State private var jetstreamAPIKey = ""
    @State private var keyIsSaved = false
    @State private var credentialMessage: String?
    @State private var writeMessage: String?
    private let credentialStore = JetstreamCredentialStore()

    init(model: SyncModel) {
        _popfeedLiveSync = ObservedObject(wrappedValue: model.popfeedLiveSync)
        _popfeedRecordSync = ObservedObject(wrappedValue: model.popfeedRecordSync)
    }

    var body: some View {
        Form {
            Section {
                TextField("Account DID (did:plc:…)", text: $popfeedDID)
                    .skylightsDisableAutocapitalization()
                    .autocorrectionDisabled()
                    .skylightsURLKeyboard()
                    .disabled(popfeedLiveSync.isRunning)
                    .onChange(of: popfeedDID) { _, value in
                        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "popfeed.sync.did")
                    }
                SecureField(keyIsSaved ? "Jetstream API key (saved)" : "Jetstream API key", text: $jetstreamAPIKey)
                    .skylightsDisableAutocapitalization()
                    .autocorrectionDisabled()
                HStack {
                    Button("Save key") { saveJetstreamKey() }
                        .disabled(jetstreamAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if keyIsSaved {
                        Button("Remove", role: .destructive) { removeJetstreamKey() }
                    }
                }
                if let credentialMessage {
                    Text(credentialMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Live sync") } footer: {
                Text("The DID and Jetstream key configure read sync. The API key is stored in Keychain.")
            }

            Section {
                HStack {
                    Label("\(popfeedLiveSync.recordCount) Popfeed records on device", systemImage: "tray.full")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Sync now") {
                        popfeedLiveSync.restart(did: popfeedDID)
                    }
                    .buttonStyle(.bordered)
                }
                Text(popfeedLiveSync.message).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Local Popfeed data") }

            Section {
                Label(popfeedRecordSync.connected ? "Write access connected" : "Write access not connected", systemImage: popfeedRecordSync.connected ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                    .font(.subheadline)
                HStack {
                    if popfeedRecordSync.connected {
                        Button("Sync writes") { Task { await popfeedRecordSync.synchronize() } }
                        Button("Disconnect", role: .destructive) { popfeedRecordSync.disconnect() }
                    } else {
                        Button("Connect Popfeed") {
                            Task {
                                do {
                                    let url = try await popfeedRecordSync.beginLogin(did: popfeedDID)
                                    #if os(iOS)
                                    await UIApplication.shared.open(url)
                                    #else
                                    NSWorkspace.shared.open(url)
                                    #endif
                                } catch { writeMessage = error.localizedDescription }
                            }
                        }
                        .disabled(popfeedDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || popfeedRecordSync.isSyncing)
                    }
                }
                Text(popfeedRecordSync.status).font(.caption).foregroundStyle(.secondary)
                if !popfeedRecordSync.pending.isEmpty {
                    Label("\(popfeedRecordSync.pending.count) offline change(s) queued", systemImage: "arrow.trianglehead.2.clockwise")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !popfeedRecordSync.conflicts.isEmpty {
                    ForEach(popfeedRecordSync.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("This record changed on Popfeed while you were offline.").font(.caption)
                            HStack {
                                Button("Keep my change") { Task { await popfeedRecordSync.resolveConflict(conflict, useLocal: true) } }
                                Button("Use latest") { Task { await popfeedRecordSync.resolveConflict(conflict, useLocal: false) } }
                            }.buttonStyle(.bordered)
                        }
                    }
                }
                if let writeMessage { Text(writeMessage).font(.caption).foregroundStyle(.secondary) }
                Text("Sign in opens Popfeed in your browser. Skylights stores the OAuth session in Keychain; ratings, reviews and list changes queue on this device when offline.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Write access") } footer: { Text("Connect through Popfeed’s secure browser sign in.") }
        }
        .navigationTitle("Popfeed")
        .skylightsInlineNavigationTitle()
        .onAppear {
            keyIsSaved = credentialStore.read() != nil
        }
        .task {
            await popfeedRecordSync.restoreIfPossible(did: popfeedDID)
        }
    }

    private func saveJetstreamKey() {
        let value = jetstreamAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try credentialStore.write(value)
            jetstreamAPIKey = ""
            keyIsSaved = true
            credentialMessage = "API key saved securely on this device."
            let did = popfeedDID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !did.isEmpty { popfeedLiveSync.restart(did: did) }
        } catch {
            credentialMessage = "Could not save API key: \(error.localizedDescription)"
        }
    }

    private func removeJetstreamKey() {
        do {
            try credentialStore.delete()
            keyIsSaved = false
            jetstreamAPIKey = ""
            credentialMessage = "API key removed from this device."
        } catch {
            credentialMessage = "Could not remove API key: \(error.localizedDescription)"
        }
    }
}

private struct SyncDiagnosticsView: View {
    @ObservedObject var model: SyncModel

    var body: some View {
        Form {

            Section("Diagnostic log") {
                ScrollView {
                    Text(model.logText.isEmpty ? "No log entries yet." : model.logText)
                        .font(.system(.caption2, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.frame(minHeight: 160).background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Section {
                Text("Apple controls Spotlight storage and ranking, so results can be delayed or evicted. The app logs submission and error details; it cannot inspect the operating system's private index or guarantee every item is surfaced.")
                #if os(iOS)
                Text("A manual sync continues in the background with a system progress Live Activity. Titles are indexed without poster images to keep storage use low. iOS can still stop work under resource pressure, and the saved checkpoint lets you resume safely.")
                #else
                Text("A manual sync reports progress here. Titles are indexed without poster images to keep storage use low, and the saved checkpoint lets you resume safely if indexing is interrupted.")
                #endif
            } footer: {
                #if os(macOS)
                Text("Search results come from Core Spotlight. Posters load on demand from the poster service; results use the Skylights app icon to keep storage use low.")
                #else
                Text("Search results come from Core Spotlight. Posters load on demand from the poster service; the Spotlight index uses shared film and TV icons to keep storage use low.")
                #endif
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Diagnostics")
        .skylightsInlineNavigationTitle()
        .task {
            while !Task.isCancelled {
                model.refreshLog()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

private struct TitleDetailView: View {
    let title: SpotlightTitle
    let logger: DiagnosticLog
    @ObservedObject var writes: PopfeedRecordSync
    let onDraftChange: (String, UnsavedReviewDraft?) -> Void
    @State private var indexedMetadata: SpotlightTitle?
    @State private var preloadedBlurredPosterData: Data?
    @State private var rating: Int?
    @State private var initialRating: Int?
    @State private var reviewText = ""
    @State private var initialReviewText = ""
    @State private var hasEditedReview = false
    @State private var reviewEditorHeight: CGFloat = 34

    private var hasReviewChanges: Bool {
        rating != initialRating || reviewText != initialReviewText
    }

    init(
        title: SpotlightTitle,
        logger: DiagnosticLog,
        writes: PopfeedRecordSync,
        onDraftChange: @escaping (String, UnsavedReviewDraft?) -> Void
    ) {
        self.title = title
        self.logger = logger
        self.writes = writes
        self.onDraftChange = onDraftChange
        _preloadedBlurredPosterData = State(initialValue: title.blurredPosterData)
    }

    private var displayedTitle: SpotlightTitle {
        indexedMetadata?.id == title.id ? indexedMetadata! : title
    }
    private var displayedPosterURL: URL? { displayedTitle.posterURL }
    private var displayedBlurredPosterData: Data? {
        preloadedBlurredPosterData
            ?? title.blurredPosterData
            ?? (indexedMetadata?.id == title.id ? indexedMetadata?.blurredPosterData : nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        posterView
                        VStack(alignment: .leading, spacing: 16) {
                            titleMetadata
                            if writes.connected { popfeedReviewEditor }
                        }
                        .frame(minWidth: 340, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 18) {
                            posterView
                            titleMetadata
                        }
                        if writes.connected { popfeedReviewEditor }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("")
        .skylightsInlineNavigationTitle()
        .task(id: title.id) {
            loadPopfeedReview()
            publishDraft()
            // Reviews enter the detail route from the Popfeed record, which carries
            // the TMDB identity but may not carry Spotlight's poster metadata.
            // Resolve that metadata by the known ID so the detail poster can load.
            guard title.posterPath.isEmpty || title.title.isEmpty else { return }
            let query = title.spotlightQuery?.isEmpty == false
                ? title.spotlightQuery!
                : "TMDB \(title.tmdbID)"
            indexedMetadata = await SpotlightIndexer.indexedTitle(identifier: title.id, query: query, logger: logger)
        }
        .onReceive(writes.$records) { _ in
            loadPopfeedReview()
            publishDraft()
        }
        .onChange(of: rating) { _, _ in publishDraft() }
        .onChange(of: reviewText) { _, _ in publishDraft() }
            .onChange(of: title.id) { _, _ in
                hasEditedReview = false
                rating = nil
                initialRating = nil
                reviewText = ""
                initialReviewText = ""
                reviewEditorHeight = 34
                loadPopfeedReview()
            publishDraft()
            indexedMetadata = nil
            preloadedBlurredPosterData = title.blurredPosterData
        }
    }

    private func loadPopfeedReview() {
        guard !hasEditedReview else { return }
        if let review = writes.localReview(for: title) {
            rating = review.rating
            reviewText = review.text
        } else {
            rating = nil
            reviewText = ""
        }
        initialRating = rating
        initialReviewText = reviewText
    }

    private func publishDraft() {
        let draft = hasReviewChanges
            ? UnsavedReviewDraft(
                title: title,
                rating: rating,
                text: reviewText,
                originalRating: initialRating,
                originalText: initialReviewText
            )
            : nil
        onDraftChange(title.id, draft)
    }

    private func saveReview() {
        let submittedRating = rating
        let submittedText = reviewText
        initialRating = submittedRating
        initialReviewText = submittedText
        hasEditedReview = true
        publishDraft()
        Task { await writes.saveReview(for: title, rating: submittedRating, text: submittedText) }
    }

    private var titleMetadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayedTitle.title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            TitleMetadataDetails(title: displayedTitle)
        }
        .padding(.top, 4)
    }

    private var popfeedReviewEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HalfStarRatingControl(value: $rating) {
                hasEditedReview = true
            }
            .frame(width: 170, height: 42)
            ZStack(alignment: .topLeading) {
                #if os(macOS)
                GrowingReviewTextView(
                    text: $reviewText,
                    height: $reviewEditorHeight,
                    onEdit: { hasEditedReview = true }
                )
                .frame(height: reviewEditorHeight)
                .padding(6)
                #else
                TextField("Write a review", text: Binding(get: { reviewText }, set: {
                    hasEditedReview = true
                    reviewText = $0
                }), axis: .vertical)
                .lineLimit(1...8)
                .padding(8)
                #endif

                if reviewText.isEmpty {
                    Text("Write a review")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 11)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
            .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            }
            Button("Save review", action: saveReview)
                .buttonStyle(.borderedProminent)
                .disabled(!hasReviewChanges)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var posterView: some View {
        poster
            .frame(width: 150, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 8)
    }

    @ViewBuilder private var poster: some View {
        if let url = displayedPosterURL {
            DetailPosterImage(
                url: url,
                blurredURL: displayedTitle.detailBlurredPosterURL,
                cachedBlurData: displayedBlurredPosterData,
                placeholder: posterPlaceholder,
                hasBlurredPoster: displayedBlurredPosterData != nil,
                logger: logger,
                titleID: title.id
            )
                .id("\(url.absoluteString)|\(displayedTitle.detailBlurredPosterURL?.absoluteString ?? "")")
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        TitlePosterPlaceholder(title: displayedTitle, iconFont: .largeTitle, cachedBlurData: displayedBlurredPosterData)
    }

}

#if os(macOS)
private struct GrowingReviewTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let onEdit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ReviewTextScrollView {
        let scrollView = ReviewTextScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let textView = NSTextView(frame: .zero)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.setAccessibilityLabel("Write a review")
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        scrollView.onContentHeightChange = { [weak coordinator = context.coordinator] contentHeight, lineHeight in
            coordinator?.updateHeight(contentHeight: contentHeight, lineHeight: lineHeight)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: ReviewTextScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        scrollView.remeasureContent()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingReviewTextView

        init(parent: GrowingReviewTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onEdit()
            textView.enclosingScrollView.flatMap { $0 as? ReviewTextScrollView }?.remeasureContent()
        }

        func updateHeight(contentHeight: CGFloat, lineHeight: CGFloat) {
            let minimumHeight = ceil(lineHeight + 8)
            let maximumHeight = ceil(lineHeight * 8 + 8)
            let measuredHeight = min(maximumHeight, max(minimumHeight, ceil(contentHeight + 8)))
            guard abs(parent.height - measuredHeight) > 1 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.height - measuredHeight) > 1 else { return }
                self.parent.height = measuredHeight
            }
        }
    }
}

private final class ReviewTextScrollView: NSScrollView {
    var onContentHeightChange: ((CGFloat, CGFloat) -> Void)?

    override func layout() {
        super.layout()
        remeasureContent()
    }

    func remeasureContent() {
        guard
            let textView = documentView as? NSTextView,
            let textContainer = textView.textContainer,
            let layoutManager = textView.layoutManager,
            contentView.bounds.width > 0
        else { return }

        let width = contentView.bounds.width
        textView.setFrameSize(NSSize(width: width, height: max(contentView.bounds.height, 1)))
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let contentHeight = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
        let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: NSFont.systemFontSize))
        textView.setFrameSize(NSSize(width: width, height: max(contentView.bounds.height, ceil(contentHeight))))
        onContentHeightChange?(contentHeight, lineHeight)
    }
}
#endif

#if os(macOS) || os(iOS)
private struct HalfStarRatingControl: View {
    @Binding var value: Int?
    let onChange: () -> Void
    @State private var hoveredValue: Int?

    private var displayedValue: Int { hoveredValue ?? value ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                ZStack {
                    Image(systemName: symbol(for: star, rating: displayedValue))
                        .font(.system(size: 24))
                        .foregroundStyle(displayedValue >= star * 2 - 1 ? .yellow : .secondary)
                        .accessibilityHidden(true)
                    HStack(spacing: 0) {
                        ratingButton(star * 2 - 1, label: "\(Double(star) - 0.5) out of 5 stars")
                        ratingButton(star * 2, label: "\(star) out of 5 stars")
                    }
                }
                .frame(width: 34, height: 42)
            }
        }
    }

    private func symbol(for star: Int, rating: Int) -> String {
        RatingSymbol.name(for: star, rating: rating)
    }

    private func ratingButton(_ rating: Int, label: String) -> some View {
        Button {
            onChange()
            value = value == rating ? nil : rating
        } label: {
            Color.clear
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == rating ? "Clear rating" : "Set rating to \(label)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { isHovering in
            if isHovering {
                hoveredValue = rating
            } else if hoveredValue == rating {
                hoveredValue = nil
            }
        }
    }
}
#endif

private struct DetailPosterImage<Placeholder: View>: View {
    let url: URL
    let blurredURL: URL?
    let cachedBlurData: Data?
    let placeholder: Placeholder
    let hasBlurredPoster: Bool
    let logger: DiagnosticLog
    let titleID: String
    @State private var fullBlurredImage: SkylightsImage?
    @State private var sharpImage: SkylightsImage?
    @State private var revealsSharpImage = false
    @State private var sharpPosterAvailableOnMount = false
    @State private var failed = false

    init(
        url: URL,
        blurredURL: URL?,
        cachedBlurData: Data?,
        placeholder: Placeholder,
        hasBlurredPoster: Bool,
        logger: DiagnosticLog,
        titleID: String
    ) {
        self.url = url
        self.blurredURL = blurredURL
        self.cachedBlurData = cachedBlurData
        self.placeholder = placeholder
        self.hasBlurredPoster = hasBlurredPoster
        self.logger = logger
        self.titleID = titleID
        let cachedPoster = PosterImageMemoryCache.image(for: url)
        _sharpImage = State(initialValue: cachedPoster)
        _revealsSharpImage = State(initialValue: cachedPoster != nil)
        _sharpPosterAvailableOnMount = State(initialValue: cachedPoster != nil)
    }

    var body: some View {
        ZStack {
            if let fullBlurredImage {
                Image(platformImage: fullBlurredImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
            if let sharpImage {
                Image(platformImage: sharpImage)
                    .resizable()
                    .scaledToFill()
                    .opacity(revealsSharpImage ? 1 : 0)
            }
            if fullBlurredImage == nil && sharpImage == nil && !failed && !hasBlurredPoster {
                ProgressView()
            }
        }
        .task(id: "\(url.absoluteString)|\(blurredURL?.absoluteString ?? "")") {
            fullBlurredImage = cachedBlurData.flatMap { SkylightsImage(data: $0) }
            failed = false
            let started = Date()

            // A poster shown in search is already sharp and decoded in memory. Keep
            // it through the navigation transition and skip the blur/reveal path.
            if let cachedPoster = PosterImageMemoryCache.image(for: url) {
                sharpPosterAvailableOnMount = true
                sharpImage = cachedPoster
                revealsSharpImage = true
                logger.write("INFO", "Detail poster reused from search memory cache: id=\(titleID)")
                return
            }
            sharpPosterAvailableOnMount = false
            sharpImage = nil
            revealsSharpImage = false

            let blurTask: Task<Void, Never>?
            if fullBlurredImage == nil, let blurredURL {
                blurTask = Task { @MainActor in
                    let blurStarted = Date()
                    do {
                        let (data, response) = try await PosterThumbnailService.fetch(blurredURL)
                        guard !Task.isCancelled, let image = SkylightsImage(data: data) else { return }
                        guard fullBlurredImage == nil, sharpImage == nil else { return }
                        fullBlurredImage = image
                        let cache = response.value(forHTTPHeaderField: "X-Poster-Cache") ?? "unknown"
                        logger.write("INFO", "Detail blur from poster service ready: id=\(titleID), cache=\(cache), bytes=\(data.count), elapsedMs=\(Int(Date().timeIntervalSince(blurStarted) * 1000))")
                    } catch {
                        guard !Task.isCancelled else { return }
                        logger.write("WARN", "Detail blur from poster service failed: id=\(titleID), error=\(String(reflecting: error))")
                    }
                }
            } else {
                blurTask = nil
            }
            defer { blurTask?.cancel() }

            do {
                let (data, _) = try await PosterThumbnailService.fetch(url)
                guard let image = SkylightsImage(data: data) else {
                    throw URLError(.cannotDecodeContentData)
                }
                guard !Task.isCancelled else { return }
                let posterArrivedFromAnotherView = PosterImageMemoryCache.image(for: url) != nil
                PosterImageMemoryCache.insert(image, for: url)

                // If another view supplied the sharp poster while this request was
                // in flight, display it directly instead of starting a deblur.
                if sharpPosterAvailableOnMount || posterArrivedFromAnotherView {
                    sharpImage = image
                    revealsSharpImage = true
                    return
                }

                guard let blurData = await Task.detached(priority: .userInitiated, operation: {
                    SpotlightIndexer.preblurredPoster(from: data)
                }).value,
                let blurredImage = SkylightsImage(data: blurData) else {
                    throw URLError(.cannotDecodeContentData)
                }
                // Swap to a pre-rendered blur first. The cached portrait blur has the
                // same crop; the sharp layer then reveals with opacity only.
                if fullBlurredImage == nil { fullBlurredImage = blurredImage }
                sharpImage = image
                logger.write("INFO", "Detail poster downloaded and preblurred: id=\(titleID), bytes=\(data.count), blurredBytes=\(blurData.count), elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.75)) {
                    revealsSharpImage = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                logger.write("ERROR", "Detail poster failed: id=\(titleID), url=\(url.absoluteString), elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000)), error=\(String(reflecting: error))")
            }
        }
    }
}
