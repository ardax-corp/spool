// Project `.spool/deps` symlink farm. `spool build/run/test/check` pass it to
// coil as a `--root`; coil.toml is never edited (coil ignores [module].roots).
//
//   .spool/deps/<name>     -> <checkout>/src   (`use name::module`)
//   .spool/deps/<name>.hy  -> <checkout>/src/<name>.hy when present
//                             (`use name::{Item}` for single-file libraries)
use io::fs::{is_dir, is_symlink, remove_file, symlink, list_dir};
use text::{ends_with, slice};
use string::{format};
use util::{join2, ensure_dir, path_exists, tsv_field, vec_has, check_pkg_name};

fn spool_deps_dir(string project_root) -> string {
    return join2(project_root, ".spool/deps");
}

fn checkout_module_root(string checkout_path) -> string {
    let src = join2(checkout_path, "src");
    if path_exists(src) == false {
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

fn is_link(string p) -> bool {
    return match is_symlink(p) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
}

/// Remove a spool-managed symlink. Anything else in the way is an error.
fn remove_link(string p) -> Result<int, string> {
    if is_link(p) {
        return match remove_file(p) {
            Result::Ok(_) => 0,
            Result::Err(_) => raise format("cannot remove %s", p),
        };
    }
    if path_exists(p) {
        raise format("%s is not a spool link; move it out of the way", p);
    }
    return 0;
}

fn make_link(string target, string link) -> Result<int, string> {
    return match symlink(target, link) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise format("symlink %s -> %s failed", link, target),
    };
}

fn link_dep(string project_root, string name, string checkout_path) -> Result<int, string> {
    check_pkg_name(name)?;
    let deps = spool_deps_dir(project_root);
    ensure_dir(deps)?;
    let target = checkout_module_root(checkout_path);
    let link = join2(deps, name);
    remove_link(link)?;
    make_link(target, link)?;
    let file_link = link + ".hy";
    remove_link(file_link)?;
    let lib_file = join2(target, name + ".hy");
    if path_exists(lib_file) {
        make_link(lib_file, file_link)?;
    }
    return 0;
}

fn strip_hy(string entry) -> string {
    if ends_with(entry, ".hy") && len(entry) > 3 {
        return match slice(entry, 0, len(entry) - 3) {
            Result::Ok(x) => x,
            Result::Err(_) => entry,
        };
    }
    return entry;
}

/// Link every `name \t dir` row and drop links for names no longer present.
fn link_all(string project_root, Vec<string> rows) -> Result<int, string> {
    let names: Vec<string> = Vec::new();
    let i = 0;
    while i < len(rows) {
        names.push(tsv_field(rows[i], 0));
        i = i + 1;
    }
    let deps = spool_deps_dir(project_root);
    ensure_dir(deps)?;
    let entries = match list_dir(deps) {
        Result::Ok(v) => v,
        Result::Err(_) => raise format("cannot list %s", deps),
    };
    i = 0;
    while i < len(entries) {
        let e = entries[i];
        i = i + 1;
        if vec_has(names, strip_hy(e)) == false {
            remove_link(join2(deps, e))?;
        }
    }
    i = 0;
    while i < len(rows) {
        link_dep(project_root, tsv_field(rows[i], 0), tsv_field(rows[i], 1))?;
        i = i + 1;
    }
    return 0;
}
