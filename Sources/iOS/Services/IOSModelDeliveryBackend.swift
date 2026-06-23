import Foundation
import QwenVoiceCore

/// Identifies a single model-file download inside the delivery actor and the
/// backend that executes it. Encoded into `URLSessionTask.taskDescription` for
/// the real backend and used as a lookup key by the simulated backend.
struct IOSModelDownloadTaskDescription: Codable, Sendable, Hashable {
    let modelID: String
    let relativePath: String
}

/// Delegate shared between the URLSession backend and the simulated backend.
/// Closures are set once by `IOSModelDeliveryActor` and never mutated afterwards.
final class IOSModelDeliveryDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: (@Sendable (Int, String?, Int64, Int64) -> Void)?
    var onFinished: (@Sendable (Int, String?, URL) -> Void)?
    var onCompleted: (@Sendable (Int, String?, Error?) -> Void)?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(
            downloadTask.taskIdentifier,
            downloadTask.taskDescription,
            totalBytesWritten,
            totalBytesExpectedToWrite
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           ![200, 206].contains(http.statusCode) {
            onCompleted?(
                downloadTask.taskIdentifier,
                downloadTask.taskDescription,
                IOSModelDeliveryError.httpError(statusCode: http.statusCode)
            )
            return
        }

        let safeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        do {
            if FileManager.default.fileExists(atPath: safeURL.path) {
                try FileManager.default.removeItem(at: safeURL)
            }
            try FileManager.default.moveItem(at: location, to: safeURL)
            onFinished?(downloadTask.taskIdentifier, downloadTask.taskDescription, safeURL)
        } catch {
            onCompleted?(downloadTask.taskIdentifier, downloadTask.taskDescription, error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        onCompleted?(task.taskIdentifier, task.taskDescription, error)
    }
}

/// Abstraction over the actual transport that downloads model files.
/// The production implementation uses a background `URLSession`; the simulator
/// implementation produces synthetic progress and tiny files so the same actor
/// state machine can be exercised without a network or a physical device.
protocol IOSModelDownloadBackend: Sendable {
    /// Delegate whose closures the backend must call as work progresses.
    var delegate: IOSModelDeliveryDownloadDelegate { get }

    /// Begin downloading `file`. If `resumeData` is provided, resume from where
    /// a previous pause left off. The backend is responsible for encoding
    /// `taskDescription` into any task metadata it needs for later lookup.
    func startDownload(
        taskDescription: IOSModelDownloadTaskDescription,
        entry: IOSModelCatalogEntry,
        file: IOSModelCatalogFile,
        resumeData: Data?
    ) async throws

    /// Pause the download identified by `taskDescription` and return resume data
    /// that can later be passed to `startDownload`. Returns `nil` if the backend
    /// cannot produce resume data for this file.
    func pause(taskDescription: IOSModelDownloadTaskDescription) async -> Data?

    /// Cancel the download identified by `taskDescription`.
    func cancel(taskDescription: IOSModelDownloadTaskDescription) async

    /// Cancel every in-flight task for `modelID`.
    func cancelAllTasks(for modelID: String) async

    /// Number of downloads currently active in the backend.
    func activeTaskCount() async -> Int

    /// Returns true if the backend has an in-flight task matching `taskDescription`.
    func hasTask(for taskDescription: IOSModelDownloadTaskDescription) async -> Bool

    /// Whether the actor should run `verifyDownloadedModel` before installing.
    /// The simulator backend writes placeholder files, so it returns `false`.
    var requiresDownloadVerification: Bool { get }
}

func encodeTaskDescription(_ description: IOSModelDownloadTaskDescription) -> String? {
    guard let data = try? JSONEncoder().encode(description) else { return nil }
    return String(data: data, encoding: .utf8)
}

func decodeTaskDescription(_ rawValue: String?) -> IOSModelDownloadTaskDescription? {
    guard let rawValue, let data = rawValue.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(IOSModelDownloadTaskDescription.self, from: data)
}
