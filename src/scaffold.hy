// `spool new` / `spool init`: project skeletons.
use io::file::{write_text, read_text};
use string::{format};
use text::{contains, ends_with};
use util::{join2, ensure_dir, path_exists, check_pkg_name};
use proc::{run_in};

fn write_new(string path, string body) -> Result<int, string> {
    if path_exists(path) {
        return 0;
    }
    return match write_text(path, body) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("failed to write %s", path),
    };
}

fn manifest_template(string name, bool lib) -> string {
    let body = "[package]\nname = \"" + name + "\"\nversion = \"0.1.0\"\n\n[module]\nroots = [\"./src\"]\n";
    if lib == false {
        body = body + "\n[entry]\nfile = \"src/main.hy\"\n";
    }
    return body;
}

fn main_template(string name) -> string {
    return "use io::sync::{println};\n\nfn main() {\n    match println(\"hello from " + name + "\") {\n        Result::Ok(_) => 0,\n        Result::Err(_) => 0,\n    };\n}\n";
}

fn lib_template() -> string {
    return "// Consumers write `use <package>::{hello};`.\nfn hello(string who) -> string {\n    return \"hello, \" + who;\n}\n";
}

fn lib_test_template(string name) -> string {
    return "use " + name + "::{hello};\n\ntest(\"hello greets\") {\n    assert(hello(\"coil\") == \"hello, coil\")?;\n}\n";
}

fn bin_test_template() -> string {
    return "test(\"arithmetic still works\") {\n    assert(1 + 1 == 2)?;\n}\n";
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
    if contains(body, "/target/") == false {
        add = add + "/target/\n";
    }
    if contains(body, "/.spool/") == false {
        add = add + "/.spool/\n";
    }
    if len(add) == 0 {
        return 0;
    }
    if len(body) > 0 && ends_with(body, "\n") == false {
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
    if contains(name, "-") {
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
    match write_text(manifest, manifest_template(name, lib)) {
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
