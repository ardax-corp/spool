#!/usr/bin/env bash
# COI-103: current-project [scripts] via host sh. Default off. --ignore-scripts wins.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COIL_BIN="${COIL:-coil}"
CACHE="$ROOT/scratch/cache_scripts"
BASE="$ROOT/scratch/scripts"

if [[ ! -x "$COIL_BIN" ]]; then
  if ! command -v "$COIL_BIN" >/dev/null 2>&1; then
    echo "smoke_scripts: coil not found (set COIL)" >&2
    exit 1
  fi
fi

rm -rf "$CACHE" "$BASE"
mkdir -p "$BASE"

write_marker_script() {
  local dest="$1"
  local name="$2"
  cat > "$dest" <<EOF
#!/bin/sh
echo "$name" >> "\${SPOOL_PROJECT:-.}/SCRIPT_RAN"
EOF
  chmod +x "$dest"
}

write_fail_script() {
  local dest="$1"
  cat > "$dest" <<'EOF'
#!/bin/sh
echo fail >> "${SPOOL_PROJECT:-.}/SCRIPT_RAN"
exit 7
EOF
  chmod +x "$dest"
}

write_app() {
  local dest="$1"
  local name="$2"
  rm -rf "$dest"
  mkdir -p "$dest/src" "$dest/scripts"
  cat > "$dest/coil.toml" <<EOF
[package]
name = "$name"
version = "0.0.1"

[module]
roots = ["./src"]
[env]
allow_exec = true

[scripts]
pre_install = "./scripts/pre-install.sh"
post_install = "./scripts/post-install.sh"
pre_update = "./scripts/pre-update.sh"
post_update = "./scripts/post-update.sh"
EOF
  echo "// app" > "$dest/src/main.hy"
  write_marker_script "$dest/scripts/pre-install.sh" "pre_install"
  write_marker_script "$dest/scripts/post-install.sh" "post_install"
  write_marker_script "$dest/scripts/pre-update.sh" "pre_update"
  write_marker_script "$dest/scripts/post-update.sh" "post_update"
}

write_lib() {
  local dest="$1"
  local name="$2"
  rm -rf "$dest"
  mkdir -p "$dest/src" "$dest/scripts"
  cat > "$dest/coil.toml" <<EOF
[package]
name = "$name"
version = "1.0.0"
include = "./scripts/include.sh"

[module]
roots = ["./src"]

[scripts]
pre_install = "./scripts/pre-install.sh"
post_install = "./scripts/post-install.sh"
EOF
  echo "// lib" > "$dest/src/lib.hy"
  cat > "$dest/scripts/pre-install.sh" <<'EOS'
#!/bin/sh
touch "${SPOOL_PROJECT:-.}/DEP_SCRIPT_RAN"
EOS
  cat > "$dest/scripts/post-install.sh" <<'EOS'
#!/bin/sh
touch "${SPOOL_PROJECT:-.}/DEP_SCRIPT_RAN"
EOS
  cat > "$dest/scripts/include.sh" <<'EOS'
#!/bin/sh
touch "${SPOOL_PROJECT:-.}/DEP_INCLUDE_RAN"
EOS
  chmod +x "$dest/scripts/pre-install.sh" "$dest/scripts/post-install.sh" "$dest/scripts/include.sh"
}

assert_no_file() {
  local f="$1"
  local msg="$2"
  if [[ -f "$f" ]]; then
    echo "smoke_scripts: $msg ($f)" >&2
    cat "$f" >&2 || true
    exit 1
  fi
}

HELP="$("$ROOT/spool" help)"
echo "$HELP" | grep -q -- "--enable-scripts"
echo "$HELP" | grep -q -- "--ignore-scripts"

export COIL="$COIL_BIN"
export COIL_CACHE_DIR="$CACHE"

APP="$BASE/app"
write_app "$APP" "app"
export SPOOL_PROJECT="$APP"

# Default off: declared [scripts] must not sh.
"$ROOT/spool" install
assert_no_file "$APP/SCRIPT_RAN" "default install ran scripts"

# Opt-in: install pair only.
"$ROOT/spool" install --enable-scripts
test -f "$APP/SCRIPT_RAN"
grep -qx "pre_install" <(head -n 1 "$APP/SCRIPT_RAN")
grep -q "post_install" "$APP/SCRIPT_RAN"
if grep -q "pre_update" "$APP/SCRIPT_RAN" || grep -q "post_update" "$APP/SCRIPT_RAN"; then
  echo "smoke_scripts: install ran update scripts" >&2
  exit 1
