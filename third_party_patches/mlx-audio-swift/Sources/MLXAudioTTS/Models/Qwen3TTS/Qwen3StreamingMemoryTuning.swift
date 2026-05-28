import Foundation
import os

/// Process-wide streaming memory knobs set by the host app before generation.
public enum Qwen3StreamingMemoryTuning: Sendable {
    private struct State: Sendable {
        var clearCacheOnStreamChunkEmit = true
        var tokenMemoryClearCadenceOverride: Int?
    }

    private static let lock = OSAllocatedUnfairLock(initialState: State())

    public static var clearCacheOnStreamChunkEmit: Bool {
        lock.withLock { $0.clearCacheOnStreamChunkEmit }
    }

    public static var tokenMemoryClearCadenceOverride: Int? {
        lock.withLock { $0.tokenMemoryClearCadenceOverride }
    }

    public static func apply(clearOnStreamChunk: Bool, tokenCadence: Int) {
        lock.withLock {
            $0.clearCacheOnStreamChunkEmit = clearOnStreamChunk
            $0.tokenMemoryClearCadenceOverride = tokenCadence
        }
    }
}
