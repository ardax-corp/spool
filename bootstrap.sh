#!/usr/bin/env bash
# bootstrap.sh — build a standalone `spool` executable.
#
#   1. Find a usable coil toolchain: $COIL, `coil` on PATH, ~/.coil/bin/coil,
#      or a previous bootstrap build.
#   2. If none is valid, try the latest GitHub release for this host.
#   3. If there is no release, build coil-lang from source (default: main).
#   4. Fetch coil-stdlib, coil-toml and coil-json into .bootstrap/ (or use siblings).
#   5. `coil package spool.hy` → target/spool.
#   6. --install: spool → DIR (default ~/.local/bin), stdlib → ~/.coil/stdlib,
#      and a bootstrap-built coil with its tools (coil-test, coil-fmt, …) and
#      coil-embed → ~/.coil/bin.
#
# Usage: ./bootstrap.sh [--from-source] [--coil-only] [--use-siblings] [--install [DIR]]
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BOOT="${SPOOL_BOOTSTRAP_DIR:-$ROOT/.bootstrap}"
OUT_DIR="$ROOT/target"
OUT="$OUT_DIR/spool"

COIL_MIN_VERSION="${COIL_MIN_VERSION:-0.1.0}"
COIL_LANG_REPO="${COIL_LANG_REPO:-https://github.com/ardax-corp/coil-lang.git}"
COIL_LANG_REF="${COIL_LANG_REF:-main}"
COIL_STDLIB_REPO="${COIL_STDLIB_REPO:-https://github.com/ardax-corp/coil-stdlib.git}"
# Empty ref = the repository's default branch.
COIL_STDLIB_REF="${COIL_STDLIB_REF:-}"
# `pinned DEP KEY`: the `git` or `rev` value of DEP in spool's coil.toml.
pinned() {
  sed -n "s/^$1 = .*$2 = \"\\([^\"]*\\)\".*/\\1/p" "$ROOT/coil.toml"
}
# Defaults: the url and rev spool pins in its own coil.toml.
COIL_TOML_REPO="${COIL_TOML_REPO:-$(pinned toml git)}"
COIL_TOML_REF="${COIL_TOML_REF:-$(pinned toml rev)}"
COIL_JSON_REPO="${COIL_JSON_REPO:-$(pinned json git)}"
COIL_JSON_REF="${COIL_JSON_REF:-$(pinned json rev)}"
# Binaries next to coil that it re-execs, plus the packaging runner.
COIL_TOOLS="coil-embed coil-test coil-fmt coil-lsp coil-debug coil-dissect"
COIL_RELEASES_API="${COIL_RELEASES_API:-https://api.github.com/repos/ardax-corp/coil-lang/releases/latest}"

FROM_SOURCE=0
COIL_ONLY=0
USE_SIBLINGS=0
INSTALL_DIR=""

usage() {
  cat <<EOF
usage: ./bootstrap.sh [options]

  --from-source      skip installed/released coil; build coil-lang from source
  --coil-only        stop after a valid coil is found or built
  --use-siblings     compile against ../coil-stdlib, ../coil-toml and ../coil-json
  --install [DIR]    copy target/spool to DIR (default: ~/.local/bin)
  -h, --help         show this help

Environment:
  COIL                 coil binary to try first
  COIL_MIN_VERSION     minimum coil version (default: $COIL_MIN_VERSION)
  COIL_LANG_REPO/REF   source for the fallback build (default: main)
  COIL_STDLIB_REPO/REF, COIL_TOML_REPO/REF, COIL_JSON_REPO/REF
                       (empty REF = default branch)
  COIL_STDLIB_DIR, COIL_TOML_DIR, COIL_JSON_DIR   use these checkouts instead of fetching
  SPOOL_BOOTSTRAP_DIR  work dir (default: .bootstrap)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-source) FROM_SOURCE=1; shift ;;
    --coil-only) COIL_ONLY=1; shift ;;
    --use-siblings) USE_SIBLINGS=1; shift ;;
    --install)
      if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
        INSTALL_DIR="$2"; shift 2
      else
        INSTALL_DIR="$HOME/.local/bin"; shift
      fi
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "bootstrap: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf 'bootstrap: %s\n' "$*" >&2; }
die() { printf 'bootstrap: error: %s\n' "$*" >&2; exit 1; }

# --- version helpers --------------------------------------------------------

