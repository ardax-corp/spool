// `[permissions]` keys become `--allow-*` flags; `exec` grants running
// programs with the built-in `process` module (coil-lang#2141).
use tests::assert;
use toolchain::{grant_flags};
use util::{join2, ensure_dir};
use env::cwd;
use io::file::write_text;
use text::{Joined, Searchable};

fn project(string tag, string toml) -> Result<string, string> {
    let here = match cwd() {
        Result::Ok(d) => d,
        Result::Err(_) => raise "no cwd",
    };
    let proj = join2(here, "scratch/" + tag);
    ensure_dir(join2(proj, "src"))?;
    match write_text(join2(proj, "coil.toml"), toml) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "cannot write coil.toml",
    };
    return proj;
}

test("[permissions] exec is --allow-exec") {
    let proj = project(
        "perm_exec",
        "[package]\nname = \"p\"\nversion = \"0.0.1\"\n\n[permissions]\nread = true\nexec = true\n",
    )?;
    let flags = (grant_flags(proj)?).join(" ");
    assert!(flags.contains("--allow-read"));
    assert!(flags.contains("--allow-exec"));
}

test("exec left out is denied") {
    let proj = project(
        "perm_no_exec",
        "[package]\nname = \"p\"\nversion = \"0.0.1\"\n\n[permissions]\nread = true\n",
    )?;
    assert!((grant_flags(proj)?).join(" ").contains("--allow-exec") == false);
}
