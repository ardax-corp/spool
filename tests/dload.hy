use toolchain::{dload_flags, dload_stem, is_sha256_hex, ffi_native_specs};
use lock::{lock_parse, lock_native_parse, lock_native_pkg, lock_native_stem, lock_native_sha};
use manifest::{ffi_natives_parse, native_package, native_url, native_requires};
use text::{contains, join as text_join, repeat};

fn sha(string c) -> string {
    return repeat(c, 64);
}

fn lock_row(string name) -> string {
    return "[[package]]\nname = '" + name + "'\ngit = 'https://example.com/" + name + "'\ntag = 'v0.1.0'\nrev = 'abc'\ncontent_hash = 'ddd'\n";
}

fn flags_of(string manifest, string lock) -> Result<string, string> {
    return text_join(dload_flags(manifest, lock)?, " ");
}

test("dload stem strips coil- unless the lock names one") {
    assert(dload_stem("coil-tls", "") == "tls")?;
    assert(dload_stem("regex", "") == "regex")?;
    assert(dload_stem("coil-crypto", "hycrypto") == "hycrypto")?;
    assert(is_sha256_hex(sha("a")))?;
    assert(is_sha256_hex(sha("F")))?;
    assert(is_sha256_hex("abc") == false)?;
    assert(is_sha256_hex(sha("g")) == false)?;
}

test("trusted coil-prefixed dep maps to the stripped stem") {
    let manifest = "[dependencies]\ncoil-foo = { git = \"https://example.com/coil-foo.git\", version = \"^0.1\", trusted = true }\nbar = { git = \"https://example.com/bar.git\", version = \"^0.1\" }\n";
    let f = flags_of(manifest, "")?;
    assert(contains(f, "--dload-trusted foo"))?;
    assert(contains(f, "--dload-trusted coil-foo"))?;
    assert(contains(f, "bar") == false)?;
    assert(contains(f, "--dload-pin") == false)?;
}

test("lock native stem is pinned and trusted") {
    let manifest = "[dependencies]\ncoil-crypto = { git = \"https://example.com/coil-crypto.git\", version = \"^0.1\", trusted = true }\n";
    let lock = lock_row("coil-crypto") + "\n[[package.native]]\nstem = 'hycrypto'\nsha256 = '" + sha("a") + "'\n\n" + lock_row("coil-tls") + "\n[[package.native]]\nsha256 = '" + sha("b") + "'\n";
    // spool's own lock reader still accepts the native rows.
    assert(len(lock_parse(lock)?) == 2)?;
    let natives = lock_native_parse(lock);
    assert(len(natives) == 2)?;
    assert(lock_native_pkg(natives[0]) == "coil-crypto")?;
    assert(lock_native_stem(natives[0]) == "hycrypto")?;
    assert(lock_native_sha(natives[1]) == sha("b"))?;
    let f = flags_of(manifest, lock)?;
    assert(contains(f, "--dload-pin hycrypto=" + sha("a")))?;
    assert(contains(f, "--dload-pin tls=" + sha("b")))?;
    assert(contains(f, "--dload-trusted hycrypto"))?;
    assert(contains(f, "--dload-trusted crypto"))?;
}

test("trusted dep takes its lock native stem even without a sha256") {
    let manifest = "[dependencies]\ncoil-http = { git = \"https://example.com/http.git\", version = \"^1\", trusted = true }\n";
    let lock = lock_row("coil-http") + "\n[[package.native]]\nstem = 'plugin'\n";
    let f = flags_of(manifest, lock)?;
    assert(f == "--dload-trusted coil-http --dload-trusted http --dload-trusted plugin")?;
}

test("trusted coil-crypto bootstraps the crypto stem") {
    let manifest = "[dependencies]\ncoil-crypto = { git = \"https://example.com/coil-crypto.git\", version = \"^0.1\", trusted = true }\n";
    let f = flags_of(manifest, "")?;
    assert(contains(f, "--dload-trusted crypto"))?;
}

test("pins with a malformed sha256 are skipped") {
    let lock = lock_row("coil-tls") + "\n[[package.native]]\nsha256 = 'abc123'\n\n" + lock_row("regex") + "\n[[package.native]]\nlib = 'pcre'\nsha256 = '" + sha("z") + "'\n";
    let f = flags_of("[package]\nname = \"app\"\n", lock)?;
    assert(len(f) == 0)?;
}

test("trusted must be a bool") {
    let manifest = "[dependencies]\nfoo = { git = \"https://example.com/foo.git\", version = \"^0.1\", trusted = \"yes\" }\n";
    match dload_flags(manifest, "") {
        Result::Ok(_) => {
            assert(false)?;
        },
        Result::Err(e) => {
            assert(contains(e, "trusted must be a bool"))?;
        },
    };
}

test("ffi.native rows become --ffi-native specs") {
    let manifest = "[[ffi.native]]\nname = \"re\"\npackage = \"coil-regex\"\nversion = \"1.2.0\"\npath = \"native\"\nurl = \"https://example.com/libre.so\"\nrequires = [\"libpcre2.so\", \"libz.so\"]\nrequires_hint = \"apt install pcre2, zlib\"\n\n[[ffi.native]]\nname = \"sum\"\nversion = \"0.1.0\"\npath = \"/opt/sum\"\n";
    let rows = ffi_natives_parse(manifest)?;
    assert(len(rows) == 2)?;
    assert(native_package(rows[1]) == "sum")?;
    assert(native_url(rows[0]) == "https://example.com/libre.so")?;
    assert(native_requires(rows[0]) == "libpcre2.so;libz.so")?;
    let specs = ffi_native_specs("/proj", manifest)?;
    assert(specs[0] == "name=re,version=1.2.0,path=/proj/native,package=coil-regex,requires=libpcre2.so;libz.so,requires-hint=apt install pcre2\\, zlib")?;
    assert(specs[1] == "name=sum,version=0.1.0,path=/opt/sum")?;
}

test("ffi.native unknown and missing keys are errors") {
    match ffi_natives_parse("[[ffi.native]]\nname = \"re\"\nversion = \"1\"\npath = \"n\"\ncolour = \"red\"\n") {
        Result::Ok(_) => {
            assert(false)?;
        },
        Result::Err(e) => {
            assert(contains(e, "unknown key ffi.native.colour"))?;
        },
    };
    match ffi_natives_parse("[[ffi.native]]\nname = \"re\"\nversion = \"1\"\n") {
        Result::Ok(_) => {
            assert(false)?;
        },
        Result::Err(e) => {
            assert(contains(e, "path"))?;
        },
    };
}