# `coil --version` prints `coil X.Y.Z[...]`; echo X.Y.Z or nothing.
coil_version_of() {
  local out
  out="$("$1" --version 2>/dev/null || true)"
  out="${out#coil }"
  out="${out%% *}"
  out="${out%%-*}"
  if [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$out"
  fi
}

# version_ge A B → true when A >= B (MAJOR.MINOR.PATCH).
version_ge() {
  local a b i
  IFS=. read -r -a a <<< "$1"
  IFS=. read -r -a b <<< "$2"
  for i in 0 1 2; do
    if (( ${a[i]:-0} > ${b[i]:-0} )); then return 0; fi
    if (( ${a[i]:-0} < ${b[i]:-0} )); then return 1; fi
  done
  return 0
}

# A valid coil: runs, meets the minimum version, has `package`, and compiles
# a probe that uses the host APIs spool needs (args/exec/exit/set_cwd).
coil_is_valid() {
  local bin="$1"
  [[ -n "$bin" && -x "$bin" ]] || return 1
  local ver
  ver="$(coil_version_of "$bin")"
  if [[ -z "$ver" ]]; then
    say "  $bin: unrecognised --version output"
    return 1
  fi
  if ! version_ge "$ver" "$COIL_MIN_VERSION"; then
    say "  $bin: coil $ver < required $COIL_MIN_VERSION"
    return 1
  fi
  if ! "$bin" package --help >/dev/null 2>&1; then
    say "  $bin: coil $ver has no \`package\` command"
    return 1
  fi
  local probe_dir
  probe_dir="$(mktemp -d)"
  cat > "$probe_dir/probe.hy" <<'EOF'
use env::{args, exec, exit, set_cwd};
fn main() {
    let a = match args() {
        Result::Ok(v) => len(v),
        Result::Err(_) => 0,
    };
    let argv: Vec<string> = Vec::new();
    argv.push("-c");
    argv.push("exit 0");
    let rc = match exec("sh", argv) {
        Result::Ok(c) => c,
        Result::Err(_) => 1,
    };
    if a < 0 {
        match set_cwd(".") {
            Result::Ok(_) => 0,
            Result::Err(_) => 0,
        };
    }
    exit(rc);
}
EOF
  local ok=0
  if ( cd "$probe_dir" && "$bin" --allow-exec --allow-exit probe.hy ) >/dev/null 2>"$probe_dir/err"; then
    ok=1
  else
    say "  $bin: coil $ver failed the host-API probe:"
    sed 's/^/    /' "$probe_dir/err" | head -n 8 >&2
  fi
  rm -rf "$probe_dir"
  [[ "$ok" -eq 1 ]] || return 1
  say "  $bin: coil $ver ok"
  return 0
}

# --- coil discovery ---------------------------------------------------------

host_triple() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
  esac
  case "$os" in
    Linux)
      if ldd --version 2>&1 | grep -qi musl; then
        printf '%s-unknown-linux-musl\n' "$arch"
      else
        printf '%s-unknown-linux-gnu\n' "$arch"
      fi
      ;;
    Darwin) printf '%s-apple-darwin\n' "$arch" ;;
    MINGW*|MSYS*|CYGWIN*) printf '%s-pc-windows-gnu\n' "$arch" ;;
    *) printf 'unknown\n' ;;
  esac
}

# A coil that bootstrap built earlier is reused only while its checkout is
# still the newest COIL_LANG_REF; otherwise it would never pick up new coil
# features. Offline (or a ref ls-remote cannot resolve): keep it.
boot_coil_is_current() {
  local src="$BOOT/coil-lang" have want tool
  # Older bootstraps built only coil + coil-embed.
  for tool in $COIL_TOOLS; do
    if [[ ! -x "$src/target/release/$tool" ]]; then
      say "  bootstrap coil has no $tool: rebuilding"
      return 1
    fi
  done
  have="$(git -C "$src" rev-parse HEAD 2>/dev/null)" || return 0
  want="$(git ls-remote "$COIL_LANG_REPO" "$COIL_LANG_REF" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  [[ -z "$want" || "$have" == "$want" ]] && return 0
  say "  bootstrap coil is at ${have:0:9}, $COIL_LANG_REF is at ${want:0:9}: rebuilding"
  return 1
}

same_file() {
  [[ "$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)/$(basename "$1")" \
    == "$(cd "$(dirname "$2")" 2>/dev/null && pwd -P)/$(basename "$2")" ]]
}

