use hooks::{
    may_run_hook, hooks_are_off, default_hooks_off, ignore_scripts_flag,
    enable_scripts_flag, hook_kind_script, script_gate_lock,
};
use lock::{
    make_git_pkg, make_lock_script, lock_serialize_all, lock_parse,
    lock_parse_scripts, lock_find_script, lock_script_path, lock_script_hash,
    lock_pkg_hook_path, lock_pkg_hook_hash,
};
use io::file::{write_text};
use io::fs::{exists, create_dir_all};
use text::{contains};

fn deny_contains(Result<int, string> r, string needle) -> Result<int, string> {
    match r {
        Result::Ok(_) => {
            assert(false)?;
        },
        Result::Err(e) => {
            assert(contains(e, needle))?;
        },
    };
    return 0;
}

/// Same as the spool driver: `--ignore-scripts` wins; else `--enable-scripts` sets `0`.
fn ignore_env(bool force_off, bool want_on) -> string {
    if force_off {
        return "1";
    }
    if want_on {
        return "0";
    }
    return "";
}

fn app_lock_scripts(string path, string hash) -> string {
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg("http", "https://x/y.git", "v1.0.0", "rev1", "tree1"));
    let allow: Vec<string> = Vec::new();
    let scripts: Vec<string> = Vec::new();
    scripts.push(make_lock_script("pre_install", path, hash));
    return lock_serialize_all(pkgs, allow, scripts);
}

fn empty_scripts_lock() -> string {
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg("http", "https://x/y.git", "v1.0.0", "rev1", "tree1"));
    let allow: Vec<string> = Vec::new();
    let scripts: Vec<string> = Vec::new();
    return lock_serialize_all(pkgs, allow, scripts);
}

fn script_from_lock(
    bool hooks_off,
    string lock_text,
    string path,
    string actual_hash,
) -> Result<int, string> {
    let scripts = lock_parse_scripts(lock_text)?;
    let rec = lock_find_script(scripts, "pre_install");
    let n = may_run_hook(
        hooks_off,
        hook_kind_script(),
        "app",
        path,
        actual_hash,
        lock_script_path(rec),
        lock_script_hash(rec),
        false,
    )?;
    return n;
}

fn marker_exists(string p) -> bool {
    return match exists(p) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
}

fn ensure_dir(string p) -> Result<int, string> {
    return match create_dir_all(p) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "mkdir failed",
    };
}

/// Marker only. Does not exec. Writes HOOK_RAN when the gate would allow `sh`.
fn mark_if_allowed(string marker, Result<int, string> gated) -> Result<int, string> {
    match gated {
        Result::Ok(_) => {
            match write_text(marker, "pre_install\n") {
                Result::Ok(_) => 0,
                Result::Err(_) => raise "marker write failed",
            };
        },
        Result::Err(e) => {
            raise e;
        },
    };
    return 0;
}

test("default: consumer scripts do not run") {
    ensure_dir("scratch/coi103/default")?;
    let marker = "scratch/coi103/default/HOOK_RAN";
    let lock = app_lock_scripts("./scripts/pre-install.sh", "abc");
    assert(default_hooks_off())?;
    assert(hooks_are_off(ignore_env(false, false)))?;
    deny_contains(
        script_from_lock(
            hooks_are_off(ignore_env(false, false)),
            lock,
            "./scripts/pre-install.sh",
            "abc",
        ),
        "hooks are off",
    )?;
    assert(marker_exists(marker) == false)?;
}

test("--enable-scripts: allowed script may run") {
    ensure_dir("scratch/coi103/enable")?;
    let marker = "scratch/coi103/enable/HOOK_RAN";
    let lock = app_lock_scripts("./scripts/pre-install.sh", "abc");
    assert(enable_scripts_flag("--enable-scripts"))?;
    assert(hooks_are_off(ignore_env(false, true)) == false)?;
    mark_if_allowed(
        marker,
        script_from_lock(
            hooks_are_off(ignore_env(false, true)),
            lock,
            "./scripts/pre-install.sh",
            "abc",
        ),
    )?;
    assert(marker_exists(marker))?;
}

