import Foundation
import os

/// Process-wide streaming memory knobs set by the host app before generation.
public enum Qwen3StreamingMemoryTuning: Sendable {
    private struct State: Sendable {
        var clearCacheOnStreamChunkEmit = true
        var tokenMemoryClearCadenceOverride: Int?
        // Sliding-window talker KV cache: nil = disabled (unbounded KVCacheSimple,
        // the default/quality-transparent path). Non-nil = the number of GENERATED
        // audio-codec tokens to retain beyond the conditioning prefix (which is
        // always kept). The talker creates a RotatingKVCache(maxSize: prefixLen +
        // window, keep: prefixLen) when this is set. Used to cap peak RAM on long
        // generations for the iOS / low-end-Mac tiers.
        var talkerKVGeneratedWindow: Int?
    }

    private static let lock = OSAllocatedUnfairLock(initialState: State())

    public static var clearCacheOnStreamChunkEmit: Bool {
        lock.withLock { $0.clearCacheOnStreamChunkEmit }
    }

    public static var tokenMemoryClearCadenceOverride: Int? {
        lock.withLock { $0.tokenMemoryClearCadenceOverride }
    }

    /// Generated-audio-token window for the sliding-window talker KV cache, or nil
    /// when disabled (the default — unbounded cache, no behavior change).
    public static var talkerKVGeneratedWindow: Int? {
        lock.withLock { $0.talkerKVGeneratedWindow }
    }

    public static func apply(clearOnStreamChunk: Bool, tokenCadence: Int) {
        lock.withLock {
            $0.clearCacheOnStreamChunkEmit = clearOnStreamChunk
            $0.tokenMemoryClearCadenceOverride = tokenCadence
        }
    }

    /// Set (or clear, with nil) the sliding-window talker KV cache's generated-token
    /// window. The host sets this per-tier/per-request before generation.
    public static func applyTalkerKVWindow(_ window: Int?) {
        lock.withLock {
            $0.talkerKVGeneratedWindow = window
        }
    }
}
