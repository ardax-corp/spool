// install / add / update / remove share one pipeline:
//   engine check → pre script → fetch locked checkouts (verify tree ids)
//   → resolve (or --locked check) → prune → write lock → engine check
//   → link .spool/deps → include-hooks → post script.
use term::{eprintln};
use io::file::{read_text, write_text};
use io::fs::{remove_file, remove_dir_all};
use string::{format};
use text::{join as text_join};
use util::{join2, path_exists, tsv_field, vec_has};
use lock::{
    lock_read_or_empty, lock_write, lock_serialize, lock_pkg_name, lock_pkg_git, lock_pkg_rev,
    lock_pkg_hash,
};
use manifest::{deps_read};
use resolve::{
    collect, resolve_all, reachable_names, prune, link_rows, check_engine_all,
};
use roots::{link_all};
use lifecycle::{run_project_script, run_include_hooks};
use git::{ensure_checkout, tree_of};
use engine::{parse_coil_version_output};
use toolchain::{find_coil, coil_version_output};

fn running_coil_version() -> string {
    let coil = find_coil();
    if len(coil) == 0 {
        return "";
    }
    return match parse_coil_version_output(coil_version_output(coil)) {
        Result::Ok(v) => v,
        Result::Err(_) => "",
    };
}

/// Check out every locked package and verify its tree id.
fn fetch_locked(Vec<string> packages) -> Result<int, string> {
    let i = 0;
    while i < len(packages) {
        let p = packages[i];
        i = i + 1;
        let dest = ensure_checkout(lock_pkg_git(p), lock_pkg_rev(p), lock_pkg_hash(p))?;
        let actual = tree_of(dest);
        if actual != lock_pkg_hash(p) {
            // The dir is keyed by the expected tree id; never keep wrong content there.
            match remove_dir_all(dest) {
                Result::Ok(_) => 0,
                Result::Err(_) => 0,
            };
            raise format(
                "integrity mismatch for %s: expected %s, got %s",
                lock_pkg_name(p),
                lock_pkg_hash(p),
                actual,
            );
        }
    }
    return 0;
}

fn todo_names(Vec<string> todo) -> string {
    let names: Vec<string> = Vec::new();
    let i = 0;
    while i < len(todo) {
        names.push(tsv_field(todo[i], 0));
        i = i + 1;
    }
    return text_join(names, ", ");
}

fn dropped_names(Vec<string> before, Vec<string> after) -> string {
    let keep: Vec<string> = Vec::new();
    let i = 0;
    while i < len(after) {
        keep.push(lock_pkg_name(after[i]));
        i = i + 1;
    }
    let gone: Vec<string> = Vec::new();
    i = 0;
    while i < len(before) {
        let n = lock_pkg_name(before[i]);
        if vec_has(keep, n) == false {
            gone.push(n);
        }
        i = i + 1;
    }
    return text_join(gone, ", ");
}

/// Run the shared pipeline. `force` names are re-resolved (update).
fn sync(
    string root,
    bool locked,
    Vec<string> force,
    bool hooks_off,
    string pre_slot,
    string post_slot,
) -> Result<int, string> {
    let toml = join2(root, "coil.toml");
    if path_exists(toml) == false {
        raise "coil.toml not found";
    }
    deps_read(toml)?;
    let lock_path = join2(root, "coil.lock");
    let had_lock = path_exists(lock_path);
    let before = lock_read_or_empty(lock_path)?;
    let running = running_coil_version();

    check_engine_all(root, before, running)?;
    run_project_script(root, pre_slot, hooks_off)?;
    fetch_locked(before)?;

    let packages = before;
    if locked {
        let empty: Vec<string> = Vec::new();
        let res = collect(root, before, empty)?;
        let (cons, todo) = res;
        if len(todo) > 0 {
            raise format(
                "coil.lock is out of date (needs %s); run without --locked to update it",
                todo_names(todo),
            );
        }
    } else {
        packages = resolve_all(root, before, force)?;
    }

    let keep = reachable_names(root, packages)?;
    let pruned = prune(packages, keep);
    if len(pruned) != len(packages) {
        if locked {
            raise format(
                "coil.lock has unused packages (%s); run without --locked to prune them",
                dropped_names(packages, pruned),
            );
        }
        eprintln(format("spool: pruned %s", dropped_names(packages, pruned)));
    }
    let changed = lock_serialize(pruned) != lock_serialize(before);
    if changed && (had_lock || len(pruned) > 0) {
        lock_write(lock_path, pruned)?;
    }

    check_engine_all(root, pruned, running)?;
    let rows = link_rows(root, pruned)?;
    link_all(root, rows)?;
    run_include_hooks(root, rows, hooks_off)?;
    run_project_script(root, post_slot, hooks_off)?;
    return 0;
}

/// Snapshot of coil.toml / coil.lock so add/remove can roll back on failure.
fn snapshot(string root) -> (string, string, bool) {
    let toml = match read_text(join2(root, "coil.toml")) {
        Result::Ok(s) => s,
        Result::Err(_) => "",
    };
    let lock_path = join2(root, "coil.lock");
    let had = path_exists(lock_path);
    let lock_body = "";
    if had {
        lock_body = match read_text(lock_path) {
            Result::Ok(s) => s,
            Result::Err(_) => "",
        };
    }
    return (toml, lock_body, had);
}

fn restore(string root, string toml, string lock_body, bool had_lock) {
    match write_text(join2(root, "coil.toml"), toml) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
    let lock_path = join2(root, "coil.lock");
    if had_lock {
        match write_text(lock_path, lock_body) {
            Result::Ok(_) => 0,
            Result::Err(_) => 0,
        };
    } else {
        match remove_file(lock_path) {
            Result::Ok(_) => 0,
            Result::Err(_) => 0,
        };
    }
}
