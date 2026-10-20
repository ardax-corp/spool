use tests::assert;
use roots::{checkout_module_root, link_all};
use toolchain::{project_roots};
use util::{join2, ensure_dir, vec_has};
use env::{cwd};
use io::file::{write_text};
use text::{ends_with};

test("checkout_module_root prefers src when present") {
    let root = checkout_module_root("examples/greet");
    assert!(ends_with(root, "/src") || ends_with(root, "src"));
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
    // `use nest::inner` needs <nest>/src as a root.
    assert!(vec_has(roots, join2(proj, ".spool/deps/nest")));
    assert!(vec_has(roots, join2(proj, ".spool/deps/one")));
    // `.hy` file links are modules, not roots.
    assert!(vec_has(roots, join2(proj, ".spool/deps/one.hy")) == false);
}