# Features spool's commands use; a coil without them still works, with less.
warn_missing_features() {
  local bin="$1"
  if [[ ! -x "$(dirname "$bin")/coil-test" ]]; then
    say "warning: no coil-test next to $bin: \`spool test\` / \`spool infect\` will not work"
  fi
  if ! "$bin" --help 2>/dev/null | grep -q '^  mutate '; then
    say "warning: $bin has no \`coil mutate\`: \`spool infect\` will not work"
  fi
  if ! "$bin" test --help 2>&1 | grep -q 'NDJSON events'; then
    say "warning: $bin has no \`coil test --json\`: \`spool test\` shows coil's plain report"
    say "  (needs ardax-corp/coil-lang#584; until it is merged: COIL_LANG_REF=feat/coil-test-json ./bootstrap.sh --from-source)"
  fi
}

find_installed_coil() {
  local c
  local candidates=()
  [[ -n "${COIL:-}" ]] && candidates+=("$COIL")
  c="$(command -v coil 2>/dev/null || true)"
  [[ -n "$c" ]] && candidates+=("$c")
  candidates+=("$HOME/.coil/bin/coil" "$BOOT/release/bin/coil" "$BOOT/coil-lang/target/release/coil")
  for c in "${candidates[@]}"; do
    [[ -x "$c" ]] || continue
    say "checking $c"
    if same_file "$c" "$BOOT/coil-lang/target/release/coil" && ! boot_coil_is_current; then
      continue
    fi
    if coil_is_valid "$c"; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

fetch_release_coil() {
  command -v curl >/dev/null 2>&1 || return 1
  local triple
  triple="$(host_triple)"
  [[ "$triple" != unknown ]] || return 1
  say "looking for a coil release for $triple"
  local meta
  if ! meta="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$COIL_RELEASES_API" 2>/dev/null)"; then
    say "  no published release"
    return 1
  fi
  local url
  url="$(printf '%s\n' "$meta" \
    | grep -o '"browser_download_url": *"[^"]*coil-'"$triple"'\.tar\.gz"' \
    | sed 's/.*"\(https[^"]*\)"/\1/' | head -n 1)"
  if [[ -z "$url" ]]; then
    say "  latest release has no coil-$triple.tar.gz"
    return 1
  fi
  local dest="$BOOT/release"
  rm -rf "$dest"
  mkdir -p "$dest/bin"
  say "  downloading $url"
  if ! curl -fsSL --proto '=https' --proto-redir '=https' "$url" \
      | tar -xz -C "$dest/bin" --strip-components=1; then
    say "  download failed"
    return 1
  fi
  if coil_is_valid "$dest/bin/coil"; then
    printf '%s\n' "$dest/bin/coil"
    return 0
  fi
  return 1
}

# Fetch $1 (url) at ref $2 (branch, tag or commit; empty = default branch)
# into $3 as a shallow detached checkout.
sync_checkout() {
  local url="$1" ref="$2" dir="$3"
  say "fetching $url (${ref:-default branch})"
  if [[ ! -d "$dir/.git" ]]; then
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" remote add origin "$url"
  fi
  git -C "$dir" fetch -q --depth 1 origin "${ref:-HEAD}" >&2 \
    || die "cannot fetch ${ref:-HEAD} from $url"
  git -C "$dir" checkout -q --detach FETCH_HEAD
}

build_coil_from_source() {
  command -v git >/dev/null 2>&1 || die "git is required to build coil from source"
  command -v cargo >/dev/null 2>&1 \
    || die "cargo is required to build coil from source (https://rustup.rs)"
  if command -v pkg-config >/dev/null 2>&1; then
    pkg-config --exists libffi \
      || say "warning: libffi dev files not found (apt: libffi-dev, pacman: libffi)"
    pkg-config --exists libpcre2-8 \
      || say "warning: pcre2 dev files not found (apt: libpcre2-dev, pacman: pcre2)"
  fi
  local src="$BOOT/coil-lang"
  mkdir -p "$BOOT"
  sync_checkout "$COIL_LANG_REPO" "$COIL_LANG_REF" "$src"
  say "building coil ($(git -C "$src" rev-parse --short HEAD)); this takes a few minutes"
  # Default members: coil plus the tools it re-execs (coil-test, coil-fmt,
  # coil-lsp, coil-debug, coil-dissect) and the coil-embed packaging runner.
  ( cd "$src" && cargo build --release ) >&2 \
    || die "cargo build failed in $src"
  local bin="$src/target/release/coil"
  coil_is_valid "$bin" || die "freshly built coil at $bin is not usable"
  printf '%s\n' "$bin"
}

# --- main -------------------------------------------------------------------

