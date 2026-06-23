import Foundation
import QwenVoiceCore

/// Production download backend: background `URLSession` with resume-data support.
actor IOSURLSessionModelDownloadBackend: IOSModelDownloadBackend {
    let delegate: IOSModelDeliveryDownloadDelegate
    let requiresDownloadVerification: Bool = true

    private let configuration: IOSModelDeliveryConfiguration
    private let downloadSession: URLSession

    init(
        configuration: IOSModelDeliveryConfiguration,
        delegate: IOSModelDeliveryDownloadDelegate
    ) {
        self.configuration = configuration
        self.delegate = delegate

        let backgroundConfig = URLSessionConfiguration.background(
            withIdentifier: configuration.backgroundSessionIdentifier
        )
        backgroundConfig.waitsForConnectivity = true
        backgroundConfig.sessionSendsLaunchEvents = true
        backgroundConfig.isDiscretionary = false
        backgroundConfig.allowsExpensiveNetworkAccess = true
        backgroundConfig.allowsConstrainedNetworkAccess = true
        backgroundConfig.timeoutIntervalForRequest = 300
        self.downloadSession = URLSession(
            configuration: backgroundConfig,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    func startDownload(
        taskDescription: IOSModelDownloadTaskDescription,
        entry: IOSModelCatalogEntry,
        file: IOSModelCatalogFile,
        resumeData: Data?
    ) async throws {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = downloadSession.downloadTask(withResumeData: resumeData)
        } else {
            let downloadURL = try IOSModelDeliverySupport.downloadURL(
                for: file,
                entry: entry,
                configuration: configuration
            )
            task = downloadSession.downloadTask(with: downloadURL)
        }
        task.taskDescription = encodeTaskDescription(taskDescription)
        task.resume()
    }

    func pause(taskDescription: IOSModelDownloadTaskDescription) async -> Data? {
        guard let downloadTask = await matchingTask(for: taskDescription) as? URLSessionDownloadTask else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            downloadTask.cancel(byProducingResumeData: { data in
                continuation.resume(returning: data)
            })
        }
    }

    func cancel(taskDescription: IOSModelDownloadTaskDescription) async {
        if let task = await matchingTask(for: taskDescription) {
            task.cancel()
        }
    }

    func cancelAllTasks(for modelID: String) async {
        let tasks = await allTasks()
        for task in tasks {
            if decodeTaskDescription(task.taskDescription)?.modelID == modelID {
                task.cancel()
            }
        }
    }

    func activeTaskCount() async -> Int {
        await allTasks().count
    }

    func hasTask(for taskDescription: IOSModelDownloadTaskDescription) async -> Bool {
        await matchingTask(for: taskDescription) != nil
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            downloadSession.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func matchingTask(for taskDescription: IOSModelDownloadTaskDescription) async -> URLSessionTask? {
        await allTasks().first { task in
            decodeTaskDescription(task.taskDescription) == taskDescription
        }
    }
}
