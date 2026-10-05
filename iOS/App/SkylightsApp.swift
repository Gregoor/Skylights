#if os(iOS)
import SwiftUI
import BackgroundTasks
import CoreSpotlight
import UIKit
import Combine

private let refreshTaskID = "com.tinycast.tmdbspotlight.refresh"
private let processingTaskID = "com.tinycast.tmdbspotlight.processing"
private let fullIndexTaskID = "com.tinycast.tmdbspotlight.full-index"

@MainActor
final class AppDelegate: SkylightsAppController, UIApplicationDelegate {
    private var fullIndexProgress: ((Int, Int, String) -> Void)?
    private var fullIndexCompletion: ((Result<SyncResult, Error>) -> Void)?
    private var requestedFullIndexLimit: Int?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { [weak self] task in
            guard let self, let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            self.run(refresh)
        }
        logger.write(registered ? "INFO" : "ERROR", "Registered daily background refresh task: \(registered)")
        let processingRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskID, using: nil) { [weak self] task in
            guard let self, let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            self.run(processing)
        }
        logger.write(processingRegistered ? "INFO" : "ERROR", "Registered long-running background processing task: \(processingRegistered)")
        let continuedRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: fullIndexTaskID, using: nil) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in self?.run(continued) }
        }
        logger.write(continuedRegistered ? "INFO" : "ERROR", "Registered user-initiated continued indexing task: \(continuedRegistered)")
        scheduleRefresh()
        scheduleProcessing()
        return true
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType else { return false }
        handleSearchActivity(userActivity)
        return true
    }

    func startFullIndex(limit: Int?, progress: @escaping (Int, Int, String) -> Void, completion: @escaping (Result<SyncResult, Error>) -> Void) throws {
        requestedFullIndexLimit = limit
        fullIndexProgress = progress
        fullIndexCompletion = completion
        let request = BGContinuedProcessingTaskRequest(
            identifier: fullIndexTaskID,
            title: "Indexing TMDB",
            subtitle: "Preparing the TMDB catalog…"
        )
        // Keep the person-initiated task pending if iOS cannot start it immediately.
        // A `.fail` strategy turns temporary system pressure into a user-visible failure.
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.write("INFO", "Queued user-initiated continued indexing task; limit=\(limit.map(String.init) ?? "all")")
        } catch {
            fullIndexProgress = nil
            fullIndexCompletion = nil
            requestedFullIndexLimit = nil
            let nsError = error as NSError
            logger.write("ERROR", "Continued indexing task submission failed: domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription), userInfo=\(nsError.userInfo)")
            throw error
        }
    }

    private func run(_ task: BGContinuedProcessingTask) {
        let limit = requestedFullIndexLimit
        logger.write("INFO", "Continued indexing task started; limit=\(limit.map(String.init) ?? "all")")
        task.progress.totalUnitCount = 1
        task.progress.completedUnitCount = 0
        var work: Task<Void, Never>?
        task.expirationHandler = {
            self.logger.write("WARN", "iOS cancelled the continued indexing task; stopping at the next safe batch boundary")
            work?.cancel()
        }
        work = Task { [weak self] in
            guard let self else { task.setTaskCompleted(success: false); return }
            do {
                let result = try await SpotlightIndexer(logger: self.logger).sync(limit: limit) { [weak self] done, total, message in
                    task.progress.totalUnitCount = Int64(max(1, total))
                    task.progress.completedUnitCount = Int64(min(max(0, done), max(1, total)))
                    Task { @MainActor [weak self] in
                        task.updateTitle("Indexing TMDB", subtitle: message)
                        self?.fullIndexProgress?(done, total, message)
                    }
                }
                task.progress.completedUnitCount = task.progress.totalUnitCount
                task.updateTitle("TMDB index ready", subtitle: "Indexed \(result.indexed.formatted()) titles")
                task.setTaskCompleted(success: true)
                self.logger.write("INFO", "Continued indexing task completed successfully")
                self.fullIndexCompletion?(.success(result))
            } catch {
                task.setTaskCompleted(success: false)
                self.logger.write("ERROR", "Continued indexing task failed: \(String(reflecting: error))")
                self.fullIndexCompletion?(.failure(error))
            }
            self.fullIndexProgress = nil
            self.fullIndexCompletion = nil
            self.requestedFullIndexLimit = nil
        }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.write("INFO", "Scheduled next best-effort refresh; earliestBegin=\(request.earliestBeginDate?.description ?? "nil")")
        } catch {
            logger.write("ERROR", "Could not schedule background refresh: \(String(reflecting: error))")
        }
    }

    private func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.write("INFO", "Scheduled resumable network processing task; earliestBegin=\(request.earliestBeginDate?.description ?? "nil"), externalPowerRequired=false")
        } catch {
            logger.write("ERROR", "Could not schedule background processing task: \(String(reflecting: error))")
        }
    }

    private func run(_ task: BGAppRefreshTask) {
        logger.write("INFO", "Background TMDB delta refresh started")
        scheduleRefresh()
        let log = logger
        let work = Task {
            do {
                let result = try await SpotlightIndexer(logger: log).sync(limit: nil, incrementalOnly: true) { _, _, message in
                    log.write("INFO", "Background progress: \(message)")
                }
                log.write("INFO", "Background refresh complete: submitted=\(result.indexed), movies=\(result.movies), series=\(result.series), incremental=\(result.incremental)")
                task.setTaskCompleted(success: true)
            } catch {
                log.write("ERROR", "Background refresh failed: \(String(reflecting: error))")
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = {
            log.write("WARN", "iOS expired the background refresh task; cancelling current delta work")
            work.cancel()
        }
    }

    private func run(_ task: BGProcessingTask) {
        logger.write("INFO", "Background TMDB processing task started")
        scheduleProcessing()
        let log = logger
        let work = Task {
            do {
                let result = try await SpotlightIndexer(logger: log).sync(limit: nil, incrementalOnly: true) { _, _, message in
                    log.write("INFO", "Background processing progress: \(message)")
                }
                log.write("INFO", "Background processing complete: submitted=\(result.indexed), movies=\(result.movies), series=\(result.series), incremental=\(result.incremental)")
                task.setTaskCompleted(success: true)
            } catch {
                log.write("ERROR", "Background processing failed: \(String(reflecting: error))")
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = {
            log.write("WARN", "iOS expired background processing; cancelling at the next safe batch boundary")
            work.cancel()
        }
    }
}

@main
struct SkylightsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView(appDelegate: appDelegate)
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    appDelegate.handleSearchActivity(activity)
                }
        }
    }
}

