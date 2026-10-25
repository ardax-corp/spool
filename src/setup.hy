// `spool setup`: fetch a coil toolkit and the stdlib into ~/.coil (or
// $COIL_HOME), where spool looks for them. It is what
// `bootstrap.sh --install` does for coil and the stdlib, driven by the
// downloaded spool binary. The coil archive comes from a coil-lang GitHub
// release (`stable`, `edge` or a tag) and must match the release's
// SHA256SUMS; the stdlib is a shallow clone of coil-stdlib's default branch.
use term::eprintln;
use text::{Searchable, Text};
use string::format;
use util::{join2, ensure_dir, home_dir, lines_of, path_exists, trim_or};
use proc::{sh_capture, sh_run, scratch_file};
use toolchain::env_or;
use natives::{host_os, host_arch, sha256_of, curl_to};
use cli::{parse_args, opt, has, strs, strs2, strs3, no_strs, positionals};
use io::file::read_text;

fn say(string msg) {
    eprintln("spool: " + msg);
}

/// Target triple of the coil-lang release archives, or "" when there is no
/// build for this host (macOS on Intel, musl, Windows, anything else).
fn release_triple(string os, string arch, bool musl) -> string {
    if os == "linux" && !musl && (arch == "x86_64" || arch == "aarch64") {
        return arch + "-unknown-linux-gnu";
    }
    if os == "macos" && arch == "aarch64" {
        return "aarch64-apple-darwin";
    }
    return "";
}

/// A channel names a release tag in a URL; keep it to tag-safe characters.
fn valid_channel(string c) -> bool {
    if c.len() == 0 {
        return false;
    }
    let i = 0;
    while i < c.len() {
        let b = c[i];
        let ok = (b >= 97 as byte && b <= 122 as byte) ||
                 (b >= 65 as byte && b <= 90 as byte) ||
                 (b >= 48 as byte && b <= 57 as byte) ||
                 b == "." ||
                 b == "_" ||
                 b == "-";
        if !ok {
            return false;
        }
        i = i + 1;
    }
    return true;
}

/// Where the channel's release assets download from: `stable` is the latest
/// non-prerelease, anything else a tag (`edge` is the rolling snapshot).
fn release_base(string repo, string channel) -> string {
    if channel == "stable" {
        return repo + "/releases/latest/download";
    }
    return repo + "/releases/download/" + channel;
}

/// The sha256 `SHA256SUMS` lists for `file`, or "".
fn listed_sum(string sums, string file) -> string {
    for line in lines_of(sums) {
        let parts = trim_or(line).split(" ");
        if parts.len() >= 2 {
            let name = parts[parts.len() - 1];
            if name == file || name == "*" + file {
                return parts[0].to_lower();
            }
        }
    }
    return "";
}

fn coil_home() -> Result<string, string> {
    let h = env_or("COIL_HOME", "");
    if h.len() > 0 {
        return h;
    }
    return join2(home_dir()?, ".coil");
}

fn host_is_musl() -> bool {
    return match sh_capture("ldd --version 2>&1 | grep -qi musl && echo musl", no_strs()) {
        Result::Ok(res) => {
            let (code, body) = res;
            return trim_or(body) == "musl";
        },
        Result::Err(_) => false,
    };
}

/// Download `asset` from `base` into `tmp`, check it against the release's
/// SHA256SUMS, and unpack it as `home/bin`.
fn fetch_coil(
    string tmp,
    string home,
    string base,
    string asset,
    string channel,
) -> Result<int, string> {
    let archive = join2(tmp, asset);
    let sums = join2(tmp, "SHA256SUMS");
    say(format("downloading %s/%s", base, asset));
    match curl_to(archive, base + "/" + asset) {
        Result::Ok(_) => 0,
        Result::Err(e) => raise format(
            "%s (does the %s release have %s? `--channel edge` is the rolling snapshot)",
            e,
            channel,
            asset,
        ),
    }
    curl_to(sums, base + "/SHA256SUMS")?;
    let want = listed_sum(read_or_raise(sums)?, asset);
    if want.len() == 0 {
        raise format("the %s release's SHA256SUMS does not list %s", channel, asset);
    }
    let have = sha256_of(archive)?;
    if have != want {
        raise format("checksum mismatch for %s (want %s, got %s)", asset, want, have);
    }
    say("checksum ok");
    // Unpack next to bin/, then swap it in: a failed unpack leaves the old
    // toolkit. The helpers (coil-fmt, coil-test, ...) stay next to coil.
    let code = sh_run(
        "set -e; rm -rf \"$2/bin.new\"; mkdir -p \"$2/bin.new\"; tar -xzf \"$1\" -C \"$2/bin.new\" --strip-components=1; \"$2/bin.new/coil\" --version >/dev/null; rm -rf \"$2/bin\"; mv \"$2/bin.new\" \"$2/bin\"",
        strs2(archive, home),
    )?;
    if code != 0 {
        raise format("could not unpack %s into %s", asset, join2(home, "bin"));
    }
    return 0;
}

