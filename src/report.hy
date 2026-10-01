// `spool tree` and `spool outdated`.
use term::{println};
use string::{format};
use text::{slice};
use util::{join2, path_exists, tsv_field, vec_has};
use lock::{lock_find, lock_pkg_name, lock_pkg_tag, lock_pkg_rev, lock_pkg_ref, lock_pkg_hash};
use manifest::{deps_read, dep_kind, dep_name, dep_path, package_name_read, package_version_parse, manifest_body};
use resolve::{collect, resolve_dep_path, reqs_for};
use tags::{parse_ls_remote, ls_remote_tag_names};
use semver::{select_tag, select_tag_all};
use git::{checkout_path, ls_remote_tags, is_hex_sha};

fn short_sha(string s) -> string {
    if len(s) <= 10 {
        return s;
    }
    return match slice(s, 0, 10) {
        Result::Ok(x) => x,
        Result::Err(_) => s,
    };
}

fn describe_locked(string p) -> string {
    if is_hex_sha(lock_pkg_ref(p)) {
        return lock_pkg_name(p) + " @ " + short_sha(lock_pkg_rev(p));
    }
    if len(lock_pkg_ref(p)) > 0 {
        return lock_pkg_name(p) + " " + lock_pkg_ref(p) + " @ " + short_sha(lock_pkg_rev(p));
    }
    return lock_pkg_name(p) + " " + lock_pkg_tag(p);
}

/// Children of a node: `g\tname` (git) or `p\tname\tdir` (path, root only).
fn children_of(string toml) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    if path_exists(toml) == false {
        return out;
    }
    let deps = match deps_read(toml) {
        Result::Ok(v) => v,
        Result::Err(_) => {
            return out;
        },
    };
    let i = 0;
    while i < len(deps) {
        let d = deps[i];
        i = i + 1;
        if dep_kind(d) == "g" {
            out.push("g\t" + dep_name(d));
        } else {
            out.push("p\t" + dep_name(d) + "\t" + dep_path(d));
        }
    }
    return out;
}

fn print_children(string root, Vec<string> packages, Vec<string> kids, string prefix, Vec<string> stack) {
    let i = 0;
    while i < len(kids) {
        let k = kids[i];
        i = i + 1;
        let last = i == len(kids);
        let branch = "├── ";
        let next_prefix = prefix + "│   ";
        if last {
            branch = "└── ";
            next_prefix = prefix + "    ";
        }
        let kind = tsv_field(k, 0);
        let name = tsv_field(k, 1);
        if kind == "p" {
            let dir = resolve_dep_path(root, tsv_field(k, 2));
            println(prefix + branch + name + " (path " + tsv_field(k, 2) + ")");
            // Path deps' own git deps are part of the graph.
            let sub = children_of(join2(dir, "coil.toml"));
            let git_only: Vec<string> = Vec::new();
            let j = 0;
            while j < len(sub) {
                if tsv_field(sub[j], 0) == "g" {
                    git_only.push(sub[j]);
                }
                j = j + 1;
            }
            print_children(root, packages, git_only, next_prefix, stack);
            continue;
        }
        let p = lock_find(packages, name);
        if len(p) == 0 {
            println(prefix + branch + name + " (not locked; run spool install)");
            continue;
        }
        if vec_has(stack, name) {
            println(prefix + branch + describe_locked(p) + " (cycle)");
            continue;
        }
        println(prefix + branch + describe_locked(p));
        let dest = match checkout_path(lock_pkg_hash(p)) {
            Result::Ok(d) => d,
            Result::Err(_) => "",
        };
        let sub = children_of(join2(dest, "coil.toml"));
        let git_only: Vec<string> = Vec::new();
        let j = 0;
        while j < len(sub) {
            if tsv_field(sub[j], 0) == "g" {
                git_only.push(sub[j]);
            }
            j = j + 1;
        }
        // Vec is a reference; copy so siblings keep their own stack.
        let st: Vec<string> = Vec::new();
        let m = 0;
        while m < len(stack) {
            st.push(stack[m]);
            m = m + 1;
        }
        st.push(name);
        print_children(root, packages, git_only, next_prefix, st);
    }
}

fn print_tree(string root, Vec<string> packages) -> Result<int, string> {
    let toml = join2(root, "coil.toml");
    let body = manifest_body(toml)?;
    let name = package_name_read(toml);
    if len(name) == 0 {
        name = "(root)";
    }
    let ver = package_version_parse(body);
    if len(ver) > 0 {
        println(name + " v" + ver);
    } else {
        println(name);
    }
    let empty: Vec<string> = Vec::new();
    print_children(root, packages, children_of(toml), "", empty);
    return 0;
}

fn pad(string s, int width) -> string {
    let out = s;
    while len(out) < width {
        out = out + " ";
    }
    return out + " ";
}

/// Newest tag matching every constraint, and the newest tag overall.
fn print_outdated(string root, Vec<string> packages) -> Result<int, string> {
    let empty: Vec<string> = Vec::new();
    let res = collect(root, packages, empty)?;
    let (cons, todo) = res;
    println(pad("name", 16) + pad("locked", 12) + pad("compatible", 12) + "latest");
    let behind = 0;
    let i = 0;
    while i < len(packages) {
        let p = packages[i];
        i = i + 1;
        let name = lock_pkg_name(p);
        if len(lock_pkg_ref(p)) > 0 {
            println(pad(name, 16) + pad("@" + lock_pkg_ref(p), 12) + pad("-", 12) + "-");
            continue;
        }
        let body = ls_remote_tags(tsv_field(p, 1))?;
        let rows = parse_ls_remote(body)?;
        let tag_names = ls_remote_tag_names(rows);
        let latest = match select_tag("*", tag_names) {
            Result::Ok(t) => t,
            Result::Err(_) => "-",
        };
        let reqs = reqs_for(cons, name);
        let compatible = "-";
        if len(reqs) > 0 {
            compatible = match select_tag_all(reqs, tag_names) {
                Result::Ok(t) => t,
                Result::Err(_) => "-",
            };
        }
        let locked = lock_pkg_tag(p);
        if locked != latest || locked != compatible {
            behind = behind + 1;
        }
        println(pad(name, 16) + pad(locked, 12) + pad(compatible, 12) + latest);
    }
    if behind == 0 {
        println("all dependencies are up to date");
    }
    return 0;
}
