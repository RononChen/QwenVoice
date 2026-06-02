#!/usr/bin/env bash
# Install AXe (cameroncooke/AXe) — the simulator UI-driving CLI that the axiom `xcui`
# tool shells out to — WITHOUT Homebrew. `xcui doctor --install` only knows the brew
# path (`brew install cameroncooke/axe/axe`), but the formula just unpacks a prebuilt
# release tarball, ad-hoc-codesigns the bundled frameworks + binary, and writes a wrapper.
# This replicates that faithfully with curl/tar/codesign so the xcui/axe path works on a
# machine without brew. See docs/reference/ios-device-testing.md "Simulator UI review".
#
# Usage:
#   scripts/install_axe.sh                 # install (idempotent — no-op if axe already on PATH)
#   scripts/install_axe.sh --force         # reinstall even if axe is present
#   scripts/install_axe.sh --prefix DIR    # install under DIR (default ~/.local)
#
# Env overrides (for a future version bump — keep version + sha in lockstep):
#   AXE_VERSION   (default 1.7.1)
#   AXE_SHA256    (default the v1.7.1 homebrew-tarball sha; required when AXE_VERSION is overridden)
#   AXE_PREFIX    (default $HOME/.local)

set -euo pipefail

# Pinned to match cameroncooke/homebrew-axe Formula/axe.rb. Bump both together.
AXE_VERSION="${AXE_VERSION:-1.7.1}"
AXE_SHA256="${AXE_SHA256:-067e9be0a628f151477e5b5f60e6ed92796b22238fddd3b1636d953a20d910fe}"
PREFIX="${AXE_PREFIX:-$HOME/.local}"
FORCE=0

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    *) die "unknown arg '$1' (try: --force | --prefix DIR | --help)" ;;
  esac
done

ARTIFACT="AXe-macOS-homebrew-v${AXE_VERSION}.tar.gz"
URL="https://github.com/cameroncooke/AXe/releases/download/v${AXE_VERSION}/${ARTIFACT}"
LIBEXEC="$PREFIX/libexec/axe"
BIN="$PREFIX/bin/axe"

# --- Preflight ----------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "AXe is macOS-only (this is $(uname -s))"
for tool in curl tar shasum codesign; do
  command -v "$tool" >/dev/null || die "'$tool' not found (codesign needs Xcode / Command Line Tools)"
done

if command -v axe >/dev/null 2>&1 && [[ "$FORCE" -ne 1 ]]; then
  note "axe already installed: $(command -v axe) ($(axe --version 2>/dev/null | head -1))"
  note "pass --force to reinstall."
  exit 0
fi

# --- Download + verify --------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARBALL="$TMP/$ARTIFACT"

note "downloading AXe v${AXE_VERSION} (no Homebrew) …"
curl -fSL "$URL" -o "$TARBALL" || die "download failed: $URL"

note "verifying sha256 …"
got="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
[[ "$got" == "$AXE_SHA256" ]] \
  || die "sha256 mismatch — refusing to install
  expected: $AXE_SHA256
  got:      $got
  (set AXE_SHA256 if you intentionally changed AXE_VERSION)"

# --- Extract + locate the payload --------------------------------------------
EXDIR="$TMP/extract"
mkdir -p "$EXDIR"
tar -xzf "$TARBALL" -C "$EXDIR"

# The formula installs `axe` + `Frameworks` + `AXe_AXe.bundle`; tolerate an optional
# top-level wrapper directory by locating the `axe` mach-o and working from its parent.
AXE_BIN="$(find "$EXDIR" -type f -name axe -perm -u+x 2>/dev/null | head -1)"
[[ -n "$AXE_BIN" ]] || die "could not find the 'axe' executable in $ARTIFACT"
SRC="$(dirname "$AXE_BIN")"
[[ -d "$SRC/Frameworks" ]] || die "expected '$SRC/Frameworks' in the tarball (layout changed?)"
[[ -d "$SRC/AXe_AXe.bundle" ]] || warn "AXe_AXe.bundle not found beside axe — continuing"

# --- Install (mirror `libexec.install "axe", "Frameworks", "AXe_AXe.bundle"`) --
note "installing into $LIBEXEC"
rm -rf "$LIBEXEC"
mkdir -p "$LIBEXEC"
cp -R "$SRC/axe" "$SRC/Frameworks" "$LIBEXEC/"
[[ -d "$SRC/AXe_AXe.bundle" ]] && cp -R "$SRC/AXe_AXe.bundle" "$LIBEXEC/"
chmod +x "$LIBEXEC/axe"

# --- Ad-hoc codesign (mirror post_install: frameworks first, then the binary) -
note "ad-hoc codesigning frameworks + binary …"
shopt -s nullglob
for fw in "$LIBEXEC"/Frameworks/*.framework; do
  codesign --force --sign - --timestamp=none "$fw" \
    || die "codesign failed for $fw"
done
shopt -u nullglob
codesign --force --sign - --timestamp=none "$LIBEXEC/axe" \
  || die "codesign failed for $LIBEXEC/axe"

# --- Wrapper (mirror `bin.write_exec_script libexec/"axe"`) -------------------
mkdir -p "$PREFIX/bin"
cat > "$BIN" <<WRAP
#!/bin/bash
exec "$LIBEXEC/axe" "\$@"
WRAP
chmod +x "$BIN"

# --- Verify -------------------------------------------------------------------
ver="$("$BIN" --version 2>/dev/null | head -1 || true)"
[[ "$ver" == *"$AXE_VERSION"* ]] \
  || die "installed, but '$BIN --version' did not report $AXE_VERSION (got: '${ver:-<none>}')"

note "installed axe $AXE_VERSION → $BIN"
if ! printf '%s' ":$PATH:" | grep -q ":$PREFIX/bin:"; then
  warn "$PREFIX/bin is not on your PATH — add it (e.g. export PATH=\"$PREFIX/bin:\$PATH\")"
fi
note "done. Try: axe --help    (and: xcui doctor)"
