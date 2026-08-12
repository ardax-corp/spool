// Resolve git deps: pick a tag from ls-remote, write resolve.sh, merge coil.lock.
use io::file::{write_text, read_text};
use io::fs::{exists};
use path::{dirname, is_absolute};
use text::{trim, split, contains};
use string::{format};
use util::{join2, join3, join4, ensure_dir, git_sh_preamble};
use config::{cache_root};
use cache_url::{url_cache_key};
use lock::{
    make_git_pkg, lock_read_or_empty, lock_read, lock_upsert, lock_write, lock_find,
    lock_pkg_name, lock_pkg_tag, lock_pkg_hash,
};
use manifest::{
    deps_read, find_dep, dep_kind, dep_name, dep_git, dep_version, dep_path,
    make_git_dep, make_path_dep, deps_append, package_name_read,
};
use tags::{parse_ls_remote, ls_remote_tag_names, ls_remote_sha};
use semver::{select_tag, select_tag_all, tag_satisfies_all};

fn sh_quote(string s) -> string {
    return "'" + s + "'";
}

fn contains_space(string s) -> bool {
    return contains(s, " ");
}

fn write_resolve_script(string root, string name, string url, string tag, string rev) -> Result<int, string> {
    let cache = cache_root()?;
    let key = url_cache_key(url)?;
    let (host, owner, repo) = key;
    let bare = join4(join2(cache, "git"), host, owner, repo);
    let bare_parent = match dirname(bare) {
        Result::Ok(d) => d,
        Result::Err(_) => ".",
    };
    ensure_dir(bare_parent)?;
    let checkouts = join3(cache, "git", "checkouts");
    ensure_dir(checkouts)?;
    let tmp = join2(checkouts, ".tmp-" + name);
    let resolved = join2(root, ".spool/resolved.tsv");

    let script = git_sh_preamble();
    script = script + "RESOLVED=" + sh_quote(resolved) + "\n";
    script = script + ": > \"$RESOLVED\"\n";
    script = script + "BARE=" + sh_quote(bare) + "\n";
    script = script + "URL=" + sh_quote(url) + "\n";
    script = script + "REV=" + sh_quote(rev) + "\n";
    script = script + "NAME=" + sh_quote(name) + "\n";
    script = script + "TAG=" + sh_quote(tag) + "\n";
    script = script + "TMP=" + sh_quote(tmp) + "\n";
    script = script + "CHECKOUTS=" + sh_quote(checkouts) + "\n";
    script = script + "if [ -d \"$BARE\" ]; then\n";
    script = script + "  git -C \"$BARE\" fetch --tags --force origin\n";
    script = script + "else\n";
    script = script + "  git clone --bare \"$URL\" \"$BARE\"\n";
    script = script + "fi\n";
    script = script + "rm -rf \"$TMP\"\n";
    script = script + "git -C \"$BARE\" worktree add --detach \"$TMP\" \"$REV\"\n";
    script = script + "TREE=$(git -C \"$TMP\" rev-parse 'HEAD^{tree}')\n";
    script = script + "DEST=\"$CHECKOUTS/$TREE\"\n";
    script = script + "if [ -d \"$DEST\" ]; then\n";
    script = script + "  git -C \"$BARE\" worktree remove --force \"$TMP\" || rm -rf \"$TMP\"\n";
    script = script + "else\n";
    script = script + "  git -C \"$BARE\" worktree move \"$TMP\" \"$DEST\"\n";
    script = script + "fi\n";
    script = script + "printf '%s\\t%s\\t%s\\t%s\\t%s\\n' \"$NAME\" \"$URL\" \"$TAG\" \"$REV\" \"$TREE\" >> \"$RESOLVED\"\n";

    return match write_text(join2(root, ".spool/resolve.sh"), script) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write resolve.sh failed",
    };
}

