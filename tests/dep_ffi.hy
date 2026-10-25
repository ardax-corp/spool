// spool#38 / coil-tls#17: a dependency's own `[ffi] search_paths` and
// `[[ffi.native]]` rows resolve against that dependency's checkout, not the
// consumer (`.spool/deps/<name>` links to the checkout's src/, so a consumer
// path like `./.spool/deps/tls/native` never exists).
use tests::assert;
use roots::{link_all, dep_checkouts};
use toolchain::{dep_ffi_search_paths, grant_flags, package_native_flags, ffi_native_flags};
use util::{join2, ensure_dir, vec_has};
use env::cwd;
use io::file::write_text;
use text::{Joined, Searchable};

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

fn index_of(Vec<string> xs, string x) -> int {
    let i = 0;
    while i < xs.len() {
        if xs[i] == x {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

/// Fixture under scratch/<tag>: `nat` (src/ layout, native/libnat.so, its own
/// `./native` search path and `[[ffi.native]]`), `mid` (no src/, a consumer-style
/// `./.spool/deps/nat/native` path like coil-http's) and `proj` linking both.
fn fixture(string tag, string proj_toml) -> Result<string, string> {
    let base = join2(here()?, "scratch/" + tag);
    ensure_dir(join2(base, "nat/src"))?;
    ensure_dir(join2(base, "nat/native"))?;
    ensure_dir(join2(base, "mid"))?;
    ensure_dir(join2(base, "proj/src"))?;
    ensure_dir(join2(base, "proj/vendor"))?;
    write_file(join2(base, "nat/src/nat.hy"), "fn one() -> int { return 1; }\n")?;
    write_file(join2(base, "nat/native/libnat.so"), "not really a library\n")?;
    write_file(
        join2(base, "nat/coil.toml"),
        "[package]\nname = \"nat\"\nversion = \"0.1.0\"\n\n[ffi]\nsearch_paths = [\"./native\", \"./missing\", \"../escape\", \"/abs/native\"]\n\n[[ffi.native]]\nname = \"nat\"\nversion = \"0.1.0\"\npath = \"./native\"\n\n[[ffi.native]]\nname = \"outside\"\nversion = \"0.1.0\"\npath = \"../elsewhere\"\n",
    )?;
    write_file(join2(base, "mid/mid.hy"), "fn two() -> int { return 2; }\n")?;
    write_file(
        join2(base, "mid/coil.toml"),
        "[package]\nname = \"mid\"\nversion = \"0.1.0\"\n\n[ffi]\nsearch_paths = [\"./.spool/deps/nat/native\"]\n",
    )?;
    let proj = join2(base, "proj");
    write_file(join2(proj, "coil.toml"), proj_toml)?;
    let rows: Vec<string> = Vec::new();
    rows.push("mid\t" + join2(base, "mid"));
    rows.push("nat\t" + join2(base, "nat"));
    link_all(proj, rows)?;
    return base;
}

fn plain_proj() -> string {
    return "[package]\nname = \"proj\"\nversion = \"0.0.1\"\n";
}

test("dep_checkouts maps each link back to its checkout") {
    let base = fixture("depffi_checkouts", plain_proj())?;
    let rows = dep_checkouts(join2(base, "proj"));
    // .spool/deps/nat -> nat/src, so the checkout is its parent; mid has no
    // src/ and is linked as itself.
    assert!(vec_has(rows, "mid\t" + join2(base, "mid")));
    assert!(vec_has(rows, "nat\t" + join2(base, "nat")));
    assert!(rows.len() == 2);
}

test("a dependency's search_paths resolve against its checkout") {
    let base = fixture("depffi_search", plain_proj())?;
    let paths = dep_ffi_search_paths(join2(base, "proj"));
    assert!(vec_has(paths, join2(base, "nat/native")));
    // Missing dirs, `..` escapes and absolute paths are not passed; neither is
    // mid's consumer-layout path (it does not exist inside mid's checkout).
    assert!(paths.len() == 1);
}

test("dependency search paths follow the project's own") {
    let toml = plain_proj() + "\n[ffi]\nsearch_paths = [\"./vendor\"]\nallow = [\"nat\"]\n";
    let base = fixture("depffi_grants", toml)?;
    let flags = grant_flags(join2(base, "proj"))?;
    let own = index_of(flags, join2(base, "proj/vendor"));
    let dep = index_of(flags, join2(base, "nat/native"));
    assert!(own > 0 && dep > 0);
    assert!(own < dep);
    assert!(flags[dep - 1] == "--ffi-search-path");
}

test("coil package gets each dependency's [[ffi.native]] rows") {
    let base = fixture("depffi_native", plain_proj())?;
    let proj = join2(base, "proj");
    let f = (package_native_flags(proj)?).join(" ");
    assert!(f.contains("--ffi-native name=nat,version=0.1.0,path=" + join2(base, "nat/native")));
    // A row whose path leaves the checkout is dropped.
    assert!(f.contains("outside") == false);
    // `spool download` / `coil natives dump` keep only the project's rows.
    let own = ffi_native_flags(proj)?;
    assert!(own.len() == 0);
}

test("the project's own [[ffi.native]] row wins over a dependency's") {
    let toml = plain_proj() + "\n[[ffi.native]]\nname = \"nat\"\npackage = \"my-nat\"\nversion = \"9.9.9\"\npath = \"./vendor\"\n";
    let base = fixture("depffi_own", toml)?;
    let f = (package_native_flags(join2(base, "proj"))?).join(" ");
    assert!(
        f.contains("name=nat,version=9.9.9,path=" + join2(base, "proj/vendor") + ",package=my-nat"),
    );
    assert!(f.contains("version=0.1.0") == false);
}

test("a dependency native is packaged from the dir its search order finds first") {
    // Existing consumers point their own [ffi] search_paths at a sibling build
    // (`../coil-tls/native`); coil finds that file first, so it is the one
    // packaged and pinned, even when the checkout has none.
    let toml = plain_proj() + "\n[ffi]\nsearch_paths = [\"./vendor\"]\n";
    let base = fixture("depffi_sibling", toml)?;
    let proj = join2(base, "proj");
    write_file(join2(proj, "vendor/libnat.so"), "sibling build\n")?;
    let f = (package_native_flags(proj)?).join(" ");
    assert!(f.contains("name=nat,version=0.1.0,path=" + join2(proj, "vendor")));
}
