// Shared git cache bookkeeping: which projects use it, and `spool cache gc`.
//
//   <cache>/git/projects/<git hash of the root>   one file per project, holding
//                                                 its absolute root
//
// Every install and every compiling command records its project. gc keeps
// each checkout and bare clone some recorded project's coil.lock names, drops
// the records of projects whose coil.lock is gone, and removes the rest. A
// project spool has not run in since it started recording is not known: its
// checkouts may go, and `spool install` there fetches them again.
use term::eprintln;
use io::fs::{list_dir, remove_file, remove_dir_all};
use string::format;
use text::{Searchable};
use util::{join2, join3, path_exists, read_or_empty, trim_or, lines_of, vec_has, tsv_field};
use proc::{sh_run, sh_capture};
use config::cache_root;
use lock::{lock_read_or_empty, lock_pkg_git, lock_pkg_hash};
use git::bare_dir;
use toolchain::env_or;

fn projects_dir() -> Result<string, string> {
    return join3(cache_root()?, "git", "projects");
}

/// Record `root` as a user of the cache. Best effort: a failure here never
/// fails the command that called it.
fn register_project(string root) {
    let dir = match projects_dir() {
        Result::Ok(d) => d,
        Result::Err(_) => {
            return;
        },
    };
    let a: Vec<string> = Vec::new();
    a.push(dir);
    a.push(root);
    let script = "mkdir -p \"$1\" 2>/dev/null || exit 0; " +
                 "k=$(printf %s \"$2\" | git hash-object --stdin 2>/dev/null) || exit 0; " +
                 "f=\"$1/$k\"; [ \"$(cat \"$f\" 2>/dev/null)\" = \"$2\" ] && exit 0; " +
                 "printf '%s\\n' \"$2\" > \"$f.$$\" && mv -f \"$f.$$\" \"$f\"; exit 0";
    match sh_run(script, a) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}

/// Minutes a new checkout or clone is safe from gc, so an install that has
/// fetched but not yet written its coil.lock keeps what it fetched.
fn grace_minutes() -> string {
    return env_or("SPOOL_CACHE_GC_GRACE_MIN", "60");
}

/// `c <path>` for every checkout and `b <path>` for every bare clone older
/// than the grace period. A clone whose lock is held is skipped.
fn gc_candidates(string git_dir) -> Result<Vec<string>, string> {
    let a: Vec<string> = Vec::new();
    a.push(git_dir);
    a.push(grace_minutes());
    let script = "cd \"$1\" 2>/dev/null || exit 0; " +
                 "young() { [ \"$2\" -gt 0 ] && [ -n \"$(find \"$1\" -maxdepth 0 -mmin -\"$2\" 2>/dev/null)\" ]; }; " +
                 "for d in checkouts/*; do [ -d \"$d\" ] || continue; young \"$d\" \"$2\" && continue; printf 'c\\t%s\\n' \"$d\"; done; " +
                 "find . -mindepth 3 -maxdepth 3 -type d ! -path './checkouts/*' ! -path './projects/*' | " +
                 "while IFS= read -r d; do d=\"${d#./}\"; [ -f \"$d/HEAD\" ] || continue; [ -e \"$d.lock\" ] && continue; " +
                 "young \"$d\" \"$2\" && continue; printf 'b\\t%s\\n' \"$d\"; done";
    let res = sh_capture(script, a)?;
    let (code, body) = res;
    if code != 0 {
        raise format("cannot list %s", git_dir);
    }
    return lines_of(body);
}

/// The last path segment.
fn base_name(string p) -> string {
    let parts = p.split("/");
    return parts[parts.len() - 1];
}

fn say(string msg) {
    eprintln("spool: " + msg);
}

/// `spool cache gc [--dry-run]`.
fn cache_gc(bool dry) -> Result<int, string> {
    let git_dir = join2(cache_root()?, "git");
    let pdir = projects_dir()?;
    let trees: Vec<string> = Vec::new();
    let bares: Vec<string> = Vec::new();
    let forget: Vec<string> = Vec::new();
    let records: Vec<string> = Vec::new();
    if path_exists(pdir) {
        records = match list_dir(pdir) {
            Result::Ok(v) => v,
            Result::Err(_) => raise format("cannot list %s", pdir),
        };
    }
    let i = 0;
    while i < records.len() {
        let rec = join2(pdir, records[i]);
        i = i + 1;
        if records[i - 1].contains(".") {
            continue;
        }
        let root = trim_or(read_or_empty(rec));
        let lock = join2(root, "coil.lock");
        if root.len() == 0 || path_exists(lock) == false {
            forget.push(rec);
            continue;
        }
        let pkgs = match lock_read_or_empty(lock) {
            Result::Ok(p) => p,
            Result::Err(e) => raise format("cannot read %s (%s); fix it, or delete %s to forget the project", lock, e, rec),
        };
        let k = 0;
        while k < pkgs.len() {
            trees.push(lock_pkg_hash(pkgs[k]));
            bares.push(bare_dir(lock_pkg_git(pkgs[k]))?);
            k = k + 1;
        }
    }
    let verb = "removed";
    if dry {
        verb = "would remove";
    }
    let checkouts = 0;
    let clones = 0;
    let candidates = gc_candidates(git_dir)?;
    i = 0;
    while i < candidates.len() {
        let row = candidates[i];
        i = i + 1;
        let kind = tsv_field(row, 0);
        let rel = tsv_field(row, 1);
        let path = join2(git_dir, rel);
        if kind == "c" {
            if vec_has(trees, base_name(rel)) {
                continue;
            }
            say(format("%s checkout %s", verb, base_name(rel)));
            checkouts = checkouts + 1;
        } else {
            if vec_has(bares, path) {
                continue;
            }
            say(format("%s clone %s", verb, rel));
            clones = clones + 1;
        }
        if dry {
            continue;
        }
        if kind == "c" {
            match remove_dir_all(path) {
                Result::Ok(_) => 0,
                Result::Err(_) => raise format("cannot remove %s", path),
            };
        } else {
            // Take the clone's lock so no install is using it meanwhile.
            let a: Vec<string> = Vec::new();
            a.push(path);
            sh_run("mkdir \"$1.lock\" 2>/dev/null || exit 0; rm -rf \"$1\"; rmdir \"$1.lock\"", a)?;
        }
    }
    i = 0;
    while i < forget.len() {
        say(format("%s record of %s (no coil.lock)", verb, trim_or(read_or_empty(forget[i]))));
        if dry == false {
            match remove_file(forget[i]) {
                Result::Ok(_) => 0,
                Result::Err(_) => 0,
            };
        }
        i = i + 1;
    }
    if dry == false && checkouts > 0 {
        // Drop the removed checkouts from their clones' worktree lists.
        let a: Vec<string> = Vec::new();
        a.push(git_dir);
        sh_run("cd \"$1\" 2>/dev/null || exit 0; find . -mindepth 3 -maxdepth 3 -type d ! -path './checkouts/*' ! -path './projects/*' | " +
               "while IFS= read -r d; do [ -f \"$d/HEAD\" ] && git -C \"$d\" worktree prune 2>/dev/null; done; exit 0", a)?;
    }
    if checkouts + clones + forget.len() == 0 {
        say("cache gc: nothing to remove");
        return 0;
    }
    say(format("cache gc: %s %i checkouts and %i clones; %i projects forgotten", verb, checkouts, clones, forget.len()));
    return 0;
}
