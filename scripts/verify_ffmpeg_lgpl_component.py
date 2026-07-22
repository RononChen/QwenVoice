#!/usr/bin/env python3
"""Build-manifest and fail-closed verification for Vocello's LGPL-only FFmpeg helper."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shlex
import struct
import subprocess
import tempfile
import wave
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = ROOT / "config/ffmpeg-lgpl-component.json"


def fail(message: str) -> None:
    raise ValueError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n").encode("utf-8")


def run(*args: str) -> str:
    completed = subprocess.run(args, check=False, capture_output=True, text=True)
    output = completed.stdout + completed.stderr
    if completed.returncode != 0:
        fail(f"command failed ({completed.returncode}): {' '.join(args)}\n{output.strip()}")
    return output


def load_config(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read component config {path}: {error}")
    expected_keys = {
        "schemaVersion", "component", "upstream", "version", "license",
        "releaseSigningKeyFingerprint", "source", "signature", "executableName",
        "appRelativeExecutablePath", "appRelativeNoticeDirectory", "releaseBuildInfoName",
        "minimumMacOSVersion", "configureArguments", "forbiddenConfigurationArguments",
        "expectedCapabilities", "allowedDynamicLibraryPrefixes",
    }
    if not isinstance(payload, dict) or set(payload) != expected_keys or payload.get("schemaVersion") != 1:
        fail("ffmpeg-lgpl-component config has an unsupported shape or schemaVersion")
    if payload.get("component") != "ffmpeg-vocello" or payload.get("license") != "LGPL-2.1-or-later":
        fail("component identity or license is not the approved LGPL-only helper")
    if not re.fullmatch(r"[0-9a-f]{64}", payload["source"].get("sha256", "")):
        fail("source SHA-256 is missing or malformed")
    if not re.fullmatch(r"[0-9a-f]{64}", payload["signature"].get("sha256", "")):
        fail("signature SHA-256 is missing or malformed")
    if not re.fullmatch(r"[0-9A-F]{40}", payload.get("releaseSigningKeyFingerprint", "")):
        fail("upstream release signing-key fingerprint is malformed")
    arguments = payload.get("configureArguments")
    if not isinstance(arguments, list) or not arguments or len(arguments) != len(set(arguments)):
        fail("configureArguments must be a non-empty unique array")
    forbidden = set(payload.get("forbiddenConfigurationArguments", []))
    if forbidden.intersection(arguments):
        fail("an explicitly forbidden FFmpeg configuration argument is enabled")
    for required in ("--disable-gpl", "--disable-version3", "--disable-nonfree", "--disable-network"):
        if required not in arguments:
            fail(f"required LGPL/minimal-build switch is missing: {required}")
    capabilities = payload.get("expectedCapabilities")
    if not isinstance(capabilities, dict) or set(capabilities) != {
        "protocols", "demuxers", "muxers", "decoders", "encoders", "filters"
    }:
        fail("expectedCapabilities must define the complete approved component surface")
    for name, values in capabilities.items():
        if not isinstance(values, list) or not values or len(values) != len(set(values)):
            fail(f"expectedCapabilities.{name} must be a non-empty unique array")
    return payload


def verify_archive(path: Path, expected_sha256: str, label: str) -> None:
    if not path.is_file():
        fail(f"{label} is missing: {path}")
    actual = sha256(path)
    if actual != expected_sha256:
        fail(f"{label} SHA-256 mismatch: expected {expected_sha256}, got {actual}")


def parse_configure_arguments(version_output: str) -> list[str]:
    line = next((line for line in version_output.splitlines() if line.startswith("configuration: ")), "")
    if not line:
        fail("FFmpeg version output does not expose its configuration")
    return shlex.split(line.removeprefix("configuration: "))


def parse_table(output: str) -> set[str]:
    separator_seen = False
    names: set[str] = set()
    for line in output.splitlines():
        if line.strip() == "------" or line.strip() == "---":
            separator_seen = True
            continue
        if not separator_seen or not line.strip():
            continue
        parts = line.split()
        if len(parts) >= 2:
            names.add(parts[1])
    return names


def parse_protocols(output: str) -> set[str]:
    names: set[str] = set()
    active = False
    for line in output.splitlines():
        stripped = line.strip()
        if stripped in {"Input:", "Output:"}:
            active = True
            continue
        if active and re.fullmatch(r"[a-zA-Z0-9_+-]+", stripped):
            names.add(stripped)
    return names


def parse_filters(output: str) -> set[str]:
    names: set[str] = set()
    separator_seen = False
    for line in output.splitlines():
        if line.strip() == "| = Source or sink filter":
            separator_seen = True
            continue
        if not separator_seen:
            continue
        parts = line.split()
        if len(parts) >= 2 and re.fullmatch(r"[T.S|.]{2,3}", parts[0]):
            names.add(parts[1])
    return names


def verify_tempo_smoke(binary: Path) -> None:
    sample_rate = 24_000
    input_frames = sample_rate * 2
    with tempfile.TemporaryDirectory(prefix="vocello-ffmpeg-lgpl-") as temporary:
        input_path = Path(temporary) / "input.wav"
        output_path = Path(temporary) / "output.wav"
        with wave.open(str(input_path), "wb") as writer:
            writer.setnchannels(1)
            writer.setsampwidth(2)
            writer.setframerate(sample_rate)
            frames = bytearray()
            for index in range(input_frames):
                sample = int(12_000 * math.sin(2 * math.pi * 220 * index / sample_rate))
                frames.extend(struct.pack("<h", sample))
            writer.writeframes(frames)
        run(
            str(binary), "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(input_path), "-filter:a", "atempo=0.85",
            "-ar", str(sample_rate), "-ac", "1", "-c:a", "pcm_s16le", str(output_path),
        )
        with wave.open(str(output_path), "rb") as reader:
            if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (1, 2, sample_rate):
                fail("tempo smoke output is not mono PCM16 at 24 kHz")
            actual_duration = reader.getnframes() / reader.getframerate()
        expected_duration = 2.0 / 0.85
        if abs(actual_duration - expected_duration) > 0.04:
            fail(
                f"tempo smoke duration mismatch: expected about {expected_duration:.4f}s, "
                f"got {actual_duration:.4f}s"
            )


def verify_binary(config: dict[str, Any], binary: Path, functional_test: bool = True) -> dict[str, Any]:
    if not binary.is_file() or not binary.stat().st_mode & 0o111:
        fail(f"component executable is missing or not executable: {binary}")
    architectures = run("lipo", "-archs", str(binary)).strip().split()
    if architectures != ["arm64"]:
        fail(f"component must be arm64-only, got: {architectures}")

    version_output = run(str(binary), "-hide_banner", "-version")
    if not version_output.startswith(f"ffmpeg version {config['version']} "):
        fail(f"component version is not FFmpeg {config['version']}")
    actual_arguments = parse_configure_arguments(version_output)
    if actual_arguments != config["configureArguments"]:
        fail("embedded FFmpeg configure arguments differ from the approved manifest")
    for forbidden in config["forbiddenConfigurationArguments"]:
        if forbidden in actual_arguments:
            fail(f"forbidden FFmpeg configuration is present: {forbidden}")

    license_output = run(str(binary), "-hide_banner", "-L")
    normalized_license = " ".join(license_output.split())
    if "GNU Lesser General Public License" not in normalized_license or "version 2.1" not in normalized_license:
        fail("component does not self-report the expected LGPL 2.1-or-later license")

    actual_capabilities = {
        "protocols": parse_protocols(run(str(binary), "-hide_banner", "-protocols")),
        "demuxers": parse_table(run(str(binary), "-hide_banner", "-demuxers")),
        "muxers": parse_table(run(str(binary), "-hide_banner", "-muxers")),
        "decoders": parse_table(run(str(binary), "-hide_banner", "-decoders")),
        "encoders": parse_table(run(str(binary), "-hide_banner", "-encoders")),
        "filters": parse_filters(run(str(binary), "-hide_banner", "-filters")),
    }
    for name, expected in config["expectedCapabilities"].items():
        if actual_capabilities[name] != set(expected):
            fail(
                f"unexpected {name} capability surface: "
                f"expected={sorted(expected)!r} actual={sorted(actual_capabilities[name])!r}"
            )

    linked = run("otool", "-L", str(binary)).splitlines()[1:]
    dependencies = [line.strip().split(" (", 1)[0] for line in linked if line.strip()]
    allowed_prefixes = tuple(config["allowedDynamicLibraryPrefixes"])
    unexpected = [path for path in dependencies if not path.startswith(allowed_prefixes)]
    if unexpected:
        fail(f"component links unapproved dynamic libraries: {unexpected}")
    if functional_test:
        verify_tempo_smoke(binary)
    return {
        "binarySHA256": sha256(binary),
        "architectures": architectures,
        "dynamicLibraries": dependencies,
        "configureArguments": actual_arguments,
    }


def build_manifest(
    config: dict[str, Any], binary: Path, source: Path, signature: Path, functional_test: bool
) -> dict[str, Any]:
    verify_archive(source, config["source"]["sha256"], "FFmpeg source archive")
    verify_archive(signature, config["signature"]["sha256"], "FFmpeg detached signature")
    binary_result = verify_binary(config, binary, functional_test=functional_test)
    return {
        "schemaVersion": 1,
        "component": config["component"],
        "upstream": config["upstream"],
        "upstreamVersion": config["version"],
        "license": config["license"],
        "releaseSigningKeyFingerprint": config["releaseSigningKeyFingerprint"],
        "sourceArchive": config["source"]["releaseAssetName"],
        "sourceSHA256": config["source"]["sha256"],
        "detachedSignature": config["signature"]["releaseAssetName"],
        "detachedSignatureSHA256": config["signature"]["sha256"],
        "buildBinarySHA256": binary_result["binarySHA256"],
        "architectures": binary_result["architectures"],
        "dynamicLibraries": binary_result["dynamicLibraries"],
        "configureArguments": binary_result["configureArguments"],
    }


def verify_app_bundle(config: dict[str, Any], app: Path, functional_test: bool) -> None:
    if not app.is_dir():
        fail(f"app bundle is missing: {app}")
    binary = app / config["appRelativeExecutablePath"]
    notice_dir = app / config["appRelativeNoticeDirectory"]
    for name in ("NOTICE.txt", "COPYING.LGPLv2.1", "LICENSE.md", "BUILD-INFO.json"):
        if not (notice_dir / name).is_file():
            fail(f"bundled FFmpeg legal notice is missing: {notice_dir / name}")
    result = verify_binary(config, binary, functional_test=functional_test)
    build_info = json.loads((notice_dir / "BUILD-INFO.json").read_text(encoding="utf-8"))
    expected_identity = {
        "component": config["component"],
        "upstreamVersion": config["version"],
        "license": config["license"],
        "sourceSHA256": config["source"]["sha256"],
        "configureArguments": result["configureArguments"],
    }
    for key, expected in expected_identity.items():
        if build_info.get(key) != expected:
            fail(f"bundled FFmpeg BUILD-INFO.json has the wrong {key}")
    if not re.fullmatch(r"[0-9a-f]{64}", build_info.get("buildBinarySHA256", "")):
        fail("bundled FFmpeg BUILD-INFO.json is missing its unsigned build-binary identity")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    subparsers = parser.add_subparsers(dest="command", required=True)

    check_config = subparsers.add_parser("check-config")
    check_config.set_defaults(action="check-config")

    verify = subparsers.add_parser("verify")
    verify.add_argument("--binary", type=Path, required=True)
    verify.add_argument("--source", type=Path, required=True)
    verify.add_argument("--signature", type=Path, required=True)
    verify.add_argument("--skip-functional-test", action="store_true")

    manifest = subparsers.add_parser("manifest")
    manifest.add_argument("--binary", type=Path, required=True)
    manifest.add_argument("--source", type=Path, required=True)
    manifest.add_argument("--signature", type=Path, required=True)
    manifest.add_argument("--output", type=Path, required=True)
    manifest.add_argument("--skip-functional-test", action="store_true")

    app = subparsers.add_parser("verify-app")
    app.add_argument("--app-bundle", type=Path, required=True)
    app.add_argument("--skip-functional-test", action="store_true")

    args = parser.parse_args()
    config = load_config(args.config.resolve())
    if args.command == "check-config":
        print("ffmpeg-lgpl-component config: PASS")
    elif args.command == "verify":
        payload = build_manifest(
            config, args.binary.resolve(), args.source.resolve(), args.signature.resolve(),
            functional_test=not args.skip_functional_test,
        )
        print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    elif args.command == "manifest":
        payload = build_manifest(
            config, args.binary.resolve(), args.source.resolve(), args.signature.resolve(),
            functional_test=not args.skip_functional_test,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(canonical_bytes(payload))
        print(args.output)
    else:
        verify_app_bundle(config, args.app_bundle.resolve(), not args.skip_functional_test)
        print("ffmpeg-vocello app bundle: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as error:
        raise SystemExit(f"error: {error}") from error
