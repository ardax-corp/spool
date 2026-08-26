#!/usr/bin/env bash
# COI-104: dependency [package].include after link. Default off. allow-include required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COIL_BIN="${COIL:-coil}"
CACHE="$ROOT/scratch/cache_include"
BASE="$ROOT/scratch/include"

if [[ ! -x "$COIL_BIN" ]]; then
  if ! command -v "$COIL_BIN" >/dev/null 2>&1; then
    echo "smoke_include: coil not found (set COIL)" >&2
    exit 1
  fi
fi

rm -rf "$CACHE" "$BASE"
mkdir -p "$BASE"

write_include() {
  local dest="$1"
  local payload="$2"
  mkdir -p "$dest/hooks"
  cat > "$dest/hooks/include.sh" <<EOF
#!/bin/sh
${payload}
EOF
  chmod +x "$dest/hooks/include.sh"
}

write_lib() {
  local dest="$1"
  local name="$2"
  local extra_dep="${3:-}"
  rm -rf "$dest"
  mkdir -p "$dest/src" "$dest/scripts"
  cat > "$dest/coil.toml" <<EOF
[package]
name = "$name"
version = "1.0.0"
include = "./hooks/include.sh"

[module]
roots = ["./src"]
${extra_dep}
EOF
  echo "// lib" > "$dest/src/lib.hy"
  cat > "$dest/scripts/pre-install.sh" <<'EOS'
#!/bin/sh
touch "${SPOOL_PROJECT:-.}/DEP_SCRIPT_RAN"
EOS
  chmod +x "$dest/scripts/pre-install.sh"
  printf '\n[scripts]\npre_install = "./scripts/pre-install.sh"\n' >> "$dest/coil.toml"
  write_include "$dest" "touch \"\${SPOOL_PROJECT:-.}/INCLUDE_${name}\""
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
EOF
  echo "// app" > "$dest/src/main.hy"
  cat > "$dest/scripts/pre-install.sh" <<'EOS'
#!/bin/sh
echo pre_install >> "${SPOOL_PROJECT:-.}/SCRIPT_RAN"
EOS
  cat > "$dest/scripts/post-install.sh" <<'EOS'
#!/bin/sh
echo post_install >> "${SPOOL_PROJECT:-.}/SCRIPT_RAN"
EOS
  chmod +x "$dest/scripts/pre-install.sh" "$dest/scripts/post-install.sh"
}

assert_no_file() {
  local f="$1"
  local msg="$2"
  if [[ -f "$f" ]]; then
    echo "smoke_include: $msg ($f)" >&2
    cat "$f" >&2 || true
    exit 1
  fi
}

init_git() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "spool@test"
  git -C "$dir" config user.name "spool"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "v1"
  git -C "$dir" tag v1.0.0
}

export COIL="$COIL_BIN"
export COIL_CACHE_DIR="$CACHE"

LEAF="$BASE/leaf"
write_lib "$LEAF" "leaf"
init_git "$LEAF"
LEAF_URL="file://$LEAF"

