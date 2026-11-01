#!/usr/bin/env bash
# #32: `version = "latest"` tracks the tip of the default branch (git ls-remote URL HEAD).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
COIL_BIN="${COIL:-coil}"
CACHE="$ROOT/scratch/cache_latest"
BASE="$ROOT/scratch/latest"

fail() {
  echo "smoke_latest: $1" >&2
  exit 1
}

rm -rf "$CACHE" "$BASE"
mkdir -p "$BASE"

init_git() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email "spool@test"
  git -C "$dir" config user.name "spool"
}

commit() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

lib_toml() {
  cat > "$1/coil.toml" <<EOF
[package]
name = "$2"
version = "0.1.0"
[module]
roots = ["./src"]
$3
EOF
}

# l: untagged, default branch `master`, plus a `topic` branch that must be ignored.
L="$BASE/l"
mkdir -p "$L/src"
lib_toml "$L" l ""
echo "// l 1" > "$L/src/lib.coil"
init_git "$L"
git -C "$L" checkout -q -b master
commit "$L" "l 1"
git -C "$L" checkout -q -b topic
echo "// l topic" > "$L/src/lib.coil"
commit "$L" "l topic"
TOPIC_SHA="$(git -C "$L" rev-parse HEAD)"
git -C "$L" checkout -q master
L1="$(git -C "$L" rev-parse HEAD)"
L_URL="file://$L"

# t: tagged v1.0.0, so a bare `spool add` keeps picking tags.
T="$BASE/t"
mkdir -p "$T/src"
lib_toml "$T" t ""
echo "// t" > "$T/src/lib.coil"
init_git "$T"
commit "$T" "t 1.0.0"
git -C "$T" tag v1.0.0
T_URL="file://$T"

# a: depends on l = latest (transitive latest).
A="$BASE/a"
mkdir -p "$A/src"
lib_toml "$A" a "[dependencies]
l = { git = \"$L_URL\", version = \"latest\" }"
echo "// a" > "$A/src/lib.coil"
init_git "$A"
commit "$A" "a 0.1.0"
git -C "$A" tag v0.1.0
A_URL="file://$A"

# d: depends on l ^1.0 (conflicts with a's latest).
D="$BASE/d"
mkdir -p "$D/src"
lib_toml "$D" d "[dependencies]
l = { git = \"$L_URL\", version = \"^1.0\" }"
echo "// d" > "$D/src/lib.coil"
init_git "$D"
commit "$D" "d 0.1.0"
git -C "$D" tag v0.1.0
D_URL="file://$D"

write_app() {
  mkdir -p "$1/src"
  cat > "$1/coil.toml" <<EOF
[package]
name = "app"
version = "0.0.1"
[module]
roots = ["./src"]
[env]
EOF
  echo "// app" > "$1/src/main.coil"
}

export COIL="$COIL_BIN"
export XDG_CACHE_HOME="$CACHE"
CACHE="$CACHE/coil"

# 1. --version latest locks the default-branch tip like a branch pin.
P1="$BASE/p1"
write_app "$P1"
export SPOOL_PROJECT="$P1"
"$SPOOL" add l --git "$L_URL" --version latest
grep -q "l = { git = \"$L_URL\", version = \"latest\" }" "$P1/coil.toml" || fail "manifest lacks version = latest"
grep -q "rev = '$L1'" "$P1/coil.lock" || fail "lock is not at the master tip"
grep -q "ref = 'HEAD'" "$P1/coil.lock" || fail "lock lacks ref = HEAD"
grep -q "tag = ''" "$P1/coil.lock" || fail "latest lock row has a tag"
if grep -q "$TOPIC_SHA" "$P1/coil.lock"; then fail "picked the topic branch"; fi
test -L "$P1/.spool/deps/l" || fail "l not linked"
(cd "$P1" && "$SPOOL" tree) | grep -q "l latest @ ${L1:0:10}" || fail "tree does not show latest"

# 2. install keeps the locked sha; update moves it.
echo "// l 2" > "$L/src/lib.coil"
commit "$L" "l 2"
L2="$(git -C "$L" rev-parse HEAD)"
"$SPOOL" install
grep -q "rev = '$L1'" "$P1/coil.lock" || fail "install moved the latest pin"
"$SPOOL" install --locked
OUT="$(cd "$P1" && "$SPOOL" outdated)"
echo "$OUT" | grep -q "${L2:0:10}" || fail "outdated does not show the new tip: $OUT"
if echo "$OUT" | grep -q "all dependencies are up to date"; then fail "outdated says up to date"; fi
"$SPOOL" update l
grep -q "rev = '$L2'" "$P1/coil.lock" || fail "update did not move the latest pin"
grep -q "ref = 'HEAD'" "$P1/coil.lock" || fail "update dropped ref = HEAD"
(cd "$P1" && "$SPOOL" outdated) | grep -q "all dependencies are up to date" || fail "outdated after update"

# 3. A bare add uses latest only when the repo has no version tags.
P2="$BASE/p2"
write_app "$P2"
export SPOOL_PROJECT="$P2"
OUT="$("$SPOOL" add l --git "$L_URL" 2>&1)"
echo "$OUT" | grep -q "note: l has no version tags; using version = \"latest\"" || fail "no latest note: $OUT"
[[ "$(echo "$OUT" | grep -c "note:")" -eq 1 ]] || fail "expected one note line: $OUT"
grep -q "l = { git = \"$L_URL\", version = \"latest\" }" "$P2/coil.toml" || fail "bare add did not write latest"
grep -q "rev = '$L2'" "$P2/coil.lock" || fail "bare add not at the tip"
OUT="$("$SPOOL" add t --git "$T_URL" 2>&1)"
if echo "$OUT" | grep -q "note:"; then fail "tagged repo printed a note: $OUT"; fi
grep -q "t = { git = \"$T_URL\", version = \"\\*\" }" "$P2/coil.toml" || fail "tagged bare add did not write *"
grep -q "tag = 'v1.0.0'" "$P2/coil.lock" || fail "tagged bare add did not lock v1.0.0"

# 4. Transitive version = "latest".
P3="$BASE/p3"
write_app "$P3"
export SPOOL_PROJECT="$P3"
"$SPOOL" add a --git "$A_URL" --version "^0.1"
grep -q "name = 'l'" "$P3/coil.lock" || fail "transitive latest not locked"
grep -q "rev = '$L2'" "$P3/coil.lock" || fail "transitive latest not at the tip"
test -L "$P3/.spool/deps/l" || fail "transitive l not linked"

# 5. latest combined with a range is a diamond conflict.
P4="$BASE/p4"
write_app "$P4"
export SPOOL_PROJECT="$P4"
"$SPOOL" add a --git "$A_URL" --version "^0.1"
set +e
OUT="$("$SPOOL" add d --git "$D_URL" --version "^0.1" 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || fail "expected a diamond failure"
echo "$OUT" | grep -q "diamond conflict for l" || fail "no diamond message: $OUT"
echo "$OUT" | grep -q "a requires latest" || fail "diamond does not name a: $OUT"
echo "$OUT" | grep -q "d requires ^1.0" || fail "diamond does not name d: $OUT"

# 6. --version latest and --rev together are refused.
set +e
OUT="$("$SPOOL" add x --git "$L_URL" --version latest --rev master 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || fail "--version latest --rev should fail"

echo "smoke_latest: ok"