fn run_add_manifest(string root, string name, string git, string path, string version) -> Result<int, string> {
    if len(name) == 0 {
        raise "missing package name";
    }
    if contains_space(name) {
        raise "package name must not contain whitespace";
    }
    let dep = "";
    if len(git) > 0 {
        if len(path) > 0 {
            raise "git and path are mutually exclusive";
        }
        let ver = version;
        if len(ver) == 0 {
            ver = "*";
        }
        dep = make_git_dep(name, git, ver);
    } else {
        if len(path) == 0 {
            raise "need --git or --path";
        }
        dep = make_path_dep(name, path);
    }
    return deps_append(join2(root, "coil.toml"), dep)?;
}

fn run_apply_resolved(string root) -> Result<int, string> {
    let path = join2(root, ".spool/resolved.tsv");
    let body = match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => raise "read resolved.tsv failed",
    };
    let packages = lock_read_or_empty(join2(root, "coil.lock"))?;
    let lines = match split(body, "\n") {
        Result::Ok(ls) => ls,
        Result::Err(_) => raise "split resolved failed",
    };
    let out = packages;
    let n = 0;
    let i = 0;
    while i < len(lines) {
        let line = match trim(lines[i]) {
            Result::Ok(t) => t,
            Result::Err(_) => lines[i],
        };
        i = i + 1;
        if len(line) == 0 {
            continue;
        }
        let parts = match split(line, "\t") {
            Result::Ok(p) => p,
            Result::Err(_) => raise "bad resolved line",
        };
        if len(parts) < 5 {
            raise "bad resolved line";
        }
        let pkg = make_git_pkg(parts[0], parts[1], parts[2], parts[3], parts[4]);
        out = lock_upsert(out, pkg);
        n = n + 1;
    }
    if n == 0 {
        raise "resolved.tsv is empty";
    }
    return lock_write(join2(root, "coil.lock"), out)?;
}

fn run_list_git_deps(string root) -> Result<int, string> {
    let deps = deps_read(join2(root, "coil.toml"))?;
    let out = "";
    let i = 0;
    while i < len(deps) {
        let d = deps[i];
        i = i + 1;
        if dep_kind(d) != "g" {
            continue;
        }
        out = out + dep_name(d) + "\t" + dep_git(d) + "\t" + dep_version(d) + "\n";
    }
    ensure_dir(join2(root, ".spool"))?;
    return match write_text(join2(root, ".spool/git-deps.tsv"), out) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write git-deps.tsv failed",
    };
}

fn resolve_dep_path(string root, string p) -> string {
    if is_absolute(p) {
        return p;
    }
    return join2(root, p);
}

fn path_dep_links(string root) -> Result<string, string> {
    let deps = deps_read(join2(root, "coil.toml"))?;
    let links = "";
    let i = 0;
    while i < len(deps) {
        let d = deps[i];
        i = i + 1;
        if dep_kind(d) != "p" {
            continue;
        }
        let dest = resolve_dep_path(root, dep_path(d));
        let present = match exists(dest) {
            Result::Ok(v) => v,
            Result::Err(_) => false,
        };
        if present == false {
            raise format("path dependency %s not found: %s", dep_name(d), dest);
        }
        links = links + dep_name(d) + "\t" + dest + "\n";
    }
    return links;
}

fn con_field(string c, int idx) -> string {
    let parts = match split(c, "\t") {
        Result::Ok(v) => v,
        Result::Err(_) => {
            let empty: Vec<string> = Vec::new();
            empty
        },
    };
    if idx < len(parts) {
        return parts[idx];
    }
    return "";
}

fn make_con(string name, string git, string version, string who) -> string {
    return name + "\t" + git + "\t" + version + "\t" + who;
}

fn checkout_dir(string hash) -> Result<string, string> {
    let cache = cache_root()?;
    return join2(join3(cache, "git", "checkouts"), hash);
}

