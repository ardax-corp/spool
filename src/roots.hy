// Project `.spool/deps` symlink farm. `spool build/run/test/check` pass it to
// coil as a `--root`, plus each package's module root (dep_module_roots);
// coil.toml is never edited (coil reads no coil.toml).
//
//   .spool/deps/<name>     -> <checkout>/src   (`use name::module`; its
//                             real path is a root too, for `use name::sub`
//                             from src/<name>/sub.hy and sibling modules)
//   .spool/deps/<name>.hy  -> <checkout>/src/<name>.hy when present
//                             (`use name::{Item}` for single-file libraries)
//
// dep_checkouts maps the links back to each checkout, whose own coil.toml
// `[ffi]` paths resolve against it (spool#38).
use io::fs::{is_dir, is_symlink, remove_file, symlink, list_dir, realpath};
use collections::sort;
use text::{ends_with, slice};
use string::format;
use util::{join2, ensure_dir, path_exists, path_dirname, tsv_field, vec_has, check_pkg_name};

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
    }
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
    if ends_with(entry, ".hy") && entry.len() > 3 {
        return match slice(entry, 0, entry.len() - 3) {
            Result::Ok(x) => x,
            Result::Err(_) => entry,
        };
    }
    return entry;
}

/// The real path of every `.spool/deps/<name>` directory link, sorted: each
/// package's own module root (<checkout>/src), so it resolves its modules for
/// the consumer the way it does in its own repo (`use tls::client` ->
/// src/tls/client.hy, coil-sdl's `use simd` -> src/simd.hy).
///
/// The real path, not the link: coil names a module after the innermost root
/// holding its path, so `.spool/deps/greet` as a root would rename
/// `.spool/deps/greet/hello.hy` from `greet::hello` to `hello`. The `<name>.hy`
/// file links are modules, not roots.
fn dep_module_roots(string project_root) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let deps = spool_deps_dir(project_root);
    if path_exists(deps) == false {
        return out;
    }
    let entries = match list_dir(deps) {
        Result::Ok(v) => sort(v),
        Result::Err(_) => out,
    };
    let i = 0;
    while i < entries.len() {
        let p = join2(deps, entries[i]);
        i = i + 1;
        if ends_with(p, ".hy") || is_link(p) == false {
            continue;
        }
        let dir = match is_dir(p) {
            Result::Ok(d) => d,
            Result::Err(_) => false,
        };
        if dir == false {
            continue;
        }
        match realpath(p) {
            Result::Ok(r) => {
                out.push(r);
            },
            Result::Err(_) => {},
        }
    }
    return out;
}

/// The checkout behind a link target: `<checkout>/src` maps back to
/// `<checkout>` (link_dep links a checkout's src/ when it has one), anything
/// else is the checkout itself.
fn checkout_of_target(string target) -> string {
    if ends_with(target, "/src") && path_exists(join2(target, "coil.toml")) == false {
        let parent = path_dirname(target);
        if path_exists(join2(parent, "coil.toml")) {
            return parent;
        }
    }
    return target;
}

/// `name \t checkout` for every `.spool/deps/<name>` directory link, sorted
/// by name: where each linked package's own coil.toml and native/ live
/// (spool#38). Same links as dep_module_roots.
fn dep_checkouts(string project_root) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let deps = spool_deps_dir(project_root);
    if path_exists(deps) == false {
        return out;
    }
    let entries = match list_dir(deps) {
        Result::Ok(v) => sort(v),
        Result::Err(_) => out,
    };
    let i = 0;
    while i < entries.len() {
        let name = entries[i];
        let p = join2(deps, name);
        i = i + 1;
        if ends_with(p, ".hy") || is_link(p) == false {
            continue;
        }
        let dir = match is_dir(p) {
            Result::Ok(d) => d,
            Result::Err(_) => false,
        };
        if dir == false {
            continue;
        }
        match realpath(p) {
            Result::Ok(r) => {
                out.push(name + "\t" + checkout_of_target(r));
            },
            Result::Err(_) => {},
        }
    }
    return out;
}

/// Link every `name \t dir` row and drop links for names no longer present.
fn link_all(string project_root, Vec<string> rows) -> Result<int, string> {
    let names: Vec<string> = Vec::new();
    let i = 0;
    while i < rows.len() {
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
    while i < entries.len() {
        let e = entries[i];
        i = i + 1;
        if vec_has(names, strip_hy(e)) == false {
            remove_link(join2(deps, e))?;
        }
    }
    i = 0;
    while i < rows.len() {
        link_dep(project_root, tsv_field(rows[i], 0), tsv_field(rows[i], 1))?;
        i = i + 1;
    }
    return 0;
}
