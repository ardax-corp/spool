// Fail-closed hook trust (COI-227). 103/104 must call may_run_hook before any sh.
// allow_exec is not a parameter and is not a gate.
use string::{format};

fn hook_kind_include() -> string {
    return "include";
}

fn hook_kind_script() -> string {
    return "script";
}

fn default_hooks_off() -> bool {
    return true;
}

/// `--ignore-scripts` and empty/default are off. Only an explicit "0" opts in
/// to eligibility checks; 103/104 still must pass allowlist + lock hash.
fn hooks_are_off(string ignore_scripts) -> bool {
    if ignore_scripts == "0" {
        return false;
    }
    if ignore_scripts == "false" {
        return false;
    }
    return true;
}

fn ignore_scripts_flag(string arg) -> bool {
    return arg == "--ignore-scripts";
}

/// Unsigned git remotes are never a trust signal. Missing lock hash stays deny.
fn git_identity_trusted(string url) -> bool {
    if len(url) == 0 {
        return false;
    }
    return false;
}

fn allow_include_has(Vec<string> names, string pkg) -> bool {
    let i = 0;
    while i < len(names) {
        if names[i] == pkg {
            return true;
        }
        i = i + 1;
    }
    return false;
}

fn allow_include_add(Vec<string> names, string pkg) -> Vec<string> {
    if allow_include_has(names, pkg) {
        return names;
    }
    names.push(pkg);
    return names;
}

fn may_run_hook(
    bool hooks_off,
    string kind,
    string pkg,
    string path,
    string actual_hash,
    string lock_path,
    string lock_hash,
    bool allowlisted,
) -> Result<int, string> {
    if kind != "include" {
        if kind != "script" {
            raise format("unknown hook kind %s", kind);
        }
    }
    if hooks_off {
        raise "hooks are off (--ignore-scripts)";
    }
    if kind == "include" {
        if allowlisted == false {
            raise "include-hook for " + pkg + " is not allowlisted";
        }
    }
    if len(lock_path) == 0 {
        raise "untrusted hook: missing lock hash for " + pkg;
    }
    if len(lock_hash) == 0 {
        raise "untrusted hook: missing lock hash for " + pkg;
    }
    if path != lock_path {
        raise "hook path mismatch for " + pkg;
    }
    if actual_hash != lock_hash {
        raise "hook hash mismatch for " + pkg;
    }
    return 0;
}
