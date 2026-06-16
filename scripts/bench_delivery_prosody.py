#!/usr/bin/env python3
"""Post-process `vocello bench --delivery` WAVs with the prosody analyzer.

For every instruct-bearing delivery take under outputs/bench, finds the paired
neutral warm take (same mode / model / length / state) and computes the
prosody delta via scripts/analyze_prosody.py. Writes a sidecar JSON that
summarize_generation_telemetry.py can render alongside the delivery cells.

Usage:
    scripts/bench_delivery_prosody.py <diagnostics_dir>

Output:
    <diagnostics_dir>/bench-prosody.json
"""
import sys, os, json, re, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyze_prosody import analyze
from prosody_profile import builtin_profile, load_profile, delivery_weight


def parse_filename(name):
    """Parse bench WAV filename: <mode>_<modelID>_<len>_<stateToken>_<n>.wav

    Model IDs can contain underscores (e.g. pro_custom_speed), so we anchor on
    the known length/state tokens from the right instead of counting segments.
    """
    if not name.endswith(".wav"):
        return None
    m = re.match(
        r"^(custom|design|clone)_(.+?)_(short|medium|long)_(warm|cold|warm_d-[^_]+)_(\d+)\.wav$",
        name,
    )
    if not m:
        return None
    mode, model, length, state_token, n_str = m.groups()
    try:
        n = int(n_str)
    except ValueError:
        return None
    delivery = None
    state = state_token
    if state_token.startswith("warm_d-"):
        state = "warm"
        delivery = state_token[len("warm_d-"):]
    return {
        "mode": mode, "model": model, "length": length,
        "state": state, "delivery": delivery, "n": n,
        "name": name,
    }


def collect_outputs(bench_dir):
    if not os.path.isdir(bench_dir):
        return []
    parsed = []
    for name in os.listdir(bench_dir):
        p = parse_filename(name)
        if p:
            p["path"] = os.path.join(bench_dir, name)
            parsed.append(p)
    return parsed


def find_neutral(parsed, target):
    """Find the best neutral reference for a delivery take.

    Delivery takes always use the medium text, so the ideal reference is a warm
    neutral take of the same mode/model/length. If a same-length neutral is
    unavailable (e.g. a partial bench), fall back to any warm neutral for the
    same mode/model so the analysis still runs.
    """
    same_length = [
        p for p in parsed
        if p["delivery"] is None
        and p["mode"] == target["mode"]
        and p["model"] == target["model"]
        and p["length"] == target["length"]
        and p["state"] == target["state"]
    ]
    candidates = same_length or [
        p for p in parsed
        if p["delivery"] is None
        and p["mode"] == target["mode"]
        and p["model"] == target["model"]
        and p["state"] == target["state"]
    ]
    if not candidates:
        return None
    # Prefer same n, then lowest n.
    candidates.sort(key=lambda p: (abs(p["n"] - target["n"]), p["n"]))
    return candidates[0]


def prosody_effect(d, profile=None):
    """Replicate the signed effect score from delivery_adherence.py."""
    prof = profile if profile is not None else builtin_profile()
    return (
        d["f0_std_hz"] / delivery_weight(prof, "prosody_effect", "f0_std_divisor")
        + d["rate_cv"] / delivery_weight(prof, "prosody_effect", "rate_cv_divisor")
        - d["pause_ratio"] / delivery_weight(prof, "prosody_effect", "pause_ratio_divisor")
        + d["energy_roughness"] / delivery_weight(prof, "prosody_effect", "energy_roughness_divisor")
    )


def main():
    ap = argparse.ArgumentParser(description="Post-process bench delivery WAVs with prosody analysis.")
    ap.add_argument("diagnostics_dir", help="diagnostics directory (contains outputs/bench)")
    ap.add_argument("--prosody-profile", default="", help="path to a prosody profile JSON (default: built-in)")
    args = ap.parse_args()

    profile = load_profile(args.prosody_profile) if args.prosody_profile else None

    diag_dir = args.diagnostics_dir
    bench_dir = os.path.join(os.path.dirname(diag_dir), "outputs", "bench")
    if not os.path.isdir(bench_dir):
        sys.exit(f"bench outputs dir not found: {bench_dir}")

    parsed = collect_outputs(bench_dir)
    deliveries = [p for p in parsed if p["delivery"]]
    if not deliveries:
        print("no delivery takes found; nothing to analyze", file=sys.stderr)
        return

    results = []
    for d in deliveries:
        neu = find_neutral(parsed, d)
        if neu is None:
            print(f"WARN: no neutral reference for {d['name']}", file=sys.stderr)
            continue
        p_inst = analyze(d["path"])
        p_neu = analyze(neu["path"])
        if "error" in p_inst or "error" in p_neu:
            print(f"WARN: analysis failed for {d['name']}", file=sys.stderr)
            continue
        results.append({
            "mode": d["mode"],
            "model": d["model"],
            "length": d["length"],
            "delivery": d["delivery"],
            "deliveryWav": d["name"],
            "neutralWav": neu["name"],
            "durationSec": p_inst["durationSec"],
            "dF0Std": round(p_inst["f0_std_hz"] - p_neu["f0_std_hz"], 2),
            "dRateCV": round(p_inst["rate_cv"] - p_neu["rate_cv"], 3),
            "dPauseRatio": round(p_inst["pause_ratio"] - p_neu["pause_ratio"], 3),
            "dRoughness": round(p_inst["energy_roughness"] - p_neu["energy_roughness"], 3),
            "prosodyEffect": round(prosody_effect({k: p_inst[k] for k in [
                "f0_std_hz", "rate_cv", "pause_ratio", "energy_roughness"]}, profile), 2),
            "deliveryMetrics": p_inst,
            "neutralMetrics": p_neu,
        })

    out_path = os.path.join(diag_dir, "bench-prosody.json")
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"wrote {out_path} ({len(results)} delivery/neutral pairs)")


if __name__ == "__main__":
    main()
