import Foundation
import UIKit

/// Relays iOS background-URLSession completion handlers, keyed by session identifier. The app
/// delegate stashes each handler here (keyed by the session id from
/// `handleEventsForBackgroundURLSession`); the in-flight `HuggingFaceDownloader` flushes its own
/// session's handler from `urlSessionDidFinishEvents(forBackgroundURLSession:)` when that session
/// finishes all events. Calling the system completion handler is App-Store-required — iOS kills
/// the app otherwise — so orphans (handlers for sessions we never reattach) are flushed on
/// restore/resume.
@MainActor
enum IOSModelDeliveryBackgroundEventRelay {
    /// Registered by the app bootstrap: routes a `(identifier, completionHandler)` pair into the
    /// installer. Set once at launch; the app delegate invokes it when the system delivers a
    /// background event.
    static var handler: ((String, @escaping () -> Void) -> Void)?

    private static var pendingBySession: [String: () -> Void] = [:]

    static func store(_ completionHandler: @escaping () -> Void, forSessionIdentifier identifier: String) {
        pendingBySession[identifier] = completionHandler
    }

    /// Called by a downloader's `urlSessionDidFinishEvents` hook when its background session has
    /// finished delivering all events.
    static func complete(forSessionIdentifier identifier: String) {
        if let handler = pendingBySession.removeValue(forKey: identifier) {
            handler()
        }
    }

    /// Complete orphan handlers whose session isn't in `keeping` — e.g. the download finished
    /// before the app reattached the session on relaunch.
    static func completeOrphans(keeping activeSessionIdentifiers: Set<String>) {
        for key in pendingBySession.keys where !activeSessionIdentifiers.contains(key) {
            pendingBySession.removeValue(forKey: key)?()
        }
    }
}

final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            if let handler = IOSModelDeliveryBackgroundEventRelay.handler {
                handler(identifier, completionHandler)
            } else {
                // Handler not registered yet — stash for later. The coordinator flushes it once it
                // reconnects (or as an orphan if no download reattaches).
                IOSModelDeliveryBackgroundEventRelay.store(
                    completionHandler,
                    forSessionIdentifier: identifier
                )
            }
        }
    }
}
