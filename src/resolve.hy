// Resolve git deps in memory: collect constraints over the reachable graph,
// pick tags (or `rev` pins) against ls-remote, fetch, and prune the lock.
// Constraint rows: name \t git \t req \t who  (req is a range or `@<rev>`).
use io::file::{read_text};
use text::{trim, split, starts_with, slice};
use string::{format};
use util::{join2, path_is_absolute, path_exists, tsv_field, vec_has, check_pkg_name, check_git_url};
use lock::{
    make_git_pkg_ref, lock_upsert, lock_find, lock_pkg_name, lock_pkg_tag, lock_pkg_hash,
    lock_pkg_git, lock_pkg_rev, lock_pkg_ref,
};
use manifest::{
    deps_read, dep_kind, dep_name, dep_git, dep_path, dep_req, dep_rev,
    package_name_read, package_name_parse, package_coil_parse,
};
use tags::{parse_ls_remote, ls_remote_tag_names, ls_remote_sha};
use semver::{select_tag, select_tag_all, tag_satisfies_all};
use engine::{enforce_engine};
use git::{ls_remote_tags, ls_remote_ref, fetch_rev, checkout_path, is_hex_sha};

fn resolve_dep_path(string root, string p) -> string {
    if path_is_absolute(p) {
        return p;
    }
    return join2(root, p);
}

fn root_requester(string root) -> string {
    let n = package_name_read(join2(root, "coil.toml"));
    if len(n) == 0 {
        return "root";
    }
    return n;
}

fn make_con(string name, string git, string req, string who) -> string {
    return name + "\t" + git + "\t" + req + "\t" + who;
}

fn con_name(string c) -> string {
    return tsv_field(c, 0);
}

fn con_git(string c) -> string {
    return tsv_field(c, 1);
}

fn con_req(string c) -> string {
    return tsv_field(c, 2);
}

fn con_who(string c) -> string {
    return tsv_field(c, 3);
}

/// Append the git deps of one manifest. Names and urls are validated here:
/// a transitive manifest is untrusted input.
fn push_git_cons(Vec<string> cons, Vec<string> deps, string who) -> Result<Vec<string>, string> {
    let i = 0;
    while i < len(deps) {
        let d = deps[i];
        i = i + 1;
        if dep_kind(d) != "g" {
            continue;
        }
        let name = dep_name(d);
        let git = dep_git(d);
        check_pkg_name(name)?;
        check_git_url(git)?;
        let j = 0;
        while j < len(cons) {
            if con_name(cons[j]) == name && con_git(cons[j]) != git {
                raise "package " + name + ": git url mismatch (" + con_who(cons[j]) + " wants " + con_git(cons[j]) + ", " + who + " wants " + git + ")";
            }
            j = j + 1;
        }
        let rec = make_con(name, git, dep_req(d), who);
        if vec_has(cons, rec) == false {
            cons.push(rec);
        }
    }
    return cons;
}

fn scan_toml_cons(Vec<string> cons, string toml_path, string who) -> Result<Vec<string>, string> {
    if path_exists(toml_path) == false {
        return cons;
    }
    let deps = deps_read(toml_path)?;
    return push_git_cons(cons, deps, who)?;
}

/// Constraints declared by the project and its path deps.
fn root_cons(string root) -> Result<Vec<string>, string> {
    let cons: Vec<string> = Vec::new();
    let toml = join2(root, "coil.toml");
    cons = scan_toml_cons(cons, toml, root_requester(root))?;
    let deps = deps_read(toml)?;
    let i = 0;
    while i < len(deps) {
        let d = deps[i];
        i = i + 1;
        if dep_kind(d) != "p" {
            continue;
        }
        check_pkg_name(dep_name(d))?;
        let dest = resolve_dep_path(root, dep_path(d));
        cons = scan_toml_cons(cons, join2(dest, "coil.toml"), dep_name(d))?;
    }
    return cons;
}

fn reqs_for(Vec<string> cons, string name) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(cons) {
        if con_name(cons[i]) == name {
            out.push(con_req(cons[i]));
        }
        i = i + 1;
    }
    return out;
}

fn git_for(Vec<string> cons, string name) -> string {
    let i = 0;
    while i < len(cons) {
        if con_name(cons[i]) == name {
            return con_git(cons[i]);
        }
        i = i + 1;
    }
    return "";
}

