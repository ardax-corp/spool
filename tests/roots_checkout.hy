use tests::assert;
use roots::{checkout_module_root, link_all};
use toolchain::{project_roots, project_stdlib};
use util::{join2, ensure_dir, vec_has};
use env::{cwd};
use io::file::{write_text};
use text::{Searchable};

test("checkout_module_root prefers src when present") {
    let root = checkout_module_root("examples/greet");
    assert!(root.ends_with("/src") || root.ends_with("src"));
}

test("checkout_module_root keeps checkout without src") {
    let root = checkout_module_root("examples");
    assert!(root == "examples");
}

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

// spool#30: a package that keeps its modules under src/<name>/ (coil-tls,
// coil-http) or has a second top-level module (coil-sdl's `simd`) resolves
// them through its own src/, so that src/ must be a --root of the consumer.
test("project_roots adds each linked package's module root") {
    let base = join2(here()?, "scratch/roots30");
    ensure_dir(join2(base, "nest/src/nest"))?;
    ensure_dir(join2(base, "one/src"))?;
    ensure_dir(join2(base, "proj/src"))?;
    write_file(join2(base, "nest/src/nest.hy"), "use nest::inner::{twice};\n")?;
    write_file(join2(base, "nest/src/nest/inner.hy"), "fn twice() -> int { return 2; }\n")?;
    write_file(join2(base, "one/src/one.hy"), "fn one() -> int { return 1; }\n")?;
    write_file(join2(base, "proj/coil.toml"), "[package]\nname = \"proj\"\nversion = \"0.0.1\"\n")?;
    let proj = join2(base, "proj");
    let rows: Vec<string> = Vec::new();
    rows.push("nest\t" + join2(base, "nest"));
    rows.push("one\t" + join2(base, "one"));
    link_all(proj, rows)?;
    let roots = project_roots(proj)?;
    // The link farm itself stays a root: `use one::{one}` (single-file) and
    // `use greet::hello` (modules directly in src/) resolve through it.
    assert!(vec_has(roots, join2(proj, ".spool/deps")));
    // `use nest::inner` needs <nest>/src as a root: its real path, so files
    // reached through the link farm keep their `<name>::module` names.
    assert!(vec_has(roots, join2(base, "nest/src")));
    assert!(vec_has(roots, join2(base, "one/src")));
    assert!(vec_has(roots, join2(proj, ".spool/deps/nest")) == false);
    // `.hy` file links are modules, not roots.
    assert!(vec_has(roots, join2(proj, ".spool/deps/one.hy")) == false);
}

fn index_of(Vec<string> v, string x) -> int {
    let i = 0;
    while i < v.len() {
        if v[i] == x {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

// There is no global stdlib: the one declared under [dependencies] is the
// project's stdlib, and its root comes before every other package root.
test("project_roots puts the stdlib dependency first") {
    let base = join2(here()?, "scratch/roots_stdlib_dep");
    ensure_dir(join2(base, "std/src/io"))?;
    ensure_dir(join2(base, "one/src"))?;
    ensure_dir(join2(base, "proj/src"))?;
    write_file(join2(base, "std/src/text.hy"), "fn t() -> int { return 0; }\n")?;
    write_file(join2(base, "std/src/io/file.hy"), "fn f() -> int { return 0; }\n")?;
    write_file(join2(base, "one/src/one.hy"), "fn one() -> int { return 1; }\n")?;
    write_file(join2(base, "proj/coil.toml"), "[package]\nname = \"proj\"\nversion = \"0.0.1\"\n")?;
    let proj = join2(base, "proj");
    let rows: Vec<string> = Vec::new();
    rows.push("one\t" + join2(base, "one"));
    rows.push("stdlib\t" + join2(base, "std"));
    link_all(proj, rows)?;
    let roots = project_roots(proj)?;
    assert!(project_stdlib(proj) == join2(base, "std/src"));
    // The stdlib right after .spool/deps, before every other package root.
    let deps_at = index_of(roots, join2(proj, ".spool/deps"));
    assert!(deps_at >= 0);
    assert!(roots[deps_at + 1] == join2(base, "std/src"));
    assert!(roots[deps_at + 2] == join2(base, "one/src"));
    assert!(roots.len() == deps_at + 3);
}

// Without a stdlib dependency there is no stdlib root at all, whatever
// COIL_STDLIB_DIR or ~/.coil/stdlib hold.
test("project_roots has no stdlib without a stdlib dependency") {
    let base = join2(here()?, "scratch/roots_no_stdlib");
    ensure_dir(join2(base, "one/src"))?;
    ensure_dir(join2(base, "proj/src"))?;
    write_file(join2(base, "one/src/one.hy"), "fn one() -> int { return 1; }\n")?;
    write_file(join2(base, "proj/coil.toml"), "[package]\nname = \"proj\"\nversion = \"0.0.1\"\n")?;
    let proj = join2(base, "proj");
    let rows: Vec<string> = Vec::new();
    rows.push("one\t" + join2(base, "one"));
    link_all(proj, rows)?;
    let roots = project_roots(proj)?;
    let deps_at = index_of(roots, join2(proj, ".spool/deps"));
    assert!(roots.len() == deps_at + 2);
    assert!(roots[deps_at + 1] == join2(base, "one/src"));
    assert!(project_stdlib(proj) == "");
}
