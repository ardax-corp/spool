// Resolve git deps: pick a tag from ls-remote, write resolve.sh, merge coil.lock.
use io::file::{write_text, read_text};
use io::fs::{exists};
use path::{dirname, is_absolute};
use text::{trim, split, contains};
use string::{format};
use util::{join2, join3, join4, ensure_dir};
use config::{cache_root};
use cache_url::{url_cache_key};
use lock::{
    make_git_pkg, lock_read_or_empty, lock_upsert, lock_write,
};
use manifest::{
    deps_read, find_dep, dep_kind, dep_name, dep_git, dep_version, dep_path,
    make_git_dep, make_path_dep, deps_append,
};
use tags::{parse_ls_remote, ls_remote_tag_names, ls_remote_sha};
use semver::{select_tag};

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

    let script = "#!/bin/sh\nset -e\n";
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

fn run_pick(string root, string name) -> Result<int, string> {
    if len(name) == 0 {
        raise "missing package name";
    }
    let deps = deps_read(join2(root, "coil.toml"))?;
    let dep = find_dep(deps, name)?;
    if dep_kind(dep) != "g" {
        raise format("%s is not a git dependency", name);
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
    let tag = select_tag(dep_version(dep), tag_names)?;
    let sha = ls_remote_sha(rows, tag)?;
    ensure_dir(join2(root, ".spool"))?;
    let pick = name + "\t" + dep_git(dep) + "\t" + tag + "\t" + sha + "\n";
    match write_text(join2(root, ".spool/pick.tsv"), pick) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write pick.tsv failed",
    };
    return write_resolve_script(root, name, dep_git(dep), tag, sha)?;
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
