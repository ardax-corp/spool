use hooks::{
    may_run_hook, hooks_are_off, default_hooks_off, ignore_scripts_flag,
    git_identity_trusted, allow_include_has, allow_include_add,
    hook_kind_include, hook_kind_script,
};
use lock::{
    make_git_pkg_hook, lock_serialize_full, lock_parse, lock_parse_allow,
    lock_find, lock_pkg_hook_path, lock_pkg_hook_hash,
};
use manifest::{package_include_parse};
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

/// Gate an include-hook from lock fields only. Does not exec.
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
    let n = may_run_hook(
        hooks_off,
        hook_kind_include(),
        pkg,
        path,
        actual_hash,
        lock_pkg_hook_path(p),
        lock_pkg_hook_hash(p),
        allow_include_has(allow, pkg),
    )?;
    return n;
}

fn http_lock(bool allowlisted) -> string {
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg_hook(
        "http",
        "https://x/y.git",
        "v1.0.0",
        "rev1",
        "tree1",
        "./hooks/include.sh",
        "hookabc",
    ));
    let allow = Vec::new();
    if allowlisted {
        allow.push("http");
    }
    return lock_serialize_full(pkgs, allow);
}

test("default and --ignore-scripts are hooks-off") {
    assert(default_hooks_off())?;
    assert(hooks_are_off(""))?;
    assert(hooks_are_off("1"))?;
    assert(hooks_are_off("--ignore-scripts"))?;
    assert(ignore_scripts_flag("--ignore-scripts"))?;
    assert(ignore_scripts_flag("--hooks") == false)?;
    assert(hooks_are_off("0") == false)?;
}

test("hooks-off denies before allowlist or hash") {
    deny_contains(
        may_run_hook(
            true,
            hook_kind_include(),
            "http",
            "./hooks/include.sh",
            "abc",
            "./hooks/include.sh",
            "abc",
            true,
        ),
        "hooks are off",
    )?;
}

test("missing allowlist denies include-hook") {
    deny_contains(
        may_run_hook(
            false,
            hook_kind_include(),
            "http",
            "./hooks/include.sh",
            "abc",
            "./hooks/include.sh",
            "abc",
            false,
        ),
        "not allowlisted",
    )?;
}

test("missing lock hash denies") {
    deny_contains(
        may_run_hook(
            false,
            hook_kind_include(),
            "http",
            "./hooks/include.sh",
            "abc",
            "",
            "",
            true,
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
            "./hooks/include.sh",
            "",
            true,
        ),
        "missing lock hash",
    )?;
}

test("mismatched lock hash denies") {
    deny_contains(
        may_run_hook(
            false,
            hook_kind_include(),
            "http",
            "./hooks/include.sh",
            "abc",
            "./hooks/include.sh",
            "xyz",
            true,
        ),
        "hook hash mismatch",
    )?;
}

test("mismatched hook path denies") {
    deny_contains(
        may_run_hook(
            false,
            hook_kind_include(),
            "http",
            "./evil.sh",
            "abc",
            "./hooks/include.sh",
            "abc",
            true,
        ),
        "hook path mismatch",
    )?;
}

test("allowlisted matching hash is eligible and does not exec") {
    let n = may_run_hook(
        false,
        hook_kind_include(),
        "http",
        "./hooks/include.sh",
        "abc",
        "./hooks/include.sh",
        "abc",
        true,
    )?;
    assert(n == 0)?;
}

test("unsigned git identity is not a substitute") {
    assert(git_identity_trusted("https://github.com/acme/http.git") == false)?;
    assert(git_identity_trusted("git@github.com:acme/http.git") == false)?;
    deny_contains(
        may_run_hook(
            false,
            hook_kind_include(),
            "http",
            "./hooks/include.sh",
            "abc",
            "",
            "",
            true,
        ),
        "missing lock hash",
    )?;
}

test("consumer scripts skip allowlist but still need a lock hash") {
    deny_contains(
        may_run_hook(
            false,
            hook_kind_script(),
            "app",
            "./scripts/pre_install.sh",
            "abc",
            "",
            "",
            false,
        ),
        "missing lock hash",
    )?;
    let n = may_run_hook(
        false,
        hook_kind_script(),
        "app",
        "./scripts/pre_install.sh",
        "abc",
        "./scripts/pre_install.sh",
        "abc",
        false,
    )?;
    assert(n == 0)?;
}

