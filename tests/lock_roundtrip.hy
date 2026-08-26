use lock::{
    make_git_pkg, make_git_pkg_hook, lock_serialize, lock_serialize_full, lock_parse,
    lock_parse_allow, lock_pkg_name, lock_pkg_hash, lock_pkg_hook_path, lock_pkg_hook_hash,
    lock_hashes_match, lock_upsert,
};
use text::{contains};

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

test("lock_parse names corrupt files") {
    let r = lock_parse("not a lock\n");
    match r {
        Result::Ok(_) => {
            assert(false)?;
        },
        Result::Err(e) => {
            assert(contains(e, "corrupt coil.lock"))?;
        },
    };
}

test("lock round-trip keeps hook path and hash") {
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg_hook(
        "http",
        "https://x/y.git",
        "v1.0.0",
        "rev1",
        "tree1",
        "./hooks/include.sh",
        "hookabc",
    ));
    let text = lock_serialize(pkgs);
    assert(contains(text, "hook_path = './hooks/include.sh'"))?;
    assert(contains(text, "hook_hash = 'hookabc'"))?;
    let back = lock_parse(text)?;
    assert(len(back) == 1)?;
    assert(lock_pkg_hook_path(back[0]) == "./hooks/include.sh")?;
    assert(lock_pkg_hook_hash(back[0]) == "hookabc")?;
}

test("lock omits empty hook fields") {
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg("http", "https://x", "v1", "c", "h1"));
    let text = lock_serialize(pkgs);
    assert(contains(text, "hook_path") == false)?;
    assert(contains(text, "hook_hash") == false)?;
}

test("lock allow_include round-trip") {
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg("http", "https://x", "v1", "c", "h1"));
    let allow = Vec::new();
    allow.push("zeta");
    allow.push("http");
    let text = lock_serialize_full(pkgs, allow);
    assert(contains(text, "[hooks]"))?;
    assert(contains(text, "allow_include"))?;
    let names = lock_parse_allow(text)?;
    assert(len(names) == 2)?;
    assert(names[0] == "http")?;
    assert(names[1] == "zeta")?;
}

test("lock_upsert keeps hook fields when the new pin omits them") {
    let pkgs = Vec::new();
    pkgs.push(make_git_pkg_hook("http", "https://x", "v1", "c1", "h1", "./h.sh", "abc"));
    pkgs = lock_upsert(pkgs, make_git_pkg("http", "https://x", "v2", "c2", "h2"));
    assert(len(pkgs) == 1)?;
    assert(lock_pkg_hash(pkgs[0]) == "h2")?;
    assert(lock_pkg_hook_path(pkgs[0]) == "./h.sh")?;
    assert(lock_pkg_hook_hash(pkgs[0]) == "abc")?;
}
