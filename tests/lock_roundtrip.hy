use lock::{
    make_git_pkg, lock_serialize, lock_parse, lock_pkg_name, lock_pkg_hash, lock_hashes_match,
    lock_upsert,
};

test("lock round-trip preserves fields and sorts by name") {
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg("zeta", "https://z", "v0.1.0", "a", "ta"));
    pkgs.push(make_git_pkg("alpha", "https://a", "v1.2.3", "b", "tb"));
    let text = lock_serialize(pkgs);
    let back = lock_parse(text)?;
    assert(len(back) == 2)?;
    assert(lock_pkg_name(back[0]) == "alpha")?;
    assert(lock_pkg_name(back[1]) == "zeta")?;
    assert(lock_pkg_hash(back[0]) == "tb")?;
}

test("lock_hashes_match detects mismatch") {
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg("http", "https://x/y.git", "v1", "c", "h1"));
    let ok = Vec::new();
    ok.push(("http", "h1"));
    assert(lock_hashes_match(pkgs, ok))?;
    let bad = Vec::new();
    bad.push(("http", "h2"));
    assert(lock_hashes_match(pkgs, bad) == false)?;
}

test("lock_upsert replaces by name") {
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg("http", "https://x", "v1", "c1", "h1"));
    pkgs = lock_upsert(pkgs, make_git_pkg("http", "https://x", "v2", "c2", "h2"));
    assert(len(pkgs) == 1)?;
    assert(lock_pkg_hash(pkgs[0]) == "h2")?;
}