fn unique_names(Vec<string> cons) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(cons) {
        let n = con_name(cons[i]);
        if vec_has(out, n) == false {
            out.push(n);
        }
        i = i + 1;
    }
    return out;
}

fn format_diamond(string name, Vec<string> cons) -> string {
    let bits = "";
    let i = 0;
    while i < len(cons) {
        let c = cons[i];
        i = i + 1;
        if con_name(c) != name {
            continue;
        }
        if len(bits) > 0 {
            bits = bits + ", ";
        }
        bits = bits + con_who(c) + " requires " + con_req(c);
    }
    return format("diamond conflict for %s: %s", name, bits);
}

fn strip_at(string req) -> string {
    return match slice(req, 1, len(req)) {
        Result::Ok(x) => x,
        Result::Err(_) => req,
    };
}

/// The single `@rev` pin among reqs, "" when none; mixed / different pins raise.
fn pin_of(string name, Vec<string> reqs, Vec<string> cons) -> Result<string, string> {
    let pin = "";
    let ranges = 0;
    let i = 0;
    while i < len(reqs) {
        let r = reqs[i];
        i = i + 1;
        if starts_with(r, "@") {
            let p = strip_at(r);
            if len(pin) > 0 && pin != p {
                raise format_diamond(name, cons);
            }
            pin = p;
        } else {
            ranges = ranges + 1;
        }
    }
    if len(pin) > 0 && ranges > 0 {
        raise format_diamond(name, cons);
    }
    return pin;
}

/// Does the locked row still satisfy every constraint on its name?
fn locked_ok(string locked, string url, Vec<string> reqs, string pin) -> bool {
    if len(locked) == 0 {
        return false;
    }
    if lock_pkg_git(locked) != url {
        return false;
    }
    if len(pin) > 0 {
        if lock_pkg_ref(locked) != pin {
            return false;
        }
        if is_hex_sha(pin) {
            return lock_pkg_rev(locked) == pin;
        }
        return true;
    }
    if len(lock_pkg_ref(locked)) > 0 {
        return false;
    }
    return match tag_satisfies_all(lock_pkg_tag(locked), reqs) {
        Result::Ok(ok) => ok,
        Result::Err(_) => false,
    };
}

/// Walk the graph from the project through locked checkouts.
/// Returns (constraints, todo) where todo rows are `name \t url`.
/// Names in `force` are re-resolved even when the lock satisfies them.
fn collect(string root, Vec<string> packages, Vec<string> force) -> Result<(Vec<string>, Vec<string>), string> {
    let cons = root_cons(root)?;
    let scanned: Vec<string> = Vec::new();
    let todo: Vec<string> = Vec::new();
    let changed = true;
    while changed {
        changed = false;
        let names = unique_names(cons);
        let i = 0;
        while i < len(names) {
            let name = names[i];
            i = i + 1;
            if vec_has(scanned, name) {
                continue;
            }
            scanned.push(name);
            let url = git_for(cons, name);
            let reqs = reqs_for(cons, name);
            let pin = pin_of(name, reqs, cons)?;
            let locked = lock_find(packages, name);
            if vec_has(force, name) || locked_ok(locked, url, reqs, pin) == false {
                todo.push(name + "\t" + url);
                continue;
            }
            let dest = checkout_path(lock_pkg_hash(locked))?;
            cons = scan_toml_cons(cons, join2(dest, "coil.toml"), name)?;
            changed = true;
        }
    }
    // A later scan can add a constraint that a locked pick no longer meets.
    let names = unique_names(cons);
    let k = 0;
    while k < len(names) {
        let name = names[k];
        k = k + 1;
        let url = git_for(cons, name);
        let row = name + "\t" + url;
        if vec_has(todo, row) {
            continue;
        }
        let reqs = reqs_for(cons, name);
        let pin = pin_of(name, reqs, cons)?;
        if locked_ok(lock_find(packages, name), url, reqs, pin) == false {
            todo.push(row);
        }
    }
    return (cons, todo);
}

