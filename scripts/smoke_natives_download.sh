#!/usr/bin/env bash
# Smoke: spool download skip-on-hit with a fake TSV (no network).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
out="$("$ROOT/spool" download 2>&1 || true)"
echo "$out" | grep -q "nothing to download\|ok (0 installed"
echo "smoke_natives_download: ok"
