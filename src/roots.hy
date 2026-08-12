// Manage project .spool/deps symlink farm and [module].roots.
use io::fs::{exists, is_dir, remove_file, symlink};
use io::file::{read_text, write_text};
use text::{trim, starts_with, ends_with, split, contains, join as text_join};
use string::{format};
use util::{join2, ensure_dir};

fn spool_deps_dir(string project_root) -> string {
    return join2(project_root, ".spool/deps");
}

fn insert_into_roots_line(string line) -> Result<string, string> {
    if contains(line, "]") == false {
        raise "malformed roots line";
    }
    let parts = match split(line, "]") {
        Result::Ok(p) => p,
        Result::Err(_) => raise "split roots failed",
    };
    if len(parts) < 1 {
        raise "malformed roots line";
    }
    let head = parts[0];
    if ends_with(head, "[") {
        return "roots = [\"./.spool/deps\"]";
    }
    return head + ", \"./.spool/deps\"]";
}

fn inject_spool_root(string body) -> Result<string, string> {
    let lines = match split(body, "\n") {
        Result::Ok(ls) => ls,
        Result::Err(_) => raise "split failed",
    };
    let out: Vec<string> = Vec::new();
    let i = 0;
    let done = false;
    while i < len(lines) {
        let line = lines[i];
        i = i + 1;
        let trimmed = match trim(line) {
            Result::Ok(t) => t,
            Result::Err(_) => line,
        };
        if done == false {
            if starts_with(trimmed, "roots") {
                if contains(trimmed, "[") {
                    if contains(trimmed, "]") {
                        let inserted = insert_into_roots_line(trimmed)?;
                        out.push(inserted);
                        done = true;
                        continue;
                    }
                }
            }
        }
        out.push(line);
    }
    if done == false {
        out.push("");
        out.push("[module]");
        out.push("roots = [\"./src\", \"./.spool/deps\"]");
    }
    return text_join(out, "\n");
}

// Coil resolves `use greet::hello` as `<root>/greet/hello.hy`. Packages keep
// sources under `src/`, so the dep symlink points at that directory when present.
fn checkout_module_root(string checkout_path) -> string {
    let src = join2(checkout_path, "src");
    let present = match exists(src) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        return checkout_path;
    }
    match is_dir(src) {
        Result::Ok(d) => {
            if d {
                return src;
            }
        },
        Result::Err(_) => {},
    };
    return checkout_path;
}

fn link_dep(string project_root, string name, string checkout_path) -> Result<int, string> {
    let deps = spool_deps_dir(project_root);
    ensure_dir(join2(project_root, ".spool"))?;
    ensure_dir(deps)?;
    let link = join2(deps, name);
    let present = match exists(link) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present {
        match remove_file(link) {
            Result::Ok(_) => 0,
            Result::Err(_) => 0,
        };
    }
    let target = checkout_module_root(checkout_path);
    return match symlink(target, link) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("symlink %s -> %s failed", link, target),
    };
}

fn ensure_roots_entry(string project_root) -> Result<int, string> {
    let path = join2(project_root, "coil.toml");
    let present = match exists(path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        raise "coil.toml not found";
    }
    let body = match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => raise "read coil.toml failed",
    };
    if contains(body, ".spool/deps") {
        return 0;
    }
    let updated = inject_spool_root(body)?;
    return match write_text(path, updated) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write coil.toml failed",
    };
}
