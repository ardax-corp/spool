use hooks::{
    may_run_hook, hooks_are_off, default_hooks_off, ignore_scripts_flag,
    enable_scripts_flag, hook_kind_include, hook_kind_script, include_gate_lock,
    allow_include_has,
};
use lock::{
    make_git_pkg, make_git_pkg_hook, lock_serialize_full, lock_parse, lock_parse_allow,
    lock_find, lock_pkg_hook_path, lock_pkg_hook_hash, lock_upsert, lock_pkg_with_hook,
    lock_write, lock_read,
};
use manifest::{package_include_parse, scripts_parse, scripts_path_of};
use io::file::{write_text};
use io::fs::{exists, create_dir_all, remove_file};
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

fn http_lock(string path, string hash, bool allowlisted) -> string {
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg_hook(
        "http",
        "https://x/y.git",
        "v1.0.0",
        "rev1",
        "tree1",
        path,
        hash,
    ));
    let allow = Vec::new();
    if allowlisted {
        allow.push("http");
    }
    return lock_serialize_full(pkgs, allow);
}

/// Gate an include-hook from lock fields. First-pin in memory only. Does not exec.
fn include_from_lock(
    bool hooks_off,
    string lock_text,
    string pkg,
    string path,
    string actual_hash,
) -> Result<int, string> {
    let pkgs = lock_parse(lock_text)?;
    let allow = lock_parse_allow(lock_text)?;
    let p = lock_find(pkgs, pkg);
    let decided = include_gate_lock(
        len(p) > 0,
        lock_pkg_hook_path(p),
        lock_pkg_hook_hash(p),
        path,
        actual_hash,
    );
    let (lp, lh, first_pin) = decided;
    if first_pin {
        if len(p) > 0 {
            p = lock_pkg_with_hook(p, lp, lh);
            pkgs = lock_upsert(pkgs, p);
        }
    }
    let n = may_run_hook(
        hooks_off,
        hook_kind_include(),
        pkg,
        path,
        actual_hash,
        lp,
        lh,
        allow_include_has(allow, pkg),
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

fn clear_marker(string p) {
    match remove_file(p) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}

fn write_lock_text(string path, string body) -> Result<int, string> {
    return match write_text(path, body) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "lock write failed",
    };
}

/// Marker only. Does not exec. Writes INCLUDE_RAN when the gate would allow `sh`.
fn mark_if_allowed(string marker, Result<int, string> gated) -> Result<int, string> {
    match gated {
        Result::Ok(_) => {
            match write_text(marker, "include\n") {
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

test("default: include does not run") {
    ensure_dir("scratch/coi104/default")?;
    let marker = "scratch/coi104/default/INCLUDE_RAN";
    clear_marker(marker);
    let lock = http_lock("./hooks/include.sh", "abc", true);
    assert(default_hooks_off())?;
    assert(hooks_are_off(ignore_env(false, false)))?;
    deny_contains(
        include_from_lock(
            hooks_are_off(ignore_env(false, false)),
            lock,
            "http",
            "./hooks/include.sh",
            "abc",
        ),
        "hooks are off",
    )?;
    assert(marker_exists(marker) == false)?;
}

test("allowlisted + matching lock hash: may run") {
    ensure_dir("scratch/coi104/ok")?;
    let marker = "scratch/coi104/ok/INCLUDE_RAN";
    clear_marker(marker);
    let lock = http_lock("./hooks/include.sh", "abc", true);
    assert(enable_scripts_flag("--enable-scripts"))?;
    assert(contains(lock, "allow_include = ['http']"))?;
    mark_if_allowed(
        marker,
        include_from_lock(
            hooks_are_off(ignore_env(false, true)),
            lock,
            "http",
            "./hooks/include.sh",
            "abc",
        ),
    )?;
    assert(marker_exists(marker))?;
}

test("not allowlisted: does not run even if hash matches") {
    ensure_dir("scratch/coi104/noallow")?;
    let marker = "scratch/coi104/noallow/INCLUDE_RAN";
    clear_marker(marker);
    let lock = http_lock("./hooks/include.sh", "abc", false);
    assert(enable_scripts_flag("--enable-scripts"))?;
    deny_contains(
        include_from_lock(
            hooks_are_off(ignore_env(false, true)),
            lock,
            "http",
            "./hooks/include.sh",
            "abc",
        ),
        "not allowlisted",
    )?;
    assert(marker_exists(marker) == false)?;
}

test("no lock row / missing hash: deny, no sh") {
    ensure_dir("scratch/coi104/norow")?;
    let marker = "scratch/coi104/norow/INCLUDE_RAN";
    clear_marker(marker);
    let pkgs = Vec::new();
    let allow = Vec::new();
    allow.push("http");
    let lock = lock_serialize_full(pkgs, allow);
    assert(contains(lock, "allow_include"))?;
    let parsed = lock_parse(lock)?;
    assert(len(parsed) == 0)?;
    let rec = lock_find(parsed, "http");
    assert(len(rec) == 0)?;
    let decided = include_gate_lock(
        len(rec) > 0,
        lock_pkg_hook_path(rec),
        lock_pkg_hook_hash(rec),
        "./hooks/include.sh",
        "abc",
    );
    let (lp, lh, first_pin) = decided;
    assert(first_pin == false)?;
    assert(lp == "")?;
    assert(lh == "")?;
    deny_contains(
        include_from_lock(
            hooks_are_off(ignore_env(false, true)),
            lock,
            "http",
            "./hooks/include.sh",
            "abc",
        ),
        "missing lock hash",
    )?;
    deny_contains(
        may_run_hook(
            false,
            hook_kind_include(),
            "http",
            "./hooks/include.sh",
            "abc",
            lp,
            lh,
            true,
        ),
        "missing lock hash",
    )?;
    assert(marker_exists(marker) == false)?;
}

test("changed include after pin: fail closed, no sh") {
    ensure_dir("scratch/coi104/mismatch")?;
    let marker = "scratch/coi104/mismatch/INCLUDE_RAN";
    clear_marker(marker);
    let lock = http_lock("./hooks/include.sh", "abc", true);
    let pkgs = lock_parse(lock)?;
    let rec = lock_find(pkgs, "http");
    let decided = include_gate_lock(
        true,
        lock_pkg_hook_path(rec),
        lock_pkg_hook_hash(rec),
        "./hooks/include.sh",
        "changed",
    );
    let (lp, lh, first_pin) = decided;
    assert(first_pin == false)?;
    assert(lh == "abc")?;
    deny_contains(
        include_from_lock(
            hooks_are_off(ignore_env(false, true)),
            lock,
            "http",
            "./hooks/include.sh",
            "changed",
        ),
        "hook hash mismatch",
    )?;
    assert(lock_pkg_hook_hash(lock_find(pkgs, "http")) == "abc")?;
    assert(marker_exists(marker) == false)?;
}

test("--ignore-scripts: stays off even if allowlisted") {
    ensure_dir("scratch/coi104/ignore")?;
    let marker = "scratch/coi104/ignore/INCLUDE_RAN";
    clear_marker(marker);
    let lock = http_lock("./hooks/include.sh", "abc", true);
    assert(ignore_scripts_flag("--ignore-scripts"))?;
    assert(enable_scripts_flag("--enable-scripts"))?;
    assert(hooks_are_off(ignore_env(true, true)))?;
    deny_contains(
        include_from_lock(
            hooks_are_off(ignore_env(true, true)),
            lock,
            "http",
            "./hooks/include.sh",
            "abc",
        ),
        "hooks are off",
    )?;
    assert(marker_exists(marker) == false)?;
}

test("first-pin must write a lock row; empty hash without pin is deny") {
    ensure_dir("scratch/coi104/first")?;
    let marker = "scratch/coi104/first/INCLUDE_RAN";
    let lock_path = "scratch/coi104/first/coil.lock";
    clear_marker(marker);
    let lock = http_lock("./hooks/include.sh", "", true);
    write_lock_text(lock_path, lock)?;
    let pkgs = lock_parse(lock)?;
    let rec = lock_find(pkgs, "http");
    deny_contains(
        may_run_hook(
            false,
            hook_kind_include(),
            "http",
            "./hooks/include.sh",
            "abc",
            lock_pkg_hook_path(rec),
            lock_pkg_hook_hash(rec),
            true,
        ),
        "missing lock hash",
    )?;
    assert(marker_exists(marker) == false)?;
    let decided = include_gate_lock(
        true,
        lock_pkg_hook_path(rec),
        lock_pkg_hook_hash(rec),
        "./hooks/include.sh",
        "abc",
    );
    let (lp, lh, first_pin) = decided;
    assert(first_pin)?;
    rec = lock_pkg_with_hook(rec, lp, lh);
    pkgs = lock_upsert(pkgs, rec);
    lock_write(lock_path, pkgs)?;
    let written = lock_read(lock_path)?;
    assert(lock_pkg_hook_path(lock_find(written, "http")) == "./hooks/include.sh")?;
    assert(lock_pkg_hook_hash(lock_find(written, "http")) == "abc")?;
    mark_if_allowed(
        marker,
        may_run_hook(
            false,
            hook_kind_include(),
            "http",
            "./hooks/include.sh",
            "abc",
            lp,
            lh,
            true,
        ),
    )?;
    assert(marker_exists(marker))?;
    pkgs = lock_upsert(
        pkgs,
        make_git_pkg_hook(
            "http",
            "https://x/y.git",
            "v2.0.0",
            "rev2",
            "tree2",
            "./hooks/include.sh",
            "stale",
        ),
    );
    assert(lock_pkg_hook_hash(lock_find(pkgs, "http")) == "abc")?;
}

test("dependency [scripts] are not the include gate") {
    let body = "[package]
name = \"http\"
version = \"1.0.0\"
include = \"./hooks/include.sh\"

[scripts]
pre_install = \"./scripts/pre-install.sh\"
";
    assert(package_include_parse(body) == "./hooks/include.sh")?;
    let recs = scripts_parse(body)?;
    assert(scripts_path_of(recs, "pre_install") == "./scripts/pre-install.sh")?;
    deny_contains(
        may_run_hook(
            false,
            hook_kind_script(),
            "http",
            "./scripts/pre-install.sh",
            "abc",
            "",
            "",
            true,
        ),
        "missing lock hash",
    )?;
}

test("missing include is a no-op") {
    let body = "[package]
name = \"http\"
version = \"1.0.0\"
";
    assert(package_include_parse(body) == "")?;
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg("http", "https://x/y.git", "v1.0.0", "rev1", "tree1"));
    assert(lock_pkg_hook_path(pkgs[0]) == "")?;
    assert(lock_pkg_hook_hash(pkgs[0]) == "")?;
}
