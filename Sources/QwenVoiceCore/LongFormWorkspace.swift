import Foundation

public enum LongFormWorkspaceError: Error, Equatable, Sendable {
    case invalidTaskIdentifier
    case taskEscapesRoot
}

/// Owns the disposable audio workspace for one long-form generation.
///
/// The caller chooses the root (the app uses its excluded-from-backup cache).
/// Every segment lives below a UUID-named child directory so cleanup can never
/// target the cache root or an unrelated user-selected output folder.
public struct LongFormTaskWorkspace: Sendable {
    public let rootURL: URL
    public let taskURL: URL

    public init(
        rootURL: URL,
        taskIdentifier: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws {
        let root = rootURL.standardizedFileURL
        let identifier = taskIdentifier.uuidString.lowercased()
        guard UUID(uuidString: identifier) != nil else {
            throw LongFormWorkspaceError.invalidTaskIdentifier
        }
        let task = root.appendingPathComponent(identifier, isDirectory: true).standardizedFileURL
        guard task.deletingLastPathComponent() == root else {
            throw LongFormWorkspaceError.taskEscapesRoot
        }

        try fileManager.createDirectory(at: task, withIntermediateDirectories: true)
        self.rootURL = root
        self.taskURL = task
    }

    public func segmentURL(at index: Int) -> URL {
        taskURL.appendingPathComponent(
            String(format: "segment-%04d.wav", index + 1),
            isDirectory: false
        )
    }

    public func remove(fileManager: FileManager = .default) throws {
        guard taskURL.deletingLastPathComponent() == rootURL else {
            throw LongFormWorkspaceError.taskEscapesRoot
        }
        guard fileManager.fileExists(atPath: taskURL.path) else { return }
        try fileManager.removeItem(at: taskURL)
    }

    /// Removes only UUID-named task directories. Unknown files are preserved
    /// fail-closed instead of being treated as Vocello-owned scratch data.
    public static func removeOrphanedTasks(
        in rootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let root = rootURL.standardizedFileURL
        guard fileManager.fileExists(atPath: root.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let standardized = child.standardizedFileURL
            guard standardized.deletingLastPathComponent() == root,
                  UUID(uuidString: standardized.lastPathComponent) != nil,
                  (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            try fileManager.removeItem(at: standardized)
        }
    }
}
