# spool

Project and dependency manager for [Coil](https://github.com/ardax-corp/coil-lang):
the high-level front end over the `coil` toolchain, shipped as one standalone
executable.

- **Projects**: `new`, `init`, `build`, `run`, `check`, `test`, `fmt`, `clean`
- **Dependencies**: git (semver tags or a pinned `rev`) and path deps, a
  `coil.lock`, transitive resolution, `add`/`remove`/`update`, `tree`, `outdated`
- **Natives**: `download` fetches `[[ffi.native]]` shared libraries
- **Tooling**: `doctor`, `cache`

coil does not read `[module].roots` from `coil.toml`, so module roots come
from `--root` flags. spool builds those flags from the manifest, the linked
dependencies, and the stdlib, then runs `coil` for you.

## Install

spool is written in Coil and packaged with `coil package`:

```bash
./bootstrap.sh              # → target/spool
./bootstrap.sh --install    # also: ~/.local/bin/spool, ~/.coil/stdlib,
                            # and ~/.coil/bin/coil if bootstrap built it
```

`bootstrap.sh`:

1. Looks for a usable coil: `$COIL`, `coil` on `PATH`, `~/.coil/bin/coil`, or a
   previous bootstrap build. A candidate needs to meet `COIL_MIN_VERSION`, have
   `coil package`, and compile a probe that uses `env::args/exec/exit`. A
   previous bootstrap build is reused only while its checkout is still the
   newest `COIL_LANG_REF`; otherwise it is rebuilt (incrementally). It warns
   when the coil lacks `coil mutate` or `coil test --json`.
2. If none qualifies, it downloads the latest GitHub release asset
   `coil-<triple>.tar.gz`, when one exists.
3. If there is no release either, it builds coil-lang `main` from source into
   `.bootstrap/coil-lang` (needs `cargo`, libffi and pcre2 dev files).
4. Fetches coil-stdlib (default branch), coil-toml and coil-json (at the `rev`s
   pinned in this repo's `coil.toml`) into `.bootstrap/`. Pass `--use-siblings`
   to build against `../coil-stdlib`, `../coil-toml` and `../coil-json` instead.
5. Runs `coil package spool.hy -o target/spool`.

Other flags: `--from-source` (skip installed coil and releases),
`--coil-only`. Overrides: `COIL_LANG_REPO/REF`, `COIL_STDLIB_REPO/REF`,
`COIL_TOML_REPO/REF`, `COIL_JSON_REPO/REF`, `COIL_STDLIB_DIR`, `COIL_TOML_DIR`,
`COIL_JSON_DIR`, `SPOOL_BOOTSTRAP_DIR`.

Runtime requirements: host `git` and `sh`. `curl` is needed for `download`.

## Quick start

```bash
spool new hello && cd hello
spool run                 # packages target/hello and runs it
spool run -- a b          # program arguments after --
spool test                # coil test with the project's roots
spool add greet --git https://github.com/ardax-corp/coil-greet.git --version '^0.1'
spool tree
```

`spool new <name> --lib` creates a library. Its entry module is
`src/<name>.hy`, so consumers write `use <name>::{item}`.

## Commands

| Command | What it does |
|---|---|
| `new <name> [--lib] [--no-git]` / `init` | scaffold `coil.toml`, `src/`, `tests/`, `.gitignore` (and `git init`) |
| `build [-o PATH] [-O LEVEL]` | `coil package` of `[entry].file` (default `src/main.hy`) into `target/<name>` |
| `run [-O LEVEL] [-- ARGS]` | build, then exec `target/<name>` with ARGS and its exit code |
| `check` | `coil compile` without packaging |
| `clean [--all]` | remove `target/` (`--all`: also `.spool/`) |
| `test [PATH] [FLAGS]` | `coil test` (default `./tests`): `--coverage`, `--seed N`, `-j N`, `--fail-fast`, … |
| `coverage [PATH] [FLAGS]` | `test --coverage`: per-file coverage table and `target/coverage/lcov.info` (`--coverage-out F`, `--coverage-per-test F`) |
| `infect [PATH] [FLAGS]` | mutation testing (`coil mutate`): `--files GLOB`, `--operators`, `--min-score P`, `--json`, … |
| `fmt [--check] [PATHS]` | `coil fmt` (default `src tests`) |
| `debug [FILE] [FLAGS]` | `coil debug` on `[entry].file` (`--dap` for an IDE adapter) |
| `dissect [FILE] [FLAGS]` | `coil dissect` of `[entry].file` (`--fn`, `--il`, `--ast`, …) |
| `lsp` | `coil lsp` on stdio, started from the project root |
| `coil [ARGS]` | plain `coil ARGS` from the project root (no flags added) |
| `install [--locked] [--with-natives]` | fetch, resolve, prune and link dependencies |
| `add <name> --git URL [--version REQ \| --rev REV]` | declare a git dependency, then install |
| `add <name> --path DIR` | declare a path dependency, then install |
| `remove <name>` | drop the dependency, prune `coil.lock` and stale links |
| `update [name]` | re-resolve to the newest allowed versions (moves `rev` branches) |
| `tree` | print the dependency graph |
| `outdated` | locked vs newest compatible vs newest tag |
| `download [EXE]` | fetch FFI natives for the project or a packaged EXE |
| `allow-include <name>` | allow a dependency's include-hook |
| `doctor` | check coil, stdlib, git, sh, curl, cache and project roots |
| `cache dir` / `cache clean` | show or clear the shared git cache |

Commands that compile (`build`, `run`, `check`, `test`, `infect`, `debug`,
`dissect`) run `install` first when dependencies are declared but
`.spool/deps` does not exist yet.

`test`, `infect`, `fmt`, `debug`, `dissect` and `lsp` forward every flag to
coil unchanged, so `spool <cmd> --help` shows coil's own options and new coil
flags work without a spool release. spool adds the compile flags below and,
for `debug`/`dissect`, `[entry].file` when no file is named.

### Test and mutation reports

`test` and `infect` run coil with `--json` and render its event stream
while the run goes: one line per test file, failing cases with their reason
and captured output, then a summary (and coverage per file with
`--coverage`). `infect` lists surviving and untested mutants as they finish
and ends with the mutation score. The exit status is 1 on a failed test, a
score under `--min-score`, or a harness error.

| Flag | Effect |
|---|---|
| `--color auto\|always\|never` | default `auto`: color when stdout is a terminal, unless `NO_COLOR` is set or `TERM=dumb` |
| `--plain` | coil's own text report instead |
| `--json` | coil's raw NDJSON events (for tools); also implied by `--log-json` / `--log-lsp` |

This needs a coil whose `coil test` / `coil mutate` stream `--json` events
(ardax-corp/coil-lang#584). With an older coil, spool says so and shows
coil's own report; `spool infect` needs `coil mutate`. `spool doctor` lists
which of these the coil it found has.

`run` packages `target/<name>` rather than running the entry in memory:
`coil FILE` cannot pass program arguments, and the packaged binary sees a
normal argv.

Editors: point the Coil LSP client at `spool lsp`. It starts `coil lsp` with
the same roots (`[module].roots`, `.spool/deps`, the stdlib) and grants as
every other command, so dependencies resolve and granted calls such as
`env::exec` are not flagged. That needs a coil whose `coil lsp` accepts
`--root` (ardax-corp/coil-lang#589); with an older one spool says so and
starts it without flags.

`add` and `remove` restore `coil.toml` and `coil.lock` if the install fails.

### Compile flags

spool runs `coil` from the project root with:

- `--root` for each `[module].roots` entry (default `./src`)
- `--root .spool/deps` when dependencies are linked
- `--root <stdlib>` unless a manifest root already is a stdlib. The stdlib is
  found through `COIL_STDLIB_DIR`, `COIL_STDLIB`, `[stdlib] dir` in
  `~/.config/coil/config.toml`, or `~/.coil/stdlib`
- grants the manifest records: `[permissions]` (`read`, `write`, `net`,
  `env`, `exec`, `exit`, `attach` set to `true` give `--allow-<name>`, and
  `all = true` gives `--allow-all`), the older `[env]
  allow_exec/allow_exit/allow_ffi_exec` and `[ffi] allow_attach`, `[ffi]
  allow` (`--allow-dload`), and `[ffi] search_paths` (`--ffi-search-path`)

A program needs a grant for each capability its `main` (or a test) can
reach: reading or writing files, the network, environment variables,
running programs. coil names the missing flag when one is not granted:

```toml
[permissions]
read = true
net = true
```

The coil binary is `$COIL`, then `coil` on `PATH`, then `~/.coil/bin/coil`.

## Dependencies

```toml
[dependencies]
greet = { git = "https://github.com/ardax-corp/coil-greet.git", version = "^0.1" }
toml  = { git = "https://github.com/ardax-corp/coil-toml.git", rev = "3e0da9d…" }
local = { path = "../local" }
```

- `version` is matched against `v`-prefixed or bare semver tags: `^`, `~`,
  `>=`, `>`, `<=`, `<`, `=`, exact, `*`, and comma-joined ranges
  (`">=1.2, <2"`). Prerelease tags are never picked by a range.
- `rev` pins a branch, tag or commit. The lock stores the resolved sha plus the
  `ref`. `install` keeps the pin, and `update` moves a branch pin.
- `trusted = true` is accepted, since coil's schema allows it. spool does not
  use it.

Resolution walks the reachable graph: the project, its path deps, and every
locked checkout's `coil.toml`. Compatible requirements unify. Incompatible
ones fail with the requesters named:

```text
diamond conflict for base: hello requires @dev, mid requires ^1
```

Lock rows nothing reaches any more are pruned. `install --locked` fails
instead of changing the lock (CI):

```text
coil.lock is out of date (needs fixture); run without --locked to update it
```

Every locked checkout is verified against its `content_hash` (the git tree
id). A mismatched checkout is deleted from the cache and the command fails.

Names and URLs from any manifest, including transitive ones, are validated.
Package names match `[A-Za-z_][A-Za-z0-9_-]*`. Git URLs must use `https://`,
`http://`, `ssh://`, `git://`, `git@host:`, `file://` or an absolute path.
Values reach `git`/`sh` only as positional arguments, never inside a script.

### Linking

```text
.spool/deps/<name>     -> <checkout>/src
.spool/deps/<name>.hy  -> <checkout>/src/<name>.hy   (when it exists)
```

`use greet::hello` resolves through the directory link. `use toml::{Toml}`
resolves through the file link, which covers single-file libraries named after
their package. `coil.toml` is never edited.

## Engine range

A package may set `[package].coil` to a semver range. spool compares it with
`coil --version` of the coil it would run. Prerelease suffixes such as
`0.2.0-dev` are compared by their base version.

```toml
[package]
name = "http"
version = "1.2.0"
coil = ">=0.1.0"
```

The project, path deps and locked checkouts are checked before anything is
fetched. New checkouts are checked again before link:

```text
package http requires coil >=0.2.0, running 0.1.0
```

## Hook trust

Hooks are off by default. `may_run_hook` is the gate. Every host `sh` of a user
script goes through it first (`kind` `script` for current-project `[scripts]`,
`kind` `include` for a dependency `[package].include`). `allow_exec` is not a
gate.

`--enable-scripts` opts in. `--ignore-scripts` always wins, including in CI.
`SPOOL_IGNORE_SCRIPTS=0` is the same opt-in the gate already understands.

```bash
spool install --enable-scripts
spool install --ignore-scripts
spool allow-include http
```

`spool allow-include <name>` records the consumer allowlist in `coil.lock`,
not in `coil.toml`. coil-lang still errors on unknown manifest sections, so do
not add a `[hooks]` table there. `[package].include` is the include path on a
package. The allowlist is the lock `[hooks]` table:

```toml
[hooks]
allow_include = ['http']
```

`[[package]]` stores `hook_path` and `hook_hash` for include-hooks. Those
run after link when opted in. They still need `allow_include` plus a matching
path and hash. Empty hash is first-pin then the same gate. A present hash is
never rewritten. A missing lock row is deny, no `sh`.

`may_run_hook` raises these strings:

```text
hooks are off (--ignore-scripts)
include-hook for http is not allowlisted
untrusted hook: missing lock hash for http
hook path mismatch for http
hook hash mismatch for http
```

## Project scripts

The current project's `coil.toml` may declare lifecycle scripts. Paths are
relative to the project root. Missing keys are no-ops. Unknown keys are errors
(coil-lang already owns that schema).

```toml
[scripts]
pre_install = "./scripts/pre-install.sh"
post_install = "./scripts/post-install.sh"
pre_update = "./scripts/pre-update.sh"
post_update = "./scripts/post-update.sh"
```

Default is still off. `--enable-scripts` opts in on `install`, `add`, and
`update`. `--ignore-scripts` wins even when both flags are present.

With `--enable-scripts`:

- `spool install` runs `pre_install` then fetch/link, then `post_install`
- `spool update` runs `pre_update` / `post_update`
- `spool add` uses the install pair

`pre_*` runs after engine checks and before fetch/link. `post_*` runs after a
successful link. `sh` runs from the project root. Non-zero exit is
`spool: error: <path> exited <status>` and aborts. A missing file is
`spool: error: missing script <path>`.

Every `sh` goes through `may_run_hook` first (`kind` `script`). Scripts skip
the include allowlist. They still need a lock hash.

Hashes live in lock `[scripts]`, not on a `[[package]]` row. The hash is
`git hash-object` of the file. First opted-in run records path and hash.
After that, the existing pin is checked first. A changed file is a hash
mismatch. It does not `sh` and does not rewrite the lock:

```toml
[scripts]
pre_install = './scripts/pre-install.sh'
pre_install_hash = 'abc123'
post_install = './scripts/post-install.sh'
post_install_hash = 'def456'
```

That diagnostic is `hook hash mismatch for <package>`, using the current
`[package].name` (or `app` if the name is empty).

A dependency's `[scripts]` are not executed during a consumer install. Those
fire only when that repo is the current project.

## Include hooks

A library may declare a hook that runs when another project depends on it.

```toml
[package]
name = "native-bits"
include = "./hooks/include.sh"
```

The path is relative to that package's checkout, not the consumer. Missing
`include` is a no-op. A declared file that is not on disk is
`spool: error: missing include-hook <name> <path>`.

`spool install`, `add`, and `update` run include-hooks after link, including
transitives. `sh` runs from the checkout. `SPOOL_PROJECT` is still the
consumer.

Default is still off. `--enable-scripts` / `SPOOL_IGNORE_SCRIPTS=0` opt in.
`--ignore-scripts` wins even when both flags are present. Include-hooks also
need `spool allow-include <name>` on the consumer. Opt-in without that
allowlist is deny, no `sh`. `allow_exec` is not the gate.

Every include `sh` goes through `may_run_hook` first (`kind` `include`). The
pin is `hook_path` / `hook_hash` on that dep's `[[package]]` row. The hash is
`git hash-object` of the file. First opted-in run records them when that row
exists and `hook_hash` is empty. No `[[package]]` row (a path dep, or any
name not in the lock) is missing lock hash: no first-pin, no `sh`. After a
pin exists, it is checked first. A changed include file is a hash mismatch.
It does not `sh` and does not rewrite the lock:

```toml
[[package]]
name = 'http'
hook_path = './hooks/include.sh'
hook_hash = 'abc123'
```

Non-zero exit aborts the consumer command:

```text
spool: error: include-hook http ./hooks/include.sh exited 9
```

## Install order

1. `coil.toml` parses; `[package].coil` of the project, path deps and cached
   checkouts
2. `pre_install` / `pre_update` if `--enable-scripts`
3. Check out every locked package and verify its tree id
4. Resolve (or, with `--locked`, fail if anything would change), then prune
5. Write `coil.lock` if it changed; engine check on new checkouts
6. Link `.spool/deps` (stale links removed)
7. Include-hooks (the hook can see its own checkout; `SPOOL_PROJECT` is the consumer)
8. `post_install` / `post_update` — only after a successful link
9. `--with-natives`: `download`

`add` and `remove` use the install pair; `update` uses the update pair.

## Native libraries (`spool download`)

Direct shared libraries declared in `[[ffi.native]]` (or embedded in a
packaged exe) are fetched into a content-addressed cache:

```text
~/.coil/natives/cache/<package>/<version>/<sha256_16>/<filename>
```

Override the root with `COIL_NATIVES_DIR`. Only https URLs are fetched. Each
file is checked against the lock's sha256 and size before it is moved into
place. Transitive sonames (`requires`) must come from the OS.

```bash
spool download ./hello          # a packaged exe
spool download                  # project [[ffi.native]]
spool install --with-natives
```

## Cache

Default root: `$XDG_CACHE_HOME/coil` or `~/.cache/coil`. `COIL_CACHE_DIR` wins,
then `[cache] dir` in `~/.config/coil/config.toml`.

```text
<cache_root>/git/
  <host>/<owner>/<repo>/     # bare clone
  checkouts/<tree-id>/       # detached worktree
```

## Private git

spool stores no credentials. git runs with `GIT_TERMINAL_PROMPT=0`, so a
missing credential fails instead of hanging. Use whatever works for
`git clone`: ssh-agent with `git@host:owner/repo.git`, `GIT_ASKPASS`,
credential helpers, or `url.<base>.insteadOf`.

## Develop

```bash
./bootstrap.sh    # rerun to pick up a newer coil-lang COIL_LANG_REF
export COIL=$PWD/.bootstrap/coil-lang/target/release/coil
export COIL_STDLIB_DIR=$PWD/.bootstrap/coil-stdlib
./target/spool install        # links coil-toml (pinned rev in coil.toml)
./target/spool test           # unit tests
./scripts/smoke_all.sh        # end-to-end smoke tests against target/spool
```

`spool.hy` is the entry; modules are under `src/`:

| Module | Role |
|---|---|
| `cli` | argv parsing |
| `proc` | child processes (constant scripts, positional args) |
| `git` | ls-remote, bare cache, worktrees, tree ids |
| `resolve` | constraints, tag/rev picking, pruning, engine checks |
| `sync` | the install/add/update/remove pipeline |
| `lock`, `manifest` | `coil.lock` and `coil.toml` |
| `roots` | `.spool/deps` links |
| `lifecycle`, `hooks` | `[scripts]`, include-hooks, trust gate |
| `toolchain` | coil/stdlib discovery, compile flags |
| `natives`, `report`, `scaffold` | `download`, `tree`/`outdated`, `new`/`init` |
| `render` | `test`/`infect` reports from coil's `--json` events (uses coil-json) |

## Coil quirks this repo works around

- No forward references within a module file.
- In a function that returns `Result`, a `Result`-typed **parameter** is
  corrupted (for example, its `Err` payload reads as empty). Helpers that
  inspect a `Result` return `bool` instead (see `tests/include.hy`).
- coil-toml panics (index out of bounds) when a document ends right after a
  value with no trailing newline. `decode_manifest` appends one.
- coil-toml `main` predates field-visibility enforcement. Spool pins the
  default-branch commit with the fix.
- Userland class types still cannot cross module boundaries (COI-12), so
  records are tab-joined strings.