fn root_requester(string root) -> string {
    let n = package_name_read(join2(root, "coil.toml"));
    if len(n) == 0 {
        return "root";
    }
    return n;
}

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
        let j = 0;
        while j < len(cons) {
            if con_field(cons[j], 0) == name {
                if con_field(cons[j], 1) != git {
                    raise "package " + name + ": git url mismatch (" + con_field(cons[j], 3) + " wants " + con_field(cons[j], 1) + ", " + who + " wants " + git + ")";
                }
            }
            j = j + 1;
        }
        let rec = make_con(name, git, dep_version(d), who);
        let dup = false;
        j = 0;
        while j < len(cons) {
            if cons[j] == rec {
                dup = true;
            }
            j = j + 1;
        }
        if dup == false {
            cons.push(rec);
        }
    }
    return cons;
}

fn scan_toml_cons(Vec<string> cons, string toml_path, string who) -> Result<Vec<string>, string> {
    let present = match exists(toml_path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        return cons;
    }
    let deps = deps_read(toml_path)?;
    return push_git_cons(cons, deps, who)?;
}

fn format_diamond(string name, Vec<string> cons) -> string {
    let bits = "";
    let i = 0;
    while i < len(cons) {
        let c = cons[i];
        i = i + 1;
        if con_field(c, 0) != name {
            continue;
        }
        if len(bits) > 0 {
            bits = bits + ", ";
        }
        bits = bits + con_field(c, 3) + " requires " + con_field(c, 2);
    }
    return format("diamond conflict for %s: %s", name, bits);
}

fn reqs_for(Vec<string> cons, string name) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(cons) {
        if con_field(cons[i], 0) == name {
            out.push(con_field(cons[i], 2));
        }
        i = i + 1;
    }
    return out;
}

fn git_for(Vec<string> cons, string name) -> string {
    let i = 0;
    while i < len(cons) {
        if con_field(cons[i], 0) == name {
            return con_field(cons[i], 1);
        }
        i = i + 1;
    }
    return "";
}

fn unique_git_names(Vec<string> cons) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    let i = 0;
    while i < len(cons) {
        let n = con_field(cons[i], 0);
        let seen = false;
        let j = 0;
        while j < len(out) {
            if out[j] == n {
                seen = true;
            }
            j = j + 1;
        }
        if seen == false {
            out.push(n);
        }
        i = i + 1;
    }
    return out;
}

fn parse_constraints_body(string body) -> Vec<string> {
    let out: Vec<string> = Vec::new();
    if len(body) == 0 {
        return out;
    }
    let lines = match split(body, "\n") {
        Result::Ok(ls) => ls,
        Result::Err(_) => {
            return out;
        },
    };
    let i = 0;
    while i < len(lines) {
        let line = match trim(lines[i]) {
            Result::Ok(t) => t,
            Result::Err(_) => lines[i],
        };
        i = i + 1;
        if len(line) == 0 {
            continue;
        }
        out.push(line);
    }
    return out;
}

fn read_constraints(string root) -> Vec<string> {
    let path = join2(root, ".spool/constraints.tsv");
    let present = match exists(path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        let empty: Vec<string> = Vec::new();
        return empty;
    }
    let body = match read_text(path) {
        Result::Ok(s) => s,
        Result::Err(_) => {
            let empty: Vec<string> = Vec::new();
            return empty;
        },
    };
    return parse_constraints_body(body);
}

fn run_collect(string root) -> Result<int, string> {
    let who = root_requester(root);
    let cons: Vec<string> = Vec::new();
    cons = scan_toml_cons(cons, join2(root, "coil.toml"), who)?;

    let root_deps = deps_read(join2(root, "coil.toml"))?;
    let i = 0;
    while i < len(root_deps) {
        let d = root_deps[i];
        i = i + 1;
        if dep_kind(d) != "p" {
            continue;
        }
        let dest = resolve_dep_path(root, dep_path(d));
        cons = scan_toml_cons(cons, join2(dest, "coil.toml"), dep_name(d))?;
    }

    let packages = lock_read_or_empty(join2(root, "coil.lock"))?;
    i = 0;
    while i < len(packages) {
        let p = packages[i];
        i = i + 1;
        let dest = checkout_dir(lock_pkg_hash(p))?;
        cons = scan_toml_cons(cons, join2(dest, "coil.toml"), lock_pkg_name(p))?;
    }

    let body = "";
    i = 0;
    while i < len(cons) {
        body = body + cons[i] + "\n";
        i = i + 1;
    }
    ensure_dir(join2(root, ".spool"))?;
    match write_text(join2(root, ".spool/constraints.tsv"), body) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write constraints.tsv failed",
    };

    let todo = "";
    let names = unique_git_names(cons);
    i = 0;
    while i < len(names) {
        let name = names[i];
        i = i + 1;
        let reqs = reqs_for(cons, name);
        let git = git_for(cons, name);
        let locked = lock_find(packages, name);
        if len(locked) > 0 {
            let tag = lock_pkg_tag(locked);
            let ok_res = tag_satisfies_all(tag, reqs);
            match ok_res {
                Result::Ok(ok) => {
                    if ok {
                        continue;
                    }
                },
                Result::Err(_) => {},
            };
        }
        todo = todo + name + "\t" + git + "\n";
    }
    return match write_text(join2(root, ".spool/todo.tsv"), todo) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write todo.tsv failed",
    };
}

