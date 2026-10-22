// Compile-time grants (coil-lang#1809 step 14): the project's `[comptime]`
// grants and result cache become `--comptime-*` flags, and a dependency's own
// `[comptime]` grants apply, scoped to its modules, only after
// `spool allow-comptime`.
use tests::assert;
use roots::link_all;
use toolchain::{grant_flags, dep_top_modules};
use lock::lock_add_allow_comptime;
use util::{join2, ensure_dir, vec_has};
use env::cwd;
use io::file::write_text;
use text::{Searchable, join as text_join};

fn write_file(string path, string body) -> Result<int, string> {
    return match write_text(path, body) {
        Result::Ok(_) => 0,
        Result::Err(_) => raise "cannot write " + path,
    };
}

fn here() -> Result<string, string> {
    return match cwd() {
        Result::Ok(d) => d,
        Result::Err(_) => raise "no cwd",
    };
}

/// Fixture under scratch/<tag>: `gen` (src/gen.hy, src/gen/, src/util.hy, its
/// own `[comptime]` grants) and `proj` linking it.
fn fixture(string tag, string proj_toml) -> Result<string, string> {
    let base = join2(here()?, "scratch/" + tag);
    ensure_dir(join2(base, "gen/src/gen"))?;
    ensure_dir(join2(base, "proj/src"))?;
    write_file(join2(base, "gen/src/gen.hy"), "fn one() -> int { return 1; }\n")?;
    write_file(join2(base, "gen/src/gen/schema.hy"), "fn two() -> int { return 2; }\n")?;
    write_file(join2(base, "gen/src/util.hy"), "fn three() -> int { return 3; }\n")?;
    write_file(
        join2(base, "gen/coil.toml"),
        "[package]\nname = \"gen\"\nversion = \"0.1.0\"\n\n[comptime]\nread = [\"./schemas\"]\nenv = [\"GEN_TOKEN\"]\n",
    )?;
    let proj = join2(base, "proj");
    write_file(join2(proj, "coil.toml"), proj_toml)?;
    let rows: Vec<string> = Vec::new();
    rows.push("gen\t" + join2(base, "gen"));
    link_all(proj, rows)?;
    return base;
}

fn proj_toml() -> string {
    return "[package]\nname = \"proj\"\nversion = \"0.0.1\"\n\n[comptime]\nread = [\"data\"]\nenv = [\"CI\"]\nnet = [\"api.example.com:443\"]\n";
}

test("the project's grants and cache are flags") {
    let base = fixture("comptime_own", proj_toml())?;
    let proj = join2(base, "proj");
    let flags = text_join(grant_flags(proj)?, " ");
    assert!(flags.contains("--comptime-read " + join2(proj, "data")));
    assert!(flags.contains("--comptime-env CI"));
    assert!(flags.contains("--comptime-net api.example.com:443"));
    assert!(flags.contains("--comptime-cache " + join2(proj, ".comptime")));
    // Not allowed yet: the dependency's grants are not passed.
    assert!(flags.contains("GEN_TOKEN") == false);
}

test("an allowed dependency's grants are scoped to its modules") {
    let base = fixture("comptime_dep", proj_toml())?;
    let proj = join2(base, "proj");
    lock_add_allow_comptime(join2(proj, "coil.lock"), "gen")?;
    let flags = text_join(grant_flags(proj)?, " ");
    assert!(flags.contains("--comptime-env gen=GEN_TOKEN"));
    assert!(flags.contains("--comptime-env util=GEN_TOKEN"));
    assert!(flags.contains("--comptime-read gen=" + join2(base, "gen/schemas")));
    assert!(flags.contains("--comptime-env GEN_TOKEN") == false, "never unscoped");
}

test("a dependency's top-level modules are its files and directories") {
    let base = fixture("comptime_modules", proj_toml())?;
    let modules = dep_top_modules(join2(base, "gen"));
    assert!(vec_has(modules, "gen") && vec_has(modules, "util"));
    assert!(modules.len() == 2, "gen.hy and gen/ are one module");
}

test("[comptime] cache moves the result cache") {
    let toml = "[package]\nname = \"proj\"\nversion = \"0.0.1\"\n\n[comptime]\ncache = \"build/ct\"\n";
    let base = fixture("comptime_cache", toml)?;
    let proj = join2(base, "proj");
    let flags = text_join(grant_flags(proj)?, " ");
    assert!(flags.contains("--comptime-cache " + join2(proj, "build/ct")));
}