MID="$BASE/mid"
write_lib "$MID" "mid" "[dependencies]
leaf = { git = \"$LEAF_URL\", version = \"^1.0\" }
"
init_git "$MID"
MID_URL="file://$MID"

APP="$BASE/app"
write_app "$APP" "app"
export SPOOL_PROJECT="$APP"

# Default off: declared include does not sh.
"$ROOT/spool" add mid --git "$MID_URL" --version "^1.0"
test -L "$APP/.spool/deps/mid"
test -L "$APP/.spool/deps/leaf"
assert_no_file "$APP/INCLUDE_mid" "default add ran include-hook"
assert_no_file "$APP/INCLUDE_leaf" "default add ran transitive include-hook"
assert_no_file "$APP/DEP_SCRIPT_RAN" "default add ran dep [scripts]"
if grep -q "hook_path" "$APP/coil.lock"; then
  echo "smoke_include: default add pinned hook_path" >&2
  exit 1
fi

# Opt-in without allowlist: deny, no sh.
set +e
NOALLOW_OUT="$("$ROOT/spool" install --enable-scripts 2>&1)"
NOALLOW_RC=$?
set -e
if [[ "$NOALLOW_RC" -eq 0 ]]; then
  echo "smoke_include: expected deny without allowlist" >&2
  echo "$NOALLOW_OUT" >&2
  exit 1
fi
echo "$NOALLOW_OUT" | grep -q "not allowlisted"
assert_no_file "$APP/INCLUDE_mid" "opt-in without allowlist ran include-hook"
assert_no_file "$APP/SCRIPT_RAN" "consumer scripts ran after include deny"

"$ROOT/spool" allow-include mid
"$ROOT/spool" allow-include leaf

# Opt-in + allowlist + matching hash: runs after link, transitives too.
rm -f "$APP/INCLUDE_mid" "$APP/INCLUDE_leaf" "$APP/SCRIPT_RAN" "$APP/DEP_SCRIPT_RAN"
"$ROOT/spool" install --enable-scripts
test -f "$APP/INCLUDE_mid"
test -f "$APP/INCLUDE_leaf"
test -f "$APP/SCRIPT_RAN"
grep -q "pre_install" "$APP/SCRIPT_RAN"
grep -q "post_install" "$APP/SCRIPT_RAN"
assert_no_file "$APP/DEP_SCRIPT_RAN" "dependency [scripts] ran on consumer"
grep -q "hook_path" "$APP/coil.lock"
grep -q "hook_hash" "$APP/coil.lock"

# Path is relative to the checkout: hook ran with cwd = package dest.
# Marker used SPOOL_PROJECT (consumer). Pin lives on the dep row, not [scripts].
if grep -q "include.sh" "$APP/coil.lock" && grep -q "name = 'mid'" "$APP/coil.lock"; then
  :
else
  echo "smoke_include: expected hook pin on [[package]] row" >&2
  cat "$APP/coil.lock" >&2
  exit 1
fi
if grep "pre_install" "$APP/coil.lock" | grep -q include; then
  echo "smoke_include: stuffed include pin into [scripts]" >&2
  exit 1
fi

# Changed include.sh with an existing lock hash: mismatch, no sh, pin unchanged.
OLD_HASH="$(grep "hook_hash" "$APP/coil.lock")"
write_include "$LEAF" "touch \"\${SPOOL_PROJECT:-.}/INCLUDE_leaf_changed\""
git -C "$LEAF" add -A
git -C "$LEAF" commit -q -m "change include"
git -C "$LEAF" tag v1.1.0
rm -f "$APP/INCLUDE_mid" "$APP/INCLUDE_leaf" "$APP/INCLUDE_leaf_changed"
set +e
CHG_OUT="$("$ROOT/spool" update leaf --enable-scripts 2>&1)"
CHG_RC=$?
set -e
if [[ "$CHG_RC" -eq 0 ]]; then
  echo "smoke_include: expected hash mismatch after include.sh change" >&2
  echo "$CHG_OUT" >&2
  exit 1
fi
echo "$CHG_OUT" | grep -q "hook hash mismatch"
assert_no_file "$APP/INCLUDE_leaf_changed" "changed include.sh still ran"
NEW_HASH="$(grep "hook_hash" "$APP/coil.lock")"
if [[ "$OLD_HASH" != "$NEW_HASH" ]]; then
  echo "smoke_include: lock hash was refreshed on mismatch" >&2
  exit 1
fi

# Restore leaf include so later commands can succeed if needed.
write_include "$LEAF" "touch \"\${SPOOL_PROJECT:-.}/INCLUDE_leaf\""
git -C "$LEAF" add -A
git -C "$LEAF" commit -q -m "restore include"
# Keep the original pin; do not update. Use a fresh app for the failing hook.

# Failing hook names package, path, and exit status.
FAIL="$BASE/failib"
write_lib "$FAIL" "failib"
write_include "$FAIL" "echo fail >> \"\${SPOOL_PROJECT:-.}/INCLUDE_failib\"; exit 9"
init_git "$FAIL"
FAIL_URL="file://$FAIL"
FAILAPP="$BASE/failapp"
write_app "$FAILAPP" "failapp"
export SPOOL_PROJECT="$FAILAPP"
"$ROOT/spool" add failib --git "$FAIL_URL" --version "^1.0"
"$ROOT/spool" allow-include failib
rm -f "$FAILAPP/INCLUDE_failib" "$FAILAPP/SCRIPT_RAN"
set +e
FAIL_OUT="$("$ROOT/spool" install --enable-scripts 2>&1)"
FAIL_RC=$?
set -e
if [[ "$FAIL_RC" -eq 0 ]]; then
  echo "smoke_include: expected failing include-hook to abort" >&2
  echo "$FAIL_OUT" >&2
  exit 1
fi
echo "$FAIL_OUT" | grep -q "failib"
echo "$FAIL_OUT" | grep -q "./hooks/include.sh"
echo "$FAIL_OUT" | grep -q "9"
if [[ -f "$FAILAPP/SCRIPT_RAN" ]] && grep -q "post_install" "$FAILAPP/SCRIPT_RAN"; then
  echo "smoke_include: consumer post_install ran after include failure" >&2
  exit 1
fi

# Missing include is a no-op even when opted in.
PLAIN="$BASE/plain"
rm -rf "$PLAIN"
mkdir -p "$PLAIN/src"
cat > "$PLAIN/coil.toml" <<'EOF'
[package]
name = "plain"
version = "1.0.0"
[module]
roots = ["./src"]
EOF
echo "// plain" > "$PLAIN/src/lib.hy"
init_git "$PLAIN"
PLAINAPP="$BASE/plainapp"
write_app "$PLAINAPP" "plainapp"
export SPOOL_PROJECT="$PLAINAPP"
"$ROOT/spool" add plain --git "file://$PLAIN" --version "^1.0" --enable-scripts
test -L "$PLAINAPP/.spool/deps/plain"
assert_no_file "$PLAINAPP/INCLUDE_plain" "missing include wrote a marker"

echo "smoke_include: ok"