/// Download, verify and unpack `coil-<triple>.tar.gz` into `home/bin`.
fn install_coil(string home, string channel) -> Result<int, string> {
    let os = host_os();
    let arch = host_arch();
    let triple = release_triple(os, arch, os == "linux" && host_is_musl());
    if triple.len() == 0 {
        raise format(
            "no coil release is built for %s/%s; build from source with spool's bootstrap.sh",
            os,
            arch,
        );
    }
    let repo = env_or("COIL_LANG_URL", "https://github.com/ardax-corp/coil-lang");
    let base = release_base(repo, channel);
    let asset = "coil-" + triple + ".tar.gz";
    let tmp = scratch_file("setup")?;
    ensure_dir(tmp)?;
    let done = fetch_coil(tmp, home, base, asset, channel);
    sh_run("rm -rf \"$1\"", strs(tmp))?;
    done?;
    say("installed " + join2(home, "bin/coil"));
    return 0;
}

/// Shallow-clone coil-stdlib and put its `src` at `home/stdlib/src`.
fn install_stdlib(string home) -> Result<int, string> {
    let repo = env_or("COIL_STDLIB_REPO", "https://github.com/ardax-corp/coil-stdlib.git");
    let tmp = scratch_file("stdlib")?;
    say("fetching " + repo);
    let code = sh_run(
        "set -e; git clone -q --depth 1 \"$1\" \"$2\"; rm -rf \"$3/stdlib.new\"; mkdir -p \"$3/stdlib.new\"; cp -R \"$2/src\" \"$3/stdlib.new/src\"; rm -rf \"$3/stdlib\"; mv \"$3/stdlib.new\" \"$3/stdlib\"",
        strs3(repo, tmp, home),
    )?;
    sh_run("rm -rf \"$1\"", strs(tmp))?;
    if code != 0 {
        raise "could not fetch coil-stdlib from " + repo;
    }
    say("installed " + join2(home, "stdlib"));
    return 0;
}

fn read_or_raise(string p) -> Result<string, string> {
    return match read_text(p) {
        Result::Ok(s) => s,
        Result::Err(_) => raise "cannot read " + p,
    };
}

fn cmd_setup(Vec<string> rest) -> Result<int, string> {
    let p = parse_args(rest, strs("--channel"), strs2("--coil-only", "--stdlib-only"))?;
    if positionals(p).len() > 0 {
        raise "usage: spool setup [--channel stable|edge|TAG] [--coil-only | --stdlib-only]";
    }
    let channel = opt(p, "--channel");
    if channel.len() == 0 {
        channel = env_or("COIL_CHANNEL", "stable");
    }
    if !valid_channel(channel) {
        raise format("invalid channel `%s` (use stable, edge or a release tag)", channel);
    }
    let coil_only = has(p, "--coil-only");
    let stdlib_only = has(p, "--stdlib-only");
    if coil_only && stdlib_only {
        raise "--coil-only and --stdlib-only exclude each other";
    }
    let home = coil_home()?;
    ensure_dir(home)?;
    if !stdlib_only {
        install_coil(home, channel)?;
    }
    if !coil_only {
        install_stdlib(home)?;
    }
    let default_home = match home_dir() {
        Result::Ok(h) => join2(h, ".coil"),
        Result::Err(_) => "",
    };
    if home != default_home {
        // spool itself only looks in ~/.coil.
        say(
            format(
                "note: set COIL=%s and COIL_STDLIB_DIR=%s so spool finds them",
                join2(home, "bin/coil"),
                join2(home, "stdlib"),
            ),
        );
    } else if !stdlib_only &&
              !(":" + env_or("PATH", "") + ":").contains(":" + join2(home, "bin") + ":") {
        say(format("note: %s is not on PATH; spool still finds coil there", join2(home, "bin")));
    }
    say("done; `spool doctor` checks the result");
    return 0;
}