fi
grep -q "\[scripts\]" "$APP/coil.lock"
grep -q "pre_install_hash" "$APP/coil.lock"
if grep -q "name = 'app'" "$APP/coil.lock"; then
  echo "smoke_scripts: stuffed root scripts into a [[package]] row" >&2
  exit 1
fi

# --ignore-scripts wins over --enable-scripts.
rm -f "$APP/SCRIPT_RAN"
"$ROOT/spool" --enable-scripts --ignore-scripts install
assert_no_file "$APP/SCRIPT_RAN" "--ignore-scripts did not win"
"$ROOT/spool" --ignore-scripts --enable-scripts install
assert_no_file "$APP/SCRIPT_RAN" "--ignore-scripts did not win (flag order)"

# Path dep with its own [scripts] / include: never run during consumer install.
LIB="$BASE/httplib"
write_lib "$LIB" "http"
rm -f "$APP/SCRIPT_RAN" "$APP/DEP_SCRIPT_RAN" "$APP/DEP_INCLUDE_RAN"
"$ROOT/spool" add http --path "$LIB" --enable-scripts
test -L "$APP/.spool/deps/http"
test -f "$APP/SCRIPT_RAN"
grep -q "pre_install" "$APP/SCRIPT_RAN"
grep -q "post_install" "$APP/SCRIPT_RAN"
assert_no_file "$APP/DEP_SCRIPT_RAN" "dependency [scripts] ran"
assert_no_file "$APP/DEP_INCLUDE_RAN" "dependency include-hook ran"

# Git fixture for update + add-from-scratch.
FIX="$BASE/fixture"
write_lib "$FIX" "fixture"
git init -q "$FIX"
git -C "$FIX" config user.email "spool@test"
git -C "$FIX" config user.name "spool"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "v1"
git -C "$FIX" tag v1.0.0
echo "v1.1" > "$FIX/README.md"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "v1.1"
git -C "$FIX" tag v1.1.0
GITURL="file://$FIX"

GITAPP="$BASE/gitapp"
write_app "$GITAPP" "gitapp"
export SPOOL_PROJECT="$GITAPP"
"$ROOT/spool" add fixture --git "$GITURL" --version "^1.0" --enable-scripts
test -L "$GITAPP/.spool/deps/fixture"
grep -q "pre_install" "$GITAPP/SCRIPT_RAN"
grep -q "post_install" "$GITAPP/SCRIPT_RAN"
assert_no_file "$GITAPP/DEP_SCRIPT_RAN" "git dep [scripts] ran on add"
assert_no_file "$GITAPP/DEP_INCLUDE_RAN" "git dep include-hook ran on add"

echo "v1.2" > "$FIX/README.md"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "v1.2"
git -C "$FIX" tag v1.2.0

rm -f "$GITAPP/SCRIPT_RAN"
"$ROOT/spool" update fixture --enable-scripts
grep -q "tag = 'v1.2.0'" "$GITAPP/coil.lock"
test -f "$GITAPP/SCRIPT_RAN"
grep -q "pre_update" "$GITAPP/SCRIPT_RAN"
grep -q "post_update" "$GITAPP/SCRIPT_RAN"
if grep -q "pre_install" "$GITAPP/SCRIPT_RAN" || grep -q "post_install" "$GITAPP/SCRIPT_RAN"; then
  echo "smoke_scripts: update ran install scripts" >&2
  exit 1
fi
assert_no_file "$GITAPP/DEP_SCRIPT_RAN" "git dep [scripts] ran on update"

# Failure prints path + exit status and aborts.
FAILAPP="$BASE/failapp"
write_app "$FAILAPP" "failapp"
write_fail_script "$FAILAPP/scripts/pre-install.sh"
export SPOOL_PROJECT="$FAILAPP"
set +e
OUT="$("$ROOT/spool" install --enable-scripts 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]]; then
  echo "smoke_scripts: expected failing pre_install to abort" >&2
  echo "$OUT" >&2
  exit 1
fi
echo "$OUT" | grep -q "./scripts/pre-install.sh"
echo "$OUT" | grep -q "7"

echo "smoke_scripts: ok"
