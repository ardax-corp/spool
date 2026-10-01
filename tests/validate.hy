use util::{valid_pkg_name, valid_git_url};
use cli::{parse_args, opt, has, positionals, raw_args, strs, strs2};

test("package names are plain identifiers") {
    assert(valid_pkg_name("greet"))?;
    assert(valid_pkg_name("my_lib-2"))?;
    assert(valid_pkg_name("") == false)?;
    assert(valid_pkg_name("../evil") == false)?;
    assert(valid_pkg_name("/etc/passwd") == false)?;
    assert(valid_pkg_name("-flag") == false)?;
    assert(valid_pkg_name("a b") == false)?;
    assert(valid_pkg_name("2fast") == false)?;
}

test("git urls: known transports only") {
    assert(valid_git_url("https://github.com/a/b.git"))?;
    assert(valid_git_url("git@github.com:a/b.git"))?;
    assert(valid_git_url("ssh://git@host/a/b"))?;
    assert(valid_git_url("file:///tmp/a/b/c"))?;
    assert(valid_git_url("ext::sh -c touch% /tmp/x") == false)?;
    assert(valid_git_url("--upload-pack=evil") == false)?;
    assert(valid_git_url("https://x/a b") == false)?;
}

test("parse_args splits options, flags, positionals and raw args") {
    let a: Vec<string> = Vec::new();
    a.push("mid");
    a.push("--git");
    a.push("https://x/a/b");
    a.push("--version=^1");
    a.push("--enable-scripts");
    a.push("--");
    a.push("--not-a-flag");
    let p = parse_args(a, strs2("--git", "--version"), strs("--enable-scripts"))?;
    assert(opt(p, "--git") == "https://x/a/b")?;
    assert(opt(p, "--version") == "^1")?;
    assert(has(p, "--enable-scripts"))?;
    assert(len(positionals(p)) == 1)?;
    assert(raw_args(p)[0] == "--not-a-flag")?;
}

test("parse_args rejects unknown flags and missing values") {
    let a = strs("--bogus");
    let r = parse_args(a, strs("--git"), strs("--lib"));
    let failed = match r {
        Result::Ok(_) => false,
        Result::Err(_) => true,
    };
    assert(failed)?;
    let b = strs("--git");
    let r2 = parse_args(b, strs("--git"), strs("--lib"));
    let failed2 = match r2 {
        Result::Ok(_) => false,
        Result::Err(_) => true,
    };
    assert(failed2)?;
}