test("--ignore-scripts wins over --enable-scripts") {
    ensure_dir("scratch/coi103/ignore")?;
    let marker = "scratch/coi103/ignore/HOOK_RAN";
    let lock = app_lock_scripts("./scripts/pre-install.sh", "abc");
    assert(ignore_scripts_flag("--ignore-scripts"))?;
    assert(enable_scripts_flag("--enable-scripts"))?;
    assert(hooks_are_off(ignore_env(true, true)))?;
    deny_contains(
        script_from_lock(
            hooks_are_off(ignore_env(true, true)),
            lock,
            "./scripts/pre-install.sh",
            "abc",
        ),
        "hooks are off",
    )?;
    assert(marker_exists(marker) == false)?;
}

test("lock [scripts] hash lives off the package row") {
    let lock = app_lock_scripts("./scripts/pre-install.sh", "abc");
    assert(contains(lock, "[scripts]"))?;
    assert(contains(lock, "pre_install = './scripts/pre-install.sh'"))?;
    assert(contains(lock, "pre_install_hash = 'abc'"))?;
    assert(contains(lock, "name = 'app'") == false)?;
    let pkgs = lock_parse(lock)?;
    assert(len(pkgs) == 1)?;
    assert(lock_pkg_hook_path(pkgs[0]) == "")?;
    assert(lock_pkg_hook_hash(pkgs[0]) == "")?;
    let scripts = lock_parse_scripts(lock)?;
    let rec = lock_find_script(scripts, "pre_install");
    assert(lock_script_path(rec) == "./scripts/pre-install.sh")?;
    assert(lock_script_hash(rec) == "abc")?;
}

test("changed script with a lock pin mismatches and does not sh") {
    ensure_dir("scratch/coi103/mismatch")?;
    let marker = "scratch/coi103/mismatch/HOOK_RAN";
    let lock = app_lock_scripts("./scripts/pre-install.sh", "abc");
    let scripts = lock_parse_scripts(lock)?;
    let rec = lock_find_script(scripts, "pre_install");
    let decided = script_gate_lock(
        lock_script_path(rec),
        lock_script_hash(rec),
        "./scripts/pre-install.sh",
        "changed",
    );
    let (lp, lh, first_pin) = decided;
    assert(first_pin == false)?;
    assert(lh == "abc")?;
    deny_contains(
        may_run_hook(
            false,
            hook_kind_script(),
            "app",
            "./scripts/pre-install.sh",
            "changed",
            lp,
            lh,
            false,
        ),
        "hook hash mismatch",
    )?;
    deny_contains(
        script_from_lock(
            hooks_are_off(ignore_env(false, true)),
            lock,
            "./scripts/pre-install.sh",
            "changed",
        ),
        "hook hash mismatch",
    )?;
    assert(marker_exists(marker) == false)?;
}

test("missing lock pin first-pins then gates; empty hash does not skip the gate") {
    ensure_dir("scratch/coi103/first")?;
    let marker = "scratch/coi103/first/HOOK_RAN";
    let lock = empty_scripts_lock();
    assert(contains(lock, "pre_install_hash") == false)?;
    let scripts = lock_parse_scripts(lock)?;
    let rec = lock_find_script(scripts, "pre_install");
    deny_contains(
        may_run_hook(
            false,
            hook_kind_script(),
            "app",
            "./scripts/pre-install.sh",
            "abc",
            lock_script_path(rec),
            lock_script_hash(rec),
            false,
        ),
        "missing lock hash",
    )?;
    assert(marker_exists(marker) == false)?;
    let decided = script_gate_lock(
        lock_script_path(rec),
        lock_script_hash(rec),
        "./scripts/pre-install.sh",
        "abc",
    );
    let (lp, lh, first_pin) = decided;
    assert(first_pin)?;
    assert(lp == "./scripts/pre-install.sh")?;
    assert(lh == "abc")?;
    mark_if_allowed(
        marker,
        may_run_hook(
            false,
            hook_kind_script(),
            "app",
            "./scripts/pre-install.sh",
            "abc",
            lp,
            lh,
            false,
        ),
    )?;
    assert(marker_exists(marker))?;
}