test("allow_include list is explicit") {
    let names: Vec<string> = Vec::new();
    assert(allow_include_has(names, "http") == false)?;
    names = allow_include_add(names, "http");
    assert(allow_include_has(names, "http"))?;
    names = allow_include_add(names, "http");
    assert(len(names) == 1)?;
}

test("default: include hook not allowed") {
    let lock = http_lock(false);
    assert(contains(lock, "allow_include =") == false)?;
    deny_contains(
        include_from_lock(
            default_hooks_off(),
            lock,
            "http",
            "./hooks/include.sh",
            "hookabc",
        ),
        "hooks are off",
    )?;
    deny_contains(
        include_from_lock(
            hooks_are_off("0"),
            lock,
            "http",
            "./hooks/include.sh",
            "hookabc",
        ),
        "not allowlisted",
    )?;
}

test("after allow-include: may_run_hook only for recorded path and hash") {
    let lock = http_lock(true);
    assert(contains(lock, "allow_include = ['http']"))?;
    assert(contains(lock, "hook_path = './hooks/include.sh'"))?;
    assert(contains(lock, "hook_hash = 'hookabc'"))?;
    let n = include_from_lock(
        hooks_are_off("0"),
        lock,
        "http",
        "./hooks/include.sh",
        "hookabc",
    )?;
    assert(n == 0)?;
    deny_contains(
        include_from_lock(
            hooks_are_off("0"),
            lock,
            "http",
            "./hooks/other.sh",
            "hookabc",
        ),
        "hook path mismatch",
    )?;
    deny_contains(
        include_from_lock(
            hooks_are_off("0"),
            lock,
            "other",
            "./hooks/include.sh",
            "hookabc",
        ),
        "not allowlisted",
    )?;
}

test("--ignore-scripts: false even when allowlisted") {
    let lock = http_lock(true);
    assert(ignore_scripts_flag("--ignore-scripts"))?;
    deny_contains(
        include_from_lock(
            hooks_are_off("1"),
            lock,
            "http",
            "./hooks/include.sh",
            "hookabc",
        ),
        "hooks are off",
    )?;
    deny_contains(
        include_from_lock(
            hooks_are_off("--ignore-scripts"),
            lock,
            "http",
            "./hooks/include.sh",
            "hookabc",
        ),
        "hooks are off",
    )?;
}

test("wrong or missing hook_hash fail closed") {
    let lock = http_lock(true);
    deny_contains(
        include_from_lock(
            hooks_are_off("0"),
            lock,
            "http",
            "./hooks/include.sh",
            "wrong",
        ),
        "hook hash mismatch",
    )?;
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg_hook(
        "http",
        "https://x/y.git",
        "v1.0.0",
        "rev1",
        "tree1",
        "./hooks/include.sh",
        "",
    ));
    let allow = Vec::new();
    allow.push("http");
    let missing = lock_serialize_full(pkgs, allow);
    deny_contains(
        include_from_lock(
            hooks_are_off("0"),
            missing,
            "http",
            "./hooks/include.sh",
            "hookabc",
        ),
        "missing lock hash",
    )?;
}

test("no [hooks] section in coil.toml is required") {
    let toml = "[package]
name = \"app\"
version = \"0.0.1\"

[module]
roots = [\"./src\"]

[dependencies]
http = { git = \"https://x/y.git\", version = \"^1.0\" }
";
    assert(contains(toml, "[hooks]") == false)?;
    assert(package_include_parse(toml) == "")?;
    let stray = "[package]
name = \"app\"
version = \"0.0.1\"

[hooks]
allow_include = [\"http\"]
";
    assert(package_include_parse(stray) == "")?;
    let lock = http_lock(true);
    let n = include_from_lock(
        hooks_are_off("0"),
        lock,
        "http",
        "./hooks/include.sh",
        "hookabc",
    )?;
    assert(n == 0)?;
}
