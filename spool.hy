// spool plan/link helper (no libc extern — git runs in ./spool bash).
use env::{var, cwd};
use io::{stdout};
use io::sync::{write_all};
use io::file::{write_text, read_text};
use io::fs::{exists, is_dir};
use path::{dirname};
use string::{format, to_bytes};
use text::{split, trim};
use lock::{
    lock_read_or_empty, lock_pkg_name, lock_git_url, lock_git_rev, lock_git_hash,
};
use roots::{link_dep, ensure_roots_entry};
use util::{join2, join3, join4, ensure_dir, write_status, git_sh_preamble};
use config::{cache_root};
use cache_url::{url_cache_key};
use resolve::{
    run_add_manifest, run_pick, run_apply_resolved, run_list_git_deps, path_dep_links,
    run_collect, run_check_install,
};

fn run_plan(string root) -> Result<int, string> {
    let packages = lock_read_or_empty(join2(root, "coil.lock"))?;
    ensure_dir(join2(root, ".spool"))?;
    let script = git_sh_preamble();
    let links = "";
    let verify = "";
    let i = 0;
    while i < len(packages) {
        let p = packages[i];
        i = i + 1;
        let name = lock_pkg_name(p);
        let url = lock_git_url(p);
        let rev = lock_git_rev(p);
        let hash = lock_git_hash(p);
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
        let dest = join2(checkouts, hash);

        let bare_present = match exists(bare) {
            Result::Ok(v) => v,
            Result::Err(_) => false,
        };
        if bare_present {
            script = script + "git -C '" + bare + "' fetch --tags --force origin\n";
        } else {
            script = script + "git clone --bare '" + url + "' '" + bare + "'\n";
        }

        let dest_ok = false;
        match exists(dest) {
            Result::Ok(v) => {
                if v {
                    match is_dir(dest) {
                        Result::Ok(d) => {
                            if d {
                                dest_ok = true;
                            }
                        },
                        Result::Err(_) => {},
                    };
                }
            },
            Result::Err(_) => {},
        };
        if dest_ok == false {
            script = script + "rm -rf '" + dest + "'\n";
            script = script + "git -C '" + bare + "' worktree add --detach '" + dest + "' '" + rev + "'\n";
        }

        links = links + name + "\t" + dest + "\n";
        verify = verify + name + "\t" + dest + "\t" + hash + "\n";
    }

    let path_links = path_dep_links(root)?;
    links = links + path_links;

    match write_text(join2(root, ".spool/fetch.sh"), script) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write fetch.sh failed",
    };
    match write_text(join2(root, ".spool/links.tsv"), links) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write links.tsv failed",
    };
    match write_text(join2(root, ".spool/verify.tsv"), verify) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "write verify.tsv failed",
    };
    return 0;
}

fn run_link(string root) -> Result<int, string> {
    ensure_roots_entry(root)?;
    let body = match read_text(join2(root, ".spool/links.tsv")) {
        Result::Ok(s) => s,
        Result::Err(_) => raise "read links.tsv failed",
    };
    if len(body) == 0 {
        return 0;
    }
    let lines = match split(body, "\n") {
        Result::Ok(ls) => ls,
        Result::Err(_) => raise "split links failed",
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
        let parts = match split(line, "\t") {
            Result::Ok(p) => p,
            Result::Err(_) => raise "bad links line",
        };
        if len(parts) < 2 {
            raise "bad links line";
        }
        link_dep(root, parts[0], parts[1])?;
    }
    return 0;
}

fn env_or_empty(string key) -> string {
    match var(key) {
        Result::Ok(c) => {
            return c;
        },
        Result::Err(_) => {
            return "";
        },
    };
}

