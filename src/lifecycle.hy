// Current-project [scripts] and dependency [package].include hooks.
// Hooks are off by default; every `sh` goes through may_run_hook first.
use string::{format};
use util::{join2, path_exists, tsv_field};
use proc::{sh_run};
use git::{hash_object};
use lock::{
    lock_read_scripts_or_empty, lock_write_scripts, lock_find_script, lock_script_path,
    lock_script_hash, lock_upsert_script, make_lock_script, lock_read_allow_or_empty,
    lock_read_or_empty, lock_find, lock_pkg_hook_path, lock_pkg_hook_hash, lock_pkg_with_hook,
    lock_upsert, lock_write,
};
use manifest::{scripts_read, scripts_path_of, package_name_read, package_include_read};
use hooks::{
    may_run_hook, hook_kind_script, hook_kind_include, script_gate_lock, include_gate_lock,
    allow_include_has,
};

/// `sh <rel>` from `dir` with SPOOL_PROJECT set to the consuming project;
/// non-zero exit raises `label exited N`.
fn run_hook_file(string project, string dir, string rel, string label) -> Result<int, string> {
    let a: Vec<string> = Vec::new();
    a.push(dir);
    a.push(rel);
    a.push(project);
    let code = sh_run("cd \"$1\" || exit 125; SPOOL_PROJECT=\"$3\" exec sh \"$2\"", a)?;
    if code != 0 {
        raise format("%s exited %i", label, code);
    }
    return 0;
}

/// Run the project's `[scripts].<slot>` when hooks are on and the lock pin
/// matches (first opted-in run records the pin).
fn run_project_script(string root, string slot, bool hooks_off) -> Result<int, string> {
    if hooks_off {
        return 0;
    }
    let recs = scripts_read(join2(root, "coil.toml"))?;
    let rel = scripts_path_of(recs, slot);
    if len(rel) == 0 {
        return 0;
    }
    let file = join2(root, rel);
    if path_exists(file) == false {
        raise format("missing script %s", rel);
    }
    let hash = hash_object(file)?;
    let pkg = package_name_read(join2(root, "coil.toml"));
    if len(pkg) == 0 {
        pkg = "app";
    }
    let lock_path = join2(root, "coil.lock");
    let scripts = lock_read_scripts_or_empty(lock_path)?;
    let rec = lock_find_script(scripts, slot);
    let decided = script_gate_lock(lock_script_path(rec), lock_script_hash(rec), rel, hash);
    let (lp, lh, first_pin) = decided;
    if first_pin && len(lh) > 0 {
        scripts = lock_upsert_script(scripts, make_lock_script(slot, lp, lh));
        lock_write_scripts(lock_path, scripts)?;
    }
    may_run_hook(false, hook_kind_script(), pkg, rel, hash, lp, lh, false)?;
    return run_hook_file(root, root, rel, rel)?;
}

/// Include-hooks of linked deps (`name \t dir` rows), after link.
/// Dependency [scripts] never run here.
fn run_include_hooks(string root, Vec<string> rows, bool hooks_off) -> Result<int, string> {
    if hooks_off {
        return 0;
    }
    let lock_path = join2(root, "coil.lock");
    let i = 0;
    while i < len(rows) {
        let name = tsv_field(rows[i], 0);
        let dest = tsv_field(rows[i], 1);
        i = i + 1;
        let rel = package_include_read(join2(dest, "coil.toml"))?;
        if len(rel) == 0 {
            continue;
        }
        let file = join2(dest, rel);
        if path_exists(file) == false {
            raise format("missing include-hook %s %s", name, rel);
        }
        let hash = hash_object(file)?;
        let packages = lock_read_or_empty(lock_path)?;
        let allow = lock_read_allow_or_empty(lock_path)?;
        let rec = lock_find(packages, name);
        let decided = include_gate_lock(
            len(rec) > 0,
            lock_pkg_hook_path(rec),
            lock_pkg_hook_hash(rec),
            rel,
            hash,
        );
        let (lp, lh, first_pin) = decided;
        if first_pin && len(lh) > 0 && len(rec) > 0 {
            packages = lock_upsert(packages, lock_pkg_with_hook(rec, lp, lh));
            lock_write(lock_path, packages)?;
        }
        may_run_hook(
            false,
            hook_kind_include(),
            name,
            rel,
            hash,
            lp,
            lh,
            allow_include_has(allow, name),
        )?;
        run_hook_file(root, dest, rel, format("include-hook %s %s", name, rel))?;
    }
    return 0;
}
