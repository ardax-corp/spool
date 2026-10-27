# Sourced by smoke scripts whose projects import stdlib modules: there is no
# global stdlib, so each consumer declares one. It is the coil-stdlib checkout
# bootstrap.sh built spool with (SPOOL_SMOKE_STDLIB overrides), pinned to its
# HEAD so no smoke test needs the network.
SMOKE_STDLIB="${SPOOL_SMOKE_STDLIB:-$ROOT/.bootstrap/coil-stdlib}"
if ! git -C "$SMOKE_STDLIB" rev-parse HEAD >/dev/null 2>&1; then
  echo "$(basename "$0"): no coil-stdlib checkout at $SMOKE_STDLIB (run ./bootstrap.sh or set SPOOL_SMOKE_STDLIB)" >&2
  exit 1
fi
SMOKE_STDLIB_DEP="stdlib = { git = \"file://$SMOKE_STDLIB\", rev = \"$(git -C "$SMOKE_STDLIB" rev-parse HEAD)\" }"