fn finish_ok(string root, string msg) {
    match write_status(root, "ok") {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
    match write_all(stdout(), to_bytes(msg)) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}

fn finish_err(string root, string msg) {
    match write_status(root, msg) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
    match write_all(stdout(), to_bytes(msg)) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}

fn main() {
    let cmd = "help";
    match var("SPOOL_CMD") {
        Result::Ok(c) => {
            if len(c) > 0 {
                cmd = c;
            }
        },
        Result::Err(_) => {},
    };

    if cmd == "help" || cmd == "--help" || cmd == "-h" {
        match write_all(stdout(), to_bytes("spool - Coil library dependency manager\n")) {
            Result::Ok(_) => 0,
            Result::Err(_) => 0,
        };
        match write_all(stdout(), to_bytes("Usage:\n  spool install\n  spool add <name> --git <url> [--version <req>]\n  spool add <name> --path <path>\n  spool update [name]\n  spool help\n")) {
            Result::Ok(_) => 0,
            Result::Err(_) => 0,
        };
        return;
    }

    let root = "";
    match var("SPOOL_PROJECT") {
        Result::Ok(p) => {
            if len(p) > 0 {
                root = p;
            }
        },
        Result::Err(_) => {},
    };
    if len(root) == 0 {
        match cwd() {
            Result::Ok(c) => {
                root = c;
            },
            Result::Err(_) => {
                match write_all(stdout(), to_bytes("spool failed: cwd\n")) {
                    Result::Ok(_) => 0,
                    Result::Err(_) => 0,
                };
                return;
            },
        };
    }

    if cmd == "plan" {
        match run_plan(root) {
            Result::Ok(_) => {
                match write_all(stdout(), to_bytes("spool plan: ok\n")) {
                    Result::Ok(_) => 0,
                    Result::Err(_) => 0,
                };
            },
            Result::Err(e) => {
                match write_all(stdout(), to_bytes(format("spool plan failed: %s\n", e))) {
                    Result::Ok(_) => 0,
                    Result::Err(_) => 0,
                };
            },
        };
        return;
    }

    if cmd == "link" {
        match run_link(root) {
            Result::Ok(_) => {
                match write_all(stdout(), to_bytes("spool link: ok\n")) {
                    Result::Ok(_) => 0,
                    Result::Err(_) => 0,
                };
            },
            Result::Err(e) => {
                match write_all(stdout(), to_bytes(format("spool link failed: %s\n", e))) {
                    Result::Ok(_) => 0,
                    Result::Err(_) => 0,
                };
            },
        };
        return;
    }

    if cmd == "add_manifest" {
        match run_add_manifest(
            root,
            env_or_empty("SPOOL_ADD_NAME"),
            env_or_empty("SPOOL_ADD_GIT"),
            env_or_empty("SPOOL_ADD_PATH"),
            env_or_empty("SPOOL_ADD_VERSION"),
        ) {
            Result::Ok(_) => {
                finish_ok(root, "spool add_manifest: ok\n");
            },
            Result::Err(e) => {
                finish_err(root, format("spool add_manifest failed: %s\n", e));
            },
        };
        return;
    }

    if cmd == "pick" {
        match run_pick(root, env_or_empty("SPOOL_ADD_NAME")) {
            Result::Ok(_) => {
                finish_ok(root, "spool pick: ok\n");
            },
            Result::Err(e) => {
                finish_err(root, format("spool pick failed: %s\n", e));
            },
        };
        return;
    }

    if cmd == "apply_resolved" {
        match run_apply_resolved(root) {
            Result::Ok(_) => {
                finish_ok(root, "spool apply_resolved: ok\n");
            },
            Result::Err(e) => {
                finish_err(root, format("spool apply_resolved failed: %s\n", e));
            },
        };
        return;
    }

    if cmd == "list_git_deps" {
        match run_list_git_deps(root) {
            Result::Ok(_) => {
                finish_ok(root, "spool list_git_deps: ok\n");
            },
            Result::Err(e) => {
                finish_err(root, format("spool list_git_deps failed: %s\n", e));
            },
        };
        return;
    }

    if cmd == "collect" {
        match run_collect(root) {
            Result::Ok(_) => {
                finish_ok(root, "spool collect: ok\n");
            },
            Result::Err(e) => {
                finish_err(root, format("spool collect failed: %s\n", e));
            },
        };
        return;
    }

    if cmd == "check_install" {
        match run_check_install(root) {
            Result::Ok(_) => {
                finish_ok(root, "spool check_install: ok\n");
            },
            Result::Err(e) => {
                finish_err(root, format("spool check_install failed: %s\n", e));
            },
        };
        return;
    }

    match write_all(stdout(), to_bytes(format("unknown command: %s\n", cmd))) {
        Result::Ok(_) => 0,
        Result::Err(_) => 0,
    };
}
