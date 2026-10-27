#!/usr/bin/env bash
# `spool cache gc` removes checkouts and clones no known project's coil.lock
# uses any more, and keeps the ones that are still locked somewhere.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL="${SPOOL_BIN:-$ROOT/target/spool}"
COIL_BIN="${COIL:-coil}"
BASE="$ROOT/scratch/cache_gc"
CACHE="$BASE/cache"

if [[ ! -x "$COIL_BIN" ]]; then
  if ! command -v "$COIL_BIN" >/dev/null 2>&1; then
    echo "smoke_cache_gc: coil not found (set COIL)" >&2
    exit 1
  fi
fi

rm -rf "$BASE"
mkdir -p "$BASE"

# lib: v0.1.0 and v0.2.0 (different trees). other: only project c uses it.
make_repo() {
  local dir="$1" name="$2"
  mkdir -p "$dir/src"
  printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "$name" > "$dir/coil.toml"
  echo "fn v() -> int { return 1; }" > "$dir/src/$name.hy"
  git init -q "$dir"
  git -C "$dir" config user.email "spool@test"
  git -C "$dir" config user.name "spool"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$name 0.1.0"
  git -C "$dir" tag v0.1.0
}
make_repo "$BASE/lib" lib
echo "fn v() -> int { return 2; }" > "$BASE/lib/src/lib.hy"
git -C "$BASE/lib" commit -q -am "lib 0.2.0"
git -C "$BASE/lib" tag v0.2.0
make_repo "$BASE/other" other

write_app() {
  local dest="$1" deps="$2"
  mkdir -p "$dest/src"
  printf '[package]\nname = "app"\nversion = "0.0.1"\n\n[module]\nroots = ["./src"]\n\n[dependencies]\n%s\n' "$deps" > "$dest/coil.toml"
}

export COIL="$COIL_BIN"
export XDG_CACHE_HOME="$CACHE"
CACHE="$CACHE/coil"
# No grace period: everything this script made is "new".
export SPOOL_CACHE_GC_GRACE_MIN=0

A="$BASE/a"
B="$BASE/b"
C="$BASE/c"
write_app "$A" "lib = { git = \"file://$BASE/lib\", version = \"=0.1.0\" }"
write_app "$B" "lib = { git = \"file://$BASE/lib\", version = \"=0.2.0\" }"
write_app "$C" "other = { git = \"file://$BASE/other\", version = \"^0.1\" }"
for p in "$A" "$B" "$C"; do
  SPOOL_PROJECT="$p" "$SPOOL" install >/dev/null
done
real() { (cd "$1" && pwd -P); }
OLD="$(dirname "$(real "$A/.spool/deps/lib")")"
NEW="$(dirname "$(real "$B/.spool/deps/lib")")"
OTHER="$(dirname "$(real "$C/.spool/deps/other")")"
OTHER_BARE="$(cd "$OTHER" && git rev-parse --path-format=absolute --git-common-dir)"
test "$OLD" != "$NEW"

# a moves to 0.2.0 (its 0.1.0 checkout goes stale); c is deleted.
sed -i.bak 's/=0.1.0/=0.2.0/' "$A/coil.toml" && rm -f "$A/coil.toml.bak"
SPOOL_PROJECT="$A" "$SPOOL" install >/dev/null
rm -rf "$C"

# --dry-run lists, removes nothing.
DRY="$(SPOOL_PROJECT="$A" "$SPOOL" cache gc --dry-run 2>&1)"
echo "$DRY" | grep -q "$(basename "$OLD")"
test -d "$OLD"

SPOOL_PROJECT="$A" "$SPOOL" cache gc >/dev/null 2>&1
test ! -e "$OLD"
test ! -e "$OTHER"
test ! -e "$OTHER_BARE"
test -d "$NEW"
test -d "$CACHE/git/checkouts"
# Projects still build against what is left.
test "$(real "$A/.spool/deps/lib")" = "$(real "$B/.spool/deps/lib")"
test -f "$B/.spool/deps/lib/lib.hy"
# The deleted project is forgotten: a second gc has nothing to do.
AGAIN="$(SPOOL_PROJECT="$A" "$SPOOL" cache gc 2>&1)"
echo "$AGAIN" | grep -q "nothing to remove"

echo "smoke_cache_gc: ok"
