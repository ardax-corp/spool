use hooks::{
    may_run_hook, hooks_are_off, default_hooks_off, ignore_scripts_flag,
    git_identity_trusted, allow_include_has, allow_include_add,
    hook_kind_include, hook_kind_script,
};
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
