// Host git through proc: ls-remote, bare cache clones, detached worktrees.
// GIT_TERMINAL_PROMPT=0 so a missing credential fails instead of hanging.
use string::{format};
use text::{slice, contains, starts_with};
use clock::{wall_nanos};
use util::{join2, join3, join4, ensure_dir, path_dirname, path_exists, trim_or, check_git_url};
use proc::{sh_run, sh_capture, first_line};
use config::{cache_root};
use cache_url::{url_cache_key};

fn git_auth_hint() -> string {
    return "private remotes use ssh-agent, GIT_ASKPASS, git credential helpers, or url.insteadOf in ~/.gitconfig; spool does not store credentials";
}

fn git_failed(string what, string url) -> string {
    return format("git %s failed for %s\n  hint: %s", what, url, git_auth_hint());
}

fn git_env_prefix() -> string {
    return "export GIT_TERMINAL_PROMPT=0; ";
}

/// Raw `git ls-remote --tags` output for `url`.
fn ls_remote_tags(string url) -> Result<string, string> {
    check_git_url(url)?;
    let a: Vec<string> = Vec::new();
    a.push(url);
    let res = sh_capture(git_env_prefix() + "git ls-remote --tags \"$1\"", a)?;
    let (code, body) = res;
    if code != 0 {
        raise git_failed("ls-remote", url);
    }
    return body;
}

fn is_hex_sha(string s) -> bool {
    if len(s) != 40 {
        return false;
    }
    let hex = "0123456789abcdef";
    let i = 0;
    while i < 40 {
        let c = match slice(s, i, i + 1) {
            Result::Ok(x) => x,
            Result::Err(_) => {
                return false;
            },
        };
        if contains(hex, c) == false {
            return false;
        }
        i = i + 1;
    }
    return true;
}

/// Resolve a branch / tag / full sha to a commit sha on the remote.
fn ls_remote_ref(string url, string rev) -> Result<string, string> {
    check_git_url(url)?;
    if is_hex_sha(rev) {
        return rev;
    }
    if starts_with(rev, "-") {
        raise format("invalid rev `%s`", rev);
    }
    let a: Vec<string> = Vec::new();
    a.push(url);
    a.push(rev);
    // Prefer the peeled commit of an annotated tag, then an exact ref.
    let script = git_env_prefix()
        + "out=$(git ls-remote \"$1\" \"$2\" \"refs/tags/$2^{}\" \"refs/heads/$2\" \"refs/tags/$2\") || exit 2; "
        + "p=$(printf '%s\\n' \"$out\" | awk '$2 ~ /\\^\\{\\}$/ {print $1; exit}'); "
        + "if [ -n \"$p\" ]; then echo \"$p\"; exit 0; fi; "
        + "printf '%s\\n' \"$out\" | awk 'NF {print $1; exit}'";
    let res = sh_capture(script, a)?;
    let (code, body) = res;
    if code != 0 {
        raise git_failed("ls-remote", url);
    }
    let sha = first_line(body);
    if len(sha) == 0 {
        raise format("rev `%s` not found in %s", rev, url);
    }
    return sha;
}

fn bare_dir(string url) -> Result<string, string> {
    let cache = cache_root()?;
    let key = url_cache_key(url)?;
    let (host, owner, repo) = key;
    return join4(join2(cache, "git"), host, owner, repo);
}

fn checkouts_dir() -> Result<string, string> {
    let cache = cache_root()?;
    let d = join3(cache, "git", "checkouts");
    ensure_dir(d)?;
    return d;
}

fn checkout_path(string tree) -> Result<string, string> {
    let d = checkouts_dir()?;
    return join2(d, tree);
}

fn bare_sync_script() -> string {
    return git_env_prefix()
        + "if [ -d \"$1\" ]; then git -C \"$1\" fetch -q --tags --force origin \"+refs/heads/*:refs/heads/*\" || exit 3; "
        + "else git clone -q --bare -- \"$2\" \"$1\" || exit 3; fi; ";
}

/// Fetch `rev` from `url` into the cache and return the checkout tree id.
/// The checkout lives at <cache>/git/checkouts/<tree>.
fn fetch_rev(string url, string rev) -> Result<string, string> {
    check_git_url(url)?;
    let bare = bare_dir(url)?;
    ensure_dir(path_dirname(bare))?;
    let checkouts = checkouts_dir()?;
    let tmp = join2(checkouts, format(".tmp-%i", wall_nanos()));
    let a: Vec<string> = Vec::new();
    a.push(bare);
    a.push(url);
    a.push(rev);
    a.push(tmp);
    a.push(checkouts);
    let script = bare_sync_script()
        + "git -C \"$1\" worktree prune; "
        + "git -C \"$1\" worktree add -q --detach \"$4\" \"$3\" >&2 || exit 4; "
        + "tree=$(git -C \"$4\" rev-parse 'HEAD^{tree}') || exit 4; "
        + "dest=\"$5/$tree\"; "
        + "if [ -d \"$dest\" ]; then git -C \"$1\" worktree remove --force \"$4\" || rm -rf \"$4\"; "
        + "else git -C \"$1\" worktree move \"$4\" \"$dest\" || exit 4; fi; "
        + "echo \"$tree\"";
    let res = sh_capture(script, a)?;
    let (code, body) = res;
    if code == 3 {
        raise git_failed("fetch", url);
    }
    if code != 0 {
        raise format("git checkout of %s at %s failed (exit %i)", url, rev, code);
    }
    let tree = first_line(body);
    if len(tree) == 0 {
        raise format("git checkout of %s at %s produced no tree", url, rev);
    }
    return tree;
}

/// Make sure <checkouts>/<tree> exists for a locked package (rev + hash).
fn ensure_checkout(string url, string rev, string tree) -> Result<string, string> {
    let dest = checkout_path(tree)?;
    if path_exists(dest) {
        return dest;
    }
    check_git_url(url)?;
    let bare = bare_dir(url)?;
    ensure_dir(path_dirname(bare))?;
    let a: Vec<string> = Vec::new();
    a.push(bare);
    a.push(url);
    a.push(rev);
    a.push(dest);
    let script = bare_sync_script()
        + "git -C \"$1\" worktree prune; "
        + "rm -rf \"$4\"; "
        + "git -C \"$1\" worktree add -q --detach \"$4\" \"$3\" >&2 || exit 4";
    let code = sh_run(script, a)?;
    if code == 3 {
        raise git_failed("fetch", url);
    }
    if code != 0 {
        raise format("git checkout of %s at %s failed (exit %i)", url, rev, code);
    }
    return dest;
}

/// `git rev-parse HEAD^{tree}` of a checkout, or "".
fn tree_of(string dir) -> string {
    let a: Vec<string> = Vec::new();
    a.push(dir);
    return match sh_capture("git -C \"$1\" rev-parse 'HEAD^{tree}' 2>/dev/null", a) {
        Result::Ok(res) => {
            let (code, body) = res;
            if code != 0 {
                return "";
            }
            return first_line(body);
        },
        Result::Err(_) => "",
    };
}

/// `git hash-object <file>`.
fn hash_object(string file) -> Result<string, string> {
    let a: Vec<string> = Vec::new();
    a.push(file);
    let res = sh_capture("git hash-object -- \"$1\"", a)?;
    let (code, body) = res;
    if code != 0 {
        raise format("git hash-object failed for %s", file);
    }
    return trim_or(body);
}
