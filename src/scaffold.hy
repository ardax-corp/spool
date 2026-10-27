// `spool new` / `spool init`: project skeletons.
use io::file::{write_text, read_text};
use string::{format};
use text::{Searchable};
use util::{join2, ensure_dir, path_exists, check_pkg_name};
use proc::{run_in};
use toolchain::env_or;

fn write_new(string path, string body) -> Result<int, string> {
    if path_exists(path) {
        return 0;
    }
    return match write_text(path, body) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("failed to write %s", path),
    };
}

/// Where new projects take the stdlib from (`COIL_STDLIB_REPO` overrides).
fn stdlib_repo() -> string {
    return env_or("COIL_STDLIB_REPO", "https://github.com/ardax-corp/coil-stdlib.git");
}

/// The stdlib is an ordinary dependency (there is no global one). New
/// projects follow its tip (`latest`, locked to a commit in coil.lock) until
/// they pin a version; see latest_stdlib_advice.
fn manifest_template(string name, bool lib, string stdlib_git) -> string {
    let body = "[package]\nname = \"" + name + "\"\nversion = \"0.1.0\"\n\n[module]\nroots = [\"./src\"]\n";
    if lib == false {
        body = body + "\n[entry]\nfile = \"src/main.hy\"\n";
    }
    body = body + "\n[dependencies]\n# Follows coil-stdlib's tip (edge). Pin it: version = \"...\" or rev = \"<commit>\".\n" +
           "stdlib = { git = \"" + stdlib_git + "\", version = \"latest\" }\n";
    return body;
}

/// For a project with no stdlib dependency (there is no global stdlib).
fn no_stdlib_hint() -> string {
    return "no stdlib: declare it under [dependencies], e.g. `spool add stdlib --git " + stdlib_repo() + " --rev <commit>`, then `spool install`";
}

/// Printed whenever a project's stdlib follows the tip.
fn latest_stdlib_advice() -> string {
    return "warning: the stdlib dependency follows coil-stdlib's tip (version = \"latest\"); `spool update` can pull in breaking changes. Pin it as soon as you can: version = \"<range>\" or rev = \"<commit>\" (coil.lock has the commit in use)";
}

fn main_template(string name) -> string {
    return "use io::sync::{println};\n\nfn main() {\n    println(\"hello from " + name + "\")?;\n}\n";
}

fn lib_template() -> string {
    return "// Consumers write `use <package>::{hello};`.\nfn hello(string who) -> string {\n    return \"hello, \" + who;\n}\n";
}

fn lib_test_template(string name) -> string {
    return "use " + name + "::{hello};\nuse tests::assert;\n\ntest(\"hello greets\") {\n    assert!(hello(\"coil\") == \"hello, coil\");\n}\n";
}

fn bin_test_template() -> string {
    return "use tests::assert;\n\ntest(\"arithmetic still works\") {\n    assert!(1 + 1 == 2);\n}\n";
}

fn ensure_gitignore(string dir) -> Result<int, string> {
    let path = join2(dir, ".gitignore");
    let body = "";
    if path_exists(path) {
        body = match read_text(path) {
            Result::Ok(s) => s,
            Result::Err(_) => "",
        };
    }
    let add = "";
    if body.contains("/target/") == false {
        add = add + "/target/\n";
    }
    if body.contains("/.spool/") == false {
        add = add + "/.spool/\n";
    }
    if add.len() == 0 {
        return 0;
    }
    if body.len() > 0 && body.ends_with("\n") == false {
        body = body + "\n";
    }
    return match write_text(path, body + add) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("failed to write %s", path),
    };
}

/// Module names are identifiers: letters, digits, `_`.
fn check_module_name(string name) -> Result<int, string> {
    check_pkg_name(name)?;
    if name.contains("-") {
        raise format("`%s` is not usable in `use` paths; use `_` instead of `-`", name);
    }
    return 0;
}

/// Lay out a project in `dir` (which may already exist, for `init`).
fn scaffold(string dir, string name, bool lib, bool vcs) -> Result<int, string> {
    check_module_name(name)?;
    let manifest = join2(dir, "coil.toml");
    if path_exists(manifest) {
        raise format("%s already exists", manifest);
    }
    ensure_dir(join2(dir, "src"))?;
    ensure_dir(join2(dir, "tests"))?;
    match write_text(manifest, manifest_template(name, lib, stdlib_repo())) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("failed to write %s", manifest),
    };
    if lib {
        write_new(join2(dir, "src/" + name + ".hy"), lib_template())?;
        write_new(join2(dir, "tests/" + name + ".hy"), lib_test_template(name))?;
    } else {
        write_new(join2(dir, "src/main.hy"), main_template(name))?;
        write_new(join2(dir, "tests/main.hy"), bin_test_template())?;
    }
    ensure_gitignore(dir)?;
    if vcs && path_exists(join2(dir, ".git")) == false {
        let a: Vec<string> = Vec::new();
        a.push("-c");
        a.push("git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init -q");
        run_in(dir, "sh", a)?;
    }
    return 0;
}