COIL_BIN=""
if [[ "$FROM_SOURCE" -eq 0 ]]; then
  COIL_BIN="$(find_installed_coil || true)"
  if [[ -z "$COIL_BIN" ]]; then
    COIL_BIN="$(fetch_release_coil || true)"
  fi
fi
if [[ -z "$COIL_BIN" ]]; then
  say "no usable coil found; building coil-lang $COIL_LANG_REF from source"
  COIL_BIN="$(build_coil_from_source)"
fi
say "using coil: $COIL_BIN ($(coil_version_of "$COIL_BIN"))"
warn_missing_features "$COIL_BIN"

if [[ "$COIL_ONLY" -eq 1 ]]; then
  printf '%s\n' "$COIL_BIN"
  exit 0
fi

# Library roots spool itself compiles against.
resolve_lib() {
  local override="$1" sibling="$2" url="$3" ref="$4" name="$5"
  if [[ -n "$override" ]]; then
    [[ -d "$override/src" ]] || die "$name: $override/src not found"
    printf '%s\n' "$override"
    return
  fi
  if [[ "$USE_SIBLINGS" -eq 1 ]]; then
    [[ -d "$sibling/src" ]] || die "$name: $sibling/src not found (--use-siblings)"
    printf '%s\n' "$sibling"
    return
  fi
  sync_checkout "$url" "$ref" "$BOOT/$name"
  printf '%s\n' "$BOOT/$name"
}

STDLIB_DIR="$(resolve_lib "${COIL_STDLIB_DIR:-}" "$ROOT/../coil-stdlib" \
  "$COIL_STDLIB_REPO" "$COIL_STDLIB_REF" coil-stdlib)"
TOML_DIR="$(resolve_lib "${COIL_TOML_DIR:-}" "$ROOT/../coil-toml" \
  "$COIL_TOML_REPO" "$COIL_TOML_REF" coil-toml)"
JSON_DIR="$(resolve_lib "${COIL_JSON_DIR:-}" "$ROOT/../coil-json" \
  "$COIL_JSON_REPO" "$COIL_JSON_REF" coil-json)"
say "coil-stdlib: $STDLIB_DIR ($(git -C "$STDLIB_DIR" rev-parse --short HEAD 2>/dev/null || echo local))"
say "coil-toml:   $TOML_DIR ($(git -C "$TOML_DIR" rev-parse --short HEAD 2>/dev/null || echo local))"
say "coil-json:   $JSON_DIR ($(git -C "$JSON_DIR" rev-parse --short HEAD 2>/dev/null || echo local))"

mkdir -p "$OUT_DIR"
say "packaging $OUT"
( cd "$ROOT" && "$COIL_BIN" package \
    --root "$ROOT/src" \
    --root "$STDLIB_DIR/src" \
    --root "$TOML_DIR/src" \
    --root "$JSON_DIR/src" \
    --allow-exec --allow-exit \
    -o "$OUT" spool.hy ) \
  || die "coil package failed"

"$OUT" --version >/dev/null || die "packaged spool does not run"
say "built $("$OUT" --version)"

if [[ -n "$INSTALL_DIR" ]]; then
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$OUT" "$INSTALL_DIR/spool"
  say "installed $INSTALL_DIR/spool"

  # Toolchain pieces spool looks for by default.
  COIL_HOME="${COIL_HOME:-$HOME/.coil}"
  case "$COIL_BIN" in
    "$BOOT"/*)
      mkdir -p "$COIL_HOME/bin"
      install -m 0755 "$COIL_BIN" "$COIL_HOME/bin/coil"
      # `coil test/fmt/lsp/debug/dissect` re-exec these from coil's directory.
      for tool in $COIL_TOOLS; do
        bin="$(dirname "$COIL_BIN")/$tool"
        [[ -x "$bin" ]] && install -m 0755 "$bin" "$COIL_HOME/bin/$tool"
      done
      say "installed $COIL_HOME/bin/coil"
      ;;
  esac
  rm -rf "$COIL_HOME/stdlib.new"
  mkdir -p "$COIL_HOME/stdlib.new"
  cp -R "$STDLIB_DIR/src" "$COIL_HOME/stdlib.new/src"
  rm -rf "$COIL_HOME/stdlib"
  mv "$COIL_HOME/stdlib.new" "$COIL_HOME/stdlib"
  say "installed $COIL_HOME/stdlib"

  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) say "note: $INSTALL_DIR is not on PATH" ;;
  esac
fi
printf '%s\n' "$OUT"