#else
import SwiftUI
import CoreSpotlight
import AppKit
import Combine

@MainActor
final class AppDelegate: SkylightsAppController, NSApplicationDelegate {
    weak var reviewChangeController: UnsavedReviewChangeController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "MacAppIcon", withExtension: "icns"),
           let sourceIcon = NSImage(contentsOf: iconURL) {
            let size = NSSize(width: 512, height: 512)
            let icon = NSImage(size: size)
            icon.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high

            let iconRect = NSRect(origin: .zero, size: size)
            NSBezierPath(
                roundedRect: iconRect,
                xRadius: iconRect.width * 0.22,
                yRadius: iconRect.height * 0.22
            ).addClip()
            sourceIcon.draw(in: iconRect)
            icon.unlockFocus()

            NSApplication.shared.applicationIconImage = icon
            NSApplication.shared.dockTile.display()
        }
        logger.write("INFO", "Skylights macOS app launched")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let reviewChangeController, reviewChangeController.hasUnsavedChanges else { return .terminateNow }
        reviewChangeController.requestTermination()
        return .terminateCancel
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        logger.write("INFO", "AppKit continued activity: type=\(userActivity.activityType)")
        guard userActivity.activityType == CSSearchableItemActionType else { return false }
        application.activate(ignoringOtherApps: true)
        handleSearchActivity(userActivity)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "skylights", url.host == "spotlight" else { continue }
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count == 2,
                  let tmdbID = UInt32(components[1]) else {
                logger.write("ERROR", "Rejected malformed Spotlight open URL: \(url.absoluteString)")
                continue
            }
            let mediaType: UInt8
            switch components[0] {
            case "movie": mediaType = 0
            case "tv": mediaType = 1
            default:
                logger.write("ERROR", "Rejected unsupported Spotlight URL media type: \(components[0])")
                continue
            }
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { queryItems.first(where: { $0.name == name })?.value }
            let title = value("title") ?? ""
            logger.write("INFO", "Opening Core Spotlight URL: id=\(components[0])-\(tmdbID), titleAvailable=\(!title.isEmpty)")
            NSApplication.shared.activate(ignoringOtherApps: true)
            openTitle(SpotlightTitle(
                mediaType: mediaType,
                tmdbID: tmdbID,
                title: title,
                year: UInt16(value("year") ?? "") ?? 0,
                posterPath: value("poster") ?? "",
                rottenTomatoesScore: value("score").flatMap(UInt8.init),
                voteCount: UInt32(value("votes") ?? "") ?? 0,
                seasonCount: UInt16(value("seasons") ?? "") ?? 0
            ), source: "Core Spotlight URL")
        }
    }

    func handleSearchIntent(_ intent: OpenSkylightsTitleIntent) {
        let title = intent.target
        openTitle(SpotlightTitle(
            mediaType: UInt8(title.mediaType),
            tmdbID: UInt32(clamping: title.tmdbID),
            title: title.title,
            year: UInt16(clamping: title.year),
            posterPath: "",
            rottenTomatoesScore: title.rottenTomatoesScore.map(UInt8.init(clamping:))
        ), source: "App Intents Spotlight")
    }

    func startFullIndex(limit: Int?, progress: @escaping (Int, Int, String) -> Void, completion: @escaping (Result<SyncResult, Error>) -> Void) throws {
        Task { @MainActor in
            do {
                let result = try await SpotlightIndexer(logger: logger).sync(limit: limit) { done, total, message in
                    Task { @MainActor in progress(done, total, message) }
                }
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

}

@main
struct SkylightsMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Window("Skylights", id: "main") {
            ContentView(appDelegate: appDelegate)
                .onContinueUserActivity(CSSearchableItemActionType) { appDelegate.handleSearchActivity($0) }
        }
        .defaultSize(width: 1080, height: 760)
    }
}
#endif
