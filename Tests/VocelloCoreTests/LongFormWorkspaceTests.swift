import Foundation
@testable import QwenVoiceCore
import XCTest

final class LongFormWorkspaceTests: XCTestCase {
    func testTaskRemovalDeletesAllSegmentFilesWithoutDeletingRoot() throws {
        let root = try makeTemporaryRoot("task-removal")
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let workspace = try LongFormTaskWorkspace(rootURL: root, taskIdentifier: taskID)

        try Data([0, 1, 2]).write(to: workspace.segmentURL(at: 0))
        try Data([3, 4, 5]).write(to: workspace.segmentURL(at: 37))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.taskURL.path))

        try workspace.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.taskURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testOrphanSweepRemovesOnlyUUIDOwnedTaskDirectories() throws {
        let root = try makeTemporaryRoot("orphan-sweep")
        defer { try? FileManager.default.removeItem(at: root) }
        let orphanID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let orphan = try LongFormTaskWorkspace(rootURL: root, taskIdentifier: orphanID)
        try Data([1]).write(to: orphan.segmentURL(at: 0))

        let unknownDirectory = root.appendingPathComponent("keep-me", isDirectory: true)
        try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: true)
        let unknownFile = root.appendingPathComponent("notes.txt", isDirectory: false)
        try Data("keep".utf8).write(to: unknownFile)

        try LongFormTaskWorkspace.removeOrphanedTasks(in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.taskURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownFile.path))
    }

    private func makeTemporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocello-long-form-workspace-tests", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
