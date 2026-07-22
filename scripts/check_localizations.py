#!/usr/bin/env python3
"""Validate macOS UI localization completeness and format safety."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


SUPPORTED_LOCALIZATIONS = (
    "zh-Hans",
    "zh-Hant",
    "en",
    "ja",
    "de",
    "fr",
    "ru",
    "pt",
    "es",
    "it",
)
ENTRY_PATTERN = re.compile(
    r'^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";$'
)
FORMAT_PATTERN = re.compile(r'%(?:\d+\$)?(?:@|lld|ld|d|f|s)')
SWIFT_LANGUAGE_CASE_PATTERN = re.compile(r'^\s*case\s+\w+\s*=\s*"([^"]+)"\s*$', re.MULTILINE)
PROTECTED_TERMS = ("Vocello", "Qwen3", "WAV", "PCM", "MLX", "FFmpeg")
FORBIDDEN_TRANSLATION_FRAGMENTS = ("/no_think", "<<<", ">>>", "```")


class LocalizationContractError(ValueError):
    pass


def _decode_quoted(value: str) -> str:
    return json.loads(f'"{value}"')


def parse_strings(path: Path) -> dict[str, str]:
    entries: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("/*") or line.startswith("//"):
            continue
        match = ENTRY_PATTERN.fullmatch(line)
        if match is None:
            raise LocalizationContractError(f"{path}:{line_number}: invalid .strings entry")
        key = _decode_quoted(match.group(1))
        value = _decode_quoted(match.group(2))
        if key in entries:
            raise LocalizationContractError(f"{path}:{line_number}: duplicate key: {key}")
        if not value:
            raise LocalizationContractError(f"{path}:{line_number}: empty translation: {key}")
        entries[key] = value
    return entries


def validate_swift_language_list(path: Path) -> None:
    identifiers = tuple(SWIFT_LANGUAGE_CASE_PATTERN.findall(path.read_text(encoding="utf-8")))
    if identifiers != SUPPORTED_LOCALIZATIONS:
        raise LocalizationContractError(
            "Swift/Python supported localization lists differ: "
            f"swift={identifiers} contract={SUPPORTED_LOCALIZATIONS}"
        )


def validate_localizations(resources_root: Path) -> int:
    catalogs: dict[str, dict[str, str]] = {}
    for locale in SUPPORTED_LOCALIZATIONS:
        path = resources_root / f"{locale}.lproj" / "Localizable.strings"
        if not path.is_file():
            raise LocalizationContractError(f"missing localization catalog: {path}")
        catalogs[locale] = parse_strings(path)

    reference = catalogs["en"]
    if not reference:
        raise LocalizationContractError("English localization catalog is empty")
    for key, value in reference.items():
        if value != key:
            raise LocalizationContractError(f"English fallback must preserve its source key: {key}")

    reference_keys = set(reference)
    for locale, entries in catalogs.items():
        keys = set(entries)
        missing = sorted(reference_keys - keys)
        extra = sorted(keys - reference_keys)
        if missing or extra:
            details = []
            if missing:
                details.append(f"missing={missing[:5]}")
            if extra:
                details.append(f"extra={extra[:5]}")
            raise LocalizationContractError(f"{locale}: key set mismatch ({'; '.join(details)})")

        for key, value in entries.items():
            expected_formats = FORMAT_PATTERN.findall(key)
            actual_formats = FORMAT_PATTERN.findall(value)
            if actual_formats != expected_formats:
                raise LocalizationContractError(
                    f"{locale}: format placeholders changed for {key!r}: "
                    f"expected={expected_formats} actual={actual_formats}"
                )
            for term in PROTECTED_TERMS:
                if value.count(term) != key.count(term):
                    raise LocalizationContractError(
                        f"{locale}: protected term {term!r} changed for {key!r}"
                    )
            for fragment in FORBIDDEN_TRANSLATION_FRAGMENTS:
                if fragment in value:
                    raise LocalizationContractError(
                        f"{locale}: forbidden model artifact {fragment!r} in {key!r}"
                    )
    return len(reference)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--resources-root",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "Sources" / "Resources",
    )
    parser.add_argument(
        "--language-source",
        type=Path,
        default=(
            Path(__file__).resolve().parents[1]
            / "Sources"
            / "Services"
            / "AppDisplayLanguage.swift"
        ),
    )
    args = parser.parse_args()
    try:
        validate_swift_language_list(args.language_source)
        count = validate_localizations(args.resources_root)
    except (OSError, json.JSONDecodeError, LocalizationContractError) as error:
        print(f"localization contract: FAIL: {error}")
        return 1
    print(
        "localization contract: PASS "
        f"({len(SUPPORTED_LOCALIZATIONS)} locales, {count} keys each)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
