#!/usr/bin/env bash
# Smoke: spool download skip-on-hit with a fake TSV (no network).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
COIL_BIN="${COIL:-coil}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export COIL_NATIVES_DIR="$TMP/natives"
export HOME="$TMP/home"
mkdir -p "$HOME"

# Minimal lock via a packaged-less path: write a stub that coil natives dump
# cannot use — instead exercise download_natives by injecting TSV through a
# wrapper. Prefer calling the function via a tiny harness:

# Build a fake "coil" that prints a fixed TSV for `natives dump --tsv`.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/coil" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "natives" && "${2:-}" == "dump" ]]; then
  shift 2
  # consume optional --tsv and optional path
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tsv) shift ;;
      *) shift ;;
    esac
  done
  echo "# os=linux"
  echo "# arch=x86_64"
  # empty entries → nothing to download
  exit 0
fi
echo "unexpected: $*" >&2
exit 1
EOF
chmod +x "$TMP/bin/coil"

export COIL="$TMP/bin/coil"
export PATH="$TMP/bin:$PATH"

# Force linux/x86_64 host check to match the stub (skip if host differs).
HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
[[ "$HOST_OS" == "darwin" ]] && HOST_OS="macos"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64) HOST_ARCH="x86_64" ;;
  aarch64|arm64) HOST_ARCH="aarch64" ;;
esac

if [[ "$HOST_OS" != "linux" || "$HOST_ARCH" != "x86_64" ]]; then
  # Rewrite stub os/arch to match host for this smoke.
  cat > "$TMP/bin/coil" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "natives" && "\${2:-}" == "dump" ]]; then
  echo "# os=$HOST_OS"
  echo "# arch=$HOST_ARCH"
  exit 0
fi
exit 1
EOF
  chmod +x "$TMP/bin/coil"
fi

cd "$ROOT"
out="$("$SPOOL" download 2>&1 || true)"
echo "$out" | grep -q "nothing to download\|ok (0 installed"

# coil-lang#1657: project mode, a row whose local file is not there yet. coil
# dumps it as `missing` (no sha256). spool fetches it to the row's `path`
# only when the row has its own `sha256` and the download matches it; a row
# without one is skipped, never fetched unhashed. A fake curl stands in for
# the network.
PROJ="$TMP/proj"
mkdir -p "$PROJ/src"
GOOD_SHA="$(printf 'fake library' | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
BAD_SHA="$(printf 'something else' | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
write_proj() { # $1: sha256 line for the row ("" for none)
  cat > "$PROJ/coil.toml" <<EOF
[module]
roots = ["./src"]

[[ffi.native]]
name = "gone"
version = "1.0.0"
path = "./native"
url = "https://example.invalid/libgone.so"
$1
EOF
}
cat > "$TMP/bin/coil" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "natives" && "\${2:-}" == "dump" ]]; then
  echo "# os=$HOST_OS"
  echo "# arch=$HOST_ARCH"
  printf 'gone\t1.0.0\tlibgone.so\t\t\tmissing\n'
  exit 0
fi
exit 1
EOF
chmod +x "$TMP/bin/coil"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
  esac
done
echo "\$url" >> "$TMP/curl.log"
[[ "\$url" == "https://example.invalid/libgone.so" ]] || exit 22
printf 'fake library' > "\$out"
EOF
chmod +x "$TMP/bin/curl"

# Missing, no sha256: skipped (exit 0), curl never runs, nothing is written.
write_proj ""
out="$(cd "$PROJ" && "$SPOOL" download 2>&1)" || { echo "$out"; exit 1; }
echo "$out" | grep -q "not fetching gone 1.0.0 (libgone.so): \[\[ffi.native\]\] gone has no sha256" || { echo "$out"; exit 1; }
echo "$out" | grep -q "ok (0 installed, 1 skipped" || { echo "$out"; exit 1; }
[[ ! -e "$TMP/curl.log" ]] || { echo "curl ran for an unhashed row"; exit 1; }
[[ ! -e "$PROJ/native/libgone.so" && ! -e "$PROJ/native/libgone.so.part" ]]

# Missing, wrong sha256: rejected (non-zero), the partial file removed.
write_proj "sha256 = \"$BAD_SHA\""
if out="$(cd "$PROJ" && "$SPOOL" download 2>&1)"; then echo "$out"; exit 1; fi
echo "$out" | grep -q "sha256 mismatch for gone: expected $BAD_SHA, got $GOOD_SHA" || { echo "$out"; exit 1; }
[[ ! -e "$PROJ/native/libgone.so" && ! -e "$PROJ/native/libgone.so.part" ]]

# A sha256 that is not 64 hex digits is a manifest error.
write_proj 'sha256 = "abc"'
if out="$(cd "$PROJ" && "$SPOOL" download 2>&1)"; then echo "$out"; exit 1; fi
echo "$out" | grep -q "sha256 must be 64 hex digits" || { echo "$out"; exit 1; }

# Missing, right sha256 (any case): fetched, verified, placed at `path`.
write_proj "sha256 = \"$(echo "$GOOD_SHA" | tr '[:lower:]' '[:upper:]')\""
out="$(cd "$PROJ" && "$SPOOL" download 2>&1)" || { echo "$out"; exit 1; }
echo "$out" | grep -q "fetched gone 1.0.0 -> .*native/libgone.so (sha256 $GOOD_SHA verified)" || { echo "$out"; exit 1; }
[[ "$(cat "$PROJ/native/libgone.so")" == "fake library" ]]
[[ ! -e "$PROJ/native/libgone.so.part" ]]
# If the file is there by the time spool looks, it is left alone.
rm -f "$TMP/curl.log"
out="$(cd "$PROJ" && "$SPOOL" download 2>&1)" || { echo "$out"; exit 1; }
echo "$out" | grep -q "skip gone 1.0.0" || { echo "$out"; exit 1; }
[[ ! -e "$TMP/curl.log" ]]
echo "smoke_natives_download: ok"
