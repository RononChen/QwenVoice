import Foundation

/// Process-lifetime debug-only memory behavior resolved once when the runtime
/// loads. Request-varying memory behavior belongs exclusively to
/// `Qwen3RequestMemoryPolicy`; this type must never be mutated by generation.
public enum Qwen3LoadTimeMemoryTuning: Sendable {
    /// Opt-in talker KV-cache quantization (P4 A/B; dev knob, default off):
    /// `QVOICE_TALKER_KV_QUANT=8|4` → QuantizedKVCache(groupSize: 64, bits: n).
    /// Quality-sensitive (clone fidelity) — ships per-tier only after fixed-seed
    /// exact-WAV QC plus the applicable ASR/prosody gates. Never combined with the rotating-window cache (its
    /// toQuantized is unimplemented upstream); the window knob wins if both
    /// are set.
    public static let talkerKVQuantBits: Int? = {
        guard let raw = VocelloQwen3ImplementationDebugGate.value(
            for: "QVOICE_TALKER_KV_QUANT"
        ),
              let bits = Int(raw), bits == 4 || bits == 8 else { return nil }
        return bits
    }()
}