fn run_check_install(string root) -> Result<int, string> {
    let toml = join2(root, "coil.toml");
    let present = match exists(toml) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        raise "coil.toml not found";
    }
    let deps = deps_read(toml)?;
    let git_n = 0;
    let i = 0;
    while i < len(deps) {
        if dep_kind(deps[i]) == "g" {
            git_n = git_n + 1;
        }
        i = i + 1;
    }
    let lock_path = join2(root, "coil.lock");
    let lock_ok = match exists(lock_path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if git_n > 0 {
        if lock_ok == false {
            raise "missing coil.lock: run spool add or commit a lockfile";
        }
    }
    if lock_ok == false {
        return 0;
    }
    let packages = lock_read(lock_path)?;
    i = 0;
    while i < len(deps) {
        let d = deps[i];
        i = i + 1;
        if dep_kind(d) != "g" {
            continue;
        }
        let n = dep_name(d);
        if len(lock_find(packages, n)) == 0 {
            raise format("unresolved dependency %s (declared in coil.toml, not in coil.lock)", n);
        }
    }
    return 0;
}

fn run_pick(string root, string name) -> Result<int, string> {
    if len(name) == 0 {
        raise "missing package name";
    }
    let cons = read_constraints(root);
    let url = "";
    let reqs: Vec<string> = Vec::new();
    if len(reqs_for(cons, name)) > 0 {
        reqs = reqs_for(cons, name);
        url = git_for(cons, name);
    } else {
        let deps = deps_read(join2(root, "coil.toml"))?;
        let dep = find_dep(deps, name)?;
        if dep_kind(dep) != "g" {
            raise format("%s is not a git dependency", name);
        }
        url = dep_git(dep);
        reqs.push(dep_version(dep));
    }
    if len(url) == 0 {
        raise format("no git url for %s", name);
    }
    let tags_path = join2(root, ".spool/tags.tsv");
    let present = match exists(tags_path) {
        Result::Ok(v) => v,
        Result::Err(_) => false,
    };
    if present == false {
        raise "missing .spool/tags.tsv";
    }
    let body = match read_text(tags_path) {
        Result::Ok(s) => s,
        Result::Err(_) => raise "read tags.tsv failed",
    };
    let rows = parse_ls_remote(body)?;
    let tag_names = ls_remote_tag_names(rows);
    let tag = "";
    if len(reqs) == 1 {
        tag = select_tag(reqs[0], tag_names)?;
    } else {
        let tag_res = select_tag_all(reqs, tag_names);
        match tag_res {
            Result::Ok(t) => {
                tag = t;
            },
            Result::Err(_) => {
                raise format_diamond(name, cons);
            },
        };
    }
    let sha = ls_remote_sha(rows, tag)?;
    ensure_dir(join2(root, ".spool"))?;
    let pick = name + "\t" + url + "\t" + tag + "\t" + sha + "\n";
    match write_text(join2(root, ".spool/pick.tsv"), pick) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write pick.tsv failed",
    };
    return write_resolve_script(root, name, url, tag, sha)?;
}