/// Pick and fetch one package; returns its new lock row.
fn resolve_one(string name, string url, Vec<string> cons) -> Result<string, string> {
    let reqs = reqs_for(cons, name);
    if len(reqs) == 0 {
        raise format("no requirement for %s", name);
    }
    let pin = pin_of(name, reqs, cons)?;
    let tag = "";
    let sha = "";
    if len(pin) > 0 {
        sha = ls_remote_ref(url, pin)?;
    } else {
        let body = ls_remote_tags(url)?;
        let rows = parse_ls_remote(body)?;
        let tag_names = ls_remote_tag_names(rows);
        if len(reqs) == 1 {
            tag = match select_tag(reqs[0], tag_names) {
                Result::Ok(t) => t,
                Result::Err(e) => raise format("%s: %s", name, e),
            };
        } else {
            tag = match select_tag_all(reqs, tag_names) {
                Result::Ok(t) => t,
                Result::Err(_) => raise format_diamond(name, cons),
            };
        }
        sha = ls_remote_sha(rows, tag)?;
    }
    let tree = fetch_rev(url, sha)?;
    return make_git_pkg_ref(name, url, tag, sha, tree, "", "", pin);
}

/// Resolve until the lock satisfies every reachable constraint.
fn resolve_all(string root, Vec<string> packages, Vec<string> force) -> Result<Vec<string>, string> {
    let pass = 0;
    let f = force;
    while pass < 32 {
        pass = pass + 1;
        let res = collect(root, packages, f)?;
        let (cons, todo) = res;
        if len(todo) == 0 {
            return packages;
        }
        let i = 0;
        while i < len(todo) {
            let name = tsv_field(todo[i], 0);
            let url = tsv_field(todo[i], 1);
            i = i + 1;
            let row = resolve_one(name, url, cons)?;
            packages = lock_upsert(packages, row);
        }
        let empty: Vec<string> = Vec::new();
        f = empty;
    }
    raise "resolve loop exceeded 32 passes";
}

fn packages_none() -> Vec<string> {
    let empty: Vec<string> = Vec::new();
    return empty;
}

/// Names reachable from the project (git deps only).
fn reachable_names(string root, Vec<string> packages) -> Result<Vec<string>, string> {
    let res = collect(root, packages, packages_none())?;
    let (cons, todo) = res;
    return unique_names(cons);
}

/// Drop lock rows nothing reaches any more.
fn prune(Vec<string> packages, Vec<string> keep) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(packages) {
        if vec_has(keep, lock_pkg_name(packages[i])) {
            out.push(packages[i]);
        }
        i = i + 1;
    }
    return out;
}

/// `name \t dir` for every package to link: locked git checkouts, then path deps.
fn link_rows(string root, Vec<string> packages) -> Result<Vec<string>, string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(packages) {
        let p = packages[i];
        i = i + 1;
        check_pkg_name(lock_pkg_name(p))?;
        let dest = checkout_path(lock_pkg_hash(p))?;
        out.push(lock_pkg_name(p) + "\t" + dest);
    }
    let deps = deps_read(join2(root, "coil.toml"))?;
    i = 0;
    while i < len(deps) {
        let d = deps[i];
        i = i + 1;
        if dep_kind(d) != "p" {
            continue;
        }
        check_pkg_name(dep_name(d))?;
        let dest = resolve_dep_path(root, dep_path(d));
        if path_exists(dest) == false {
            raise format("path dependency %s not found: %s", dep_name(d), dest);
        }
        out.push(dep_name(d) + "\t" + dest);
    }
    return out;
}

fn check_one_toml(string toml_path, string fallback_name, string running) -> Result<int, string> {
    if path_exists(toml_path) == false {
        return 0;
    }
    let body = match read_text(toml_path) {
        Result::Ok(s) => s,
        Result::Err(_) => raise format("failed to read %s", toml_path),
    };
    let name = package_name_parse(body);
    if len(name) == 0 {
        name = fallback_name;
    }
    if len(name) == 0 {
        name = toml_path;
    }
    return enforce_engine(name, package_coil_parse(body), running)?;
}

/// `[package].coil` of the project, path deps and every locked checkout on disk.
fn check_engine_all(string root, Vec<string> packages, string running) -> Result<int, string> {
    let toml = join2(root, "coil.toml");
    check_one_toml(toml, root_requester(root), running)?;
    let deps = deps_read(toml)?;
    let i = 0;
    while i < len(deps) {
        let d = deps[i];
        i = i + 1;
        if dep_kind(d) != "p" {
            continue;
        }
        let dest = resolve_dep_path(root, dep_path(d));
        check_one_toml(join2(dest, "coil.toml"), dep_name(d), running)?;
    }
    i = 0;
    while i < len(packages) {
        let p = packages[i];
        i = i + 1;
        let dest = checkout_path(lock_pkg_hash(p))?;
        check_one_toml(join2(dest, "coil.toml"), lock_pkg_name(p), running)?;
    }
    return 0;
}
