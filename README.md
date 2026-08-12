# spool

Git-based library dependency manager for [Coil](https://github.com/DaGhostman/coil-lang).

`spool` is a **Coil userland** project (not part of the `coil` Rust CLI). It resolves
semver tags from git remotes, pins them in `coil.lock`, fetches into a shared
content-addressed cache, and maintains project-local `.spool/deps` roots that the
compiler already understands via `[module].roots`.

## Naming

| Tool | Role |
|------|------|
| **`spool`** | Library dependencies (`install` / later `add` / `update`) |
| **`coil package`** | Embed a `.hyc` into a runner executable — unrelated |

## Status (M2)

- [x] `coil.lock` read/write (COI-5)
- [x] Git fetch into content-addressed cache (COI-4) — bash `fetch.sh` + shared cache
- [x] Manage `.spool/deps` + ensure `./.spool/deps` in `[module].roots` (COI-6)
- [x] `spool install` (COI-7) via `./spool install` (plan → fetch → link)
- [ ] `spool add` / `update` (COI-8–9)

## Requirements

- Coil toolchain (`coil` on `PATH`, or set `COIL`) built with `[package]`/`[dependencies]`
  manifest support (coil-lang `feature/coi-3` or later)
- Host `git` and `sh`
- Coil stdlib: default `../coil-lang/stdlib` relative to this repo

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
export COIL=/path/to/coil-lang/target/debug/coil
$COIL test
./spool help
./scripts/smoke_install.sh   # local git fixture → install
```

`install` flow:

1. Coil `plan` — read `coil.lock`, write `.spool/fetch.sh` + `.spool/links.tsv`
2. Bash runs `fetch.sh` (git clone/fetch + worktree)
3. Coil `link` — symlink `.spool/deps/<name>` and ensure roots

Design: Linear project **Git-based package manager** (COI-1 design doc).

## Coil quirks this repo works around

- No forward references within a module file
- `env::exec` / `env::exit` warnings fail in-memory compile; `extern` in imported
  modules panics (`invalid library handle`); `system(3)` breaks after `Vec` alloc
- So git stays in the bash driver; Coil does plan/link only
