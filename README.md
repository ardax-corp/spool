# spool

Git-based library dependency manager for [Coil](https://github.com/ardax-corp/coil-lang).

`spool` is a **Coil userland** project (not part of the `coil` Rust CLI). It resolves
semver tags from git remotes, pins them in `coil.lock`, fetches into a shared
content-addressed cache, and maintains project-local `.spool/deps` roots that the
compiler already understands via `[module].roots`.

## Naming

| Tool | Role |
|------|------|
| **`spool`** | Library dependencies (`install` / `add` / `update`) |
| **`coil package`** | Embed a `.hyc` into a runner executable — unrelated |

## Status (M4)

- [x] `coil.lock` read/write (COI-5)
- [x] Git fetch into content-addressed cache (COI-4) — bash `fetch.sh` + shared cache
- [x] Manage `.spool/deps` + ensure `./.spool/deps` in `[module].roots` (COI-6)
- [x] `spool install` (COI-7) via `./spool install` (plan → fetch → link)
- [x] `spool add` / `update` (COI-8–9)
- [x] Demo package `greet` (`examples/greet`, also [coil-greet](https://github.com/ardax-corp/coil-greet) `v0.1.0`)
- [x] Consume smoke: install → `use` → compile/run (`scripts/smoke_consume.sh`)
- [x] Private git via host credentials (COI-13)
- [x] Lock integrity + diagnostics (COI-14)
- [x] Transitive deps and diamond errors (COI-15)
- [x] Engine range `[package].coil` fail-closed on install/add/update (COI-105)
- [x] Hook trust gate: `--ignore-scripts`, lock `hook_path` / `hook_hash`, `allow-include` (COI-227)
- [x] Current-project `[scripts]` runner (`--enable-scripts`, host `sh`) (COI-103)
- [x] Dependency `[package].include` runner after link (COI-104)

## Requirements

- Coil toolchain (`coil` on `PATH`, or set `COIL`)
- Host `git` and `sh`
- Coil stdlib: default `../coil-stdlib/src` relative to this repo
  ([coil-stdlib](https://github.com/ardax-corp/coil-stdlib))
- coil-toml: default `../coil-toml/src` for `coil.toml` decode
  ([coil-toml](https://github.com/ardax-corp/coil-toml))

## Engine range

A package may set `[package].coil` to a semver range against the running Coil
toolchain. The key is optional. Spool stores the string as written.

```toml
[package]
name = "http"
version = "1.2.0"
coil = ">=0.1.0"
```

The engine string is `coil --version`. coil-lang prints `coil 0.1.0` for that
flag and for `-V`. Spool takes the token after `coil` and compares it to the
range. It uses the `coil` binary already selected by `COIL` or `PATH`.

`spool install`, `add`, and `update` check the current project, path deps, and
locked git checkouts that already exist. Missing key and in-range `>=0.1.0` are
no-ops. Out-of-range `>=0.2.0` and `^0.2` fail closed before git fetch.

A git dep whose `coil.toml` is not on disk yet is checked after checkout, before
`link`.

The diagnostic names the package, the range, and the running version:

```text
package http requires coil >=0.2.0, running 0.1.0
```

Range language is the same as git-dep `version`: caret (`^`), `>=`, `>`, `<=`,
`<`, `=`, exact, or `*`.

## Hook trust

Hooks are off by default. `may_run_hook` is the gate. Every host `sh` of a user
script goes through it first (`kind` `script` for current-project `[scripts]`,
`kind` `include` for a dependency `[package].include`). `allow_exec` is not a
gate.

`--enable-scripts` opts in. `--ignore-scripts` always wins, including in CI.
`SPOOL_IGNORE_SCRIPTS=0` is the same opt-in the gate already understands.

```bash
./spool install --enable-scripts
./spool install --ignore-scripts
./spool allow-include http
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
`spool: <path> exited <status>` and aborts. A missing file is
`spool: missing script <path>`.

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
`spool: missing include-hook <name> <path>`.

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
spool: include-hook http ./hooks/include.sh exited 9
```

## Install order

`spool install` is this sequence. Gates live in [Hook trust](#hook-trust),
[Project scripts](#project-scripts), and [Include hooks](#include-hooks).

1. `check_install` — `coil.toml` present; git deps already in `coil.lock`
2. `check_engine` on the current project, path deps, and cached `coil.toml` —
   engine first so an unsatisfied `[package].coil` never fetches
3. `pre_install` if `--enable-scripts` — before fetch so a failing project
   script leaves lock and link alone
4. Plan: write `.spool/fetch.sh` and `.spool/links.tsv`
5. Bash `fetch.sh`: clone/fetch + worktree
6. Verify lock `content_hash` against each checkout `HEAD` tree
7. `check_engine` again on new checkouts
8. Link `.spool/deps` and inject `[module].roots`
9. Include-hooks after link (the hook can see its own checkout)
10. `post_install` if `--enable-scripts` — only after a successful link; does
    not run if include failed

Hooks default off. `--enable-scripts` opts in. `--ignore-scripts` always wins.
Every `sh` goes through `may_run_hook` first.

Two lock homes: consumer `[scripts]` hashes live in lock `[scripts]`
(`git hash-object`; the current project is not a `[[package]]` row). Include
pins are `hook_path` / `hook_hash` on that dep's `[[package]]`. First opted-in
run pins. An existing lock hash is checked first; a changed file is a mismatch
and does not `sh` or rewrite the lock. No lock row (path deps) is deny, no
`sh`. Include-hooks also need `spool allow-include <name>`. A dep's own
`[scripts]` never run on a consumer install.

`add` uses the install pair. `update` uses `pre_update` / `post_update`. Both
share the same materialize, engine first, include/scripts at the end.

This path does not fetch a `.so` or write `[ffi] search_paths`.

## Cache

Default root: `$XDG_CACHE_HOME/coil` or `~/.cache/coil`.

Override:

- Env: `COIL_CACHE_DIR` (wins)
- File: `~/.config/coil/config.toml` → `[cache] dir = "…"`

Layout:

```text
<cache_root>/git/
  <host>/<owner>/<repo>/     # bare clone
  checkouts/
    <tree-id>/               # detached worktree
```

## Develop

```bash
export COIL=/path/to/coil-lang/target/release/coil
$COIL test
./spool help
./scripts/smoke_install.sh   # local git fixture → install
./scripts/smoke_add.sh       # add git+path deps, then update
./scripts/smoke_consume.sh   # add greet, `use greet::hello`, run it
./scripts/smoke_integrity.sh # hash mismatch, missing/corrupt lock
./scripts/smoke_auth.sh      # git auth failure message
./scripts/smoke_transitive.sh # unify compatible pins, diamond error
./scripts/smoke_engine.sh     # [package].coil range: omit / in-range / too-old
./scripts/smoke_hooks.sh      # --ignore-scripts, allow-include, default include-hooks stay off
./scripts/smoke_scripts.sh    # current-project [scripts]: default off, opt-in, fail, no dep scripts
./scripts/smoke_include.sh    # dep include-hooks: allowlist, hash pin, fail, no dep [scripts]
```

## Private git

spool does not store credentials. It runs host `git` with `GIT_TERMINAL_PROMPT=0` so a missing credential fails instead of hanging on a prompt.

Use whatever already works for `git clone` on your machine:

- `ssh-agent` and `git@host:owner/repo.git` URLs
- `GIT_ASKPASS` / `SSH_ASKPASS`
- git credential helpers
- `url.<base>.insteadOf` in `~/.gitconfig` to rewrite HTTPS to SSH

`GIT_SSH_COMMAND` and those variables are passed through to clone/fetch/`ls-remote`.

## Consume a library

`.spool/deps/<name>` is a symlink to the checkout's `src/` directory when that
exists, so `use greet::hello` maps to `hello.hy` in the package.

```bash
./spool add greet --git https://github.com/ardax-corp/coil-greet.git --version '^0.1'
```

```coil
use greet::hello;
```

`greet` is function-style on purpose. Userland class types still cannot cross
module boundaries (COI-12). Enums and functions in a git/path dep compile and run.

The locked `install` order is under [Install order](#install-order).

`add` / `update` resolve tags and merge `coil.lock`, then the same materialize.
Transitive git deps unify compatible pins and error on diamonds. `add` uses
`pre_install` / `post_install`. `update` uses `pre_update` / `post_update`.

Design: Linear project **Git-based package manager** (COI-1 design doc).

## Coil quirks this repo works around

- No forward references within a module file
- `env::exec` / `env::exit` warnings fail in-memory compile; `extern` in imported
  modules panics (`invalid library handle`); `system(3)` breaks after `Vec` alloc
- So git stays in the bash driver; Coil does plan/pick/lock/link only
