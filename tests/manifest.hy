use tests::assert;
use manifest::{
    deps_parse, dep_kind, dep_name, dep_git, dep_version, dep_path, deps_insert_line,
    make_git_dep, format_dep_line, deps_has_name, package_name_parse, package_coil_parse,
    package_include_parse, scripts_parse, scripts_path_of, script_rel_ok, dep_rev, dep_req,
    deps_remove_line, manifest_validate, ffi_natives_parse, native_sha256, native_url,
};
use text::{Searchable};

test("parse git dependency inline table") {
    let body = "[dependencies]
http = { git = \"https://github.com/a/b.git\", version = \"^0.2\" }
";
    let deps = deps_parse(body)?;
    assert!(deps.len() == 1);
    assert!(dep_kind(deps[0]) == "g");
    assert!(dep_name(deps[0]) == "http");
    assert!(dep_git(deps[0]) == "https://github.com/a/b.git");
    assert!(dep_version(deps[0]) == "^0.2");
}

test("parse path dependency") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"

[dependencies]
local_http = { path = \"../local-http\" }
";
    let deps = deps_parse(body)?;
    assert!(deps.len() == 1);
    assert!(dep_kind(deps[0]) == "p");
    assert!(dep_name(deps[0]) == "local_http");
    assert!(dep_path(deps[0]) == "../local-http");
}

test("insert creates dependencies section") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
";
    let line = format_dep_line(make_git_dep("http", "https://x/y.git", "^1.0"))?;
    let out = deps_insert_line(body, line)?;
    assert!(out.contains("[dependencies]"));
    assert!(out.contains("http = { git = \"https://x/y.git\", version = \"^1.0\" }"));
}

test("deps_has_name finds existing") {
    let body = "[dependencies]
http = { git = \"https://x\", version = \"*\" }
";
    let deps = deps_parse(body)?;
    assert!(deps_has_name(deps, "http"));
    assert!(deps_has_name(deps, "missing") == false);
}

test("package_name_parse reads [package] name") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
";
    assert!(package_name_parse(body) == "app");
}

test("package_coil_parse reads engine range") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
coil = \">=0.1.0\"
";
    assert!(package_coil_parse(body) == ">=0.1.0");
}

test("package_coil_parse omitted is empty") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
";
    assert!(package_coil_parse(body) == "");
}

test("package_coil_parse ignores include and scripts") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
coil = \">=0.1.0\"
include = \"./hooks/include.sh\"

[scripts]
preinstall = \"./hooks/preinstall.sh\"
";
    assert!(package_coil_parse(body) == ">=0.1.0");
}

test("package_include_parse reads include-hook path") {
    let body = "[package]
name = \"http\"
version = \"0.1.0\"
include = \"./hooks/include.sh\"
";
    assert!(package_include_parse(body) == "./hooks/include.sh");
}

test("package_include_parse omitted is empty") {
    let body = "[package]
name = \"http\"
version = \"0.1.0\"
";
    assert!(package_include_parse(body) == "");
}

test("include-hook path is read without a [hooks] table") {
    let body = "[package]
name = \"http\"
version = \"0.1.0\"
include = \"./hooks/include.sh\"

[module]
roots = [\"./src\"]
";
    assert!(body.contains("[hooks]") == false);
    assert!(package_include_parse(body) == "./hooks/include.sh");
}

test("scripts_parse reads current-project lifecycle paths") {
    let body = "[package]
name = \"app\"
version = \"0.0.1\"

[scripts]
pre_install = \"./scripts/pre-install.sh\"
post_install = \"./scripts/post-install.sh\"
pre_update = \"./scripts/pre-update.sh\"
post_update = \"./scripts/post-update.sh\"
";
    let recs = scripts_parse(body)?;
    assert!(scripts_path_of(recs, "pre_install") == "./scripts/pre-install.sh");
    assert!(scripts_path_of(recs, "post_install") == "./scripts/post-install.sh");
    assert!(scripts_path_of(recs, "pre_update") == "./scripts/pre-update.sh");
    assert!(scripts_path_of(recs, "post_update") == "./scripts/post-update.sh");
}

test("scripts_parse missing keys are omitted") {
    let body = "[scripts]
pre_install = \"./scripts/pre-install.sh\"
";
    let recs = scripts_parse(body)?;
    assert!(recs.len() == 1);
    assert!(scripts_path_of(recs, "post_install") == "");
}

test("scripts_parse unknown key hard-errors") {
    let r = scripts_parse("[scripts]
preinstall = \"./hooks/preinstall.sh\"
");
    match r {
        Result::Ok(_) => {
            assert!(false);
        },
        Result::Err(e) => {
            assert!(e.contains("unknown scripts key"));
        },
    };
}

test("script paths stay in the project tree") {
    assert!(script_rel_ok("./scripts/pre-install.sh"));
    assert!(script_rel_ok("../evil.sh") == false);
    assert!(script_rel_ok("/tmp/x.sh") == false);
}

test("deps_insert_line keeps entries together and ends with a newline") {
    let body = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\na = { path = \"../a\" }\n\n";
    let out = deps_insert_line(body, "b = { path = \"../b\" }")?;
    assert!(out.contains("a = { path = \"../a\" }\nb = { path = \"../b\" }\n"));
    let deps = deps_parse(out)?;
    assert!(deps.len() == 2);
}

test("deps_insert_line output without trailing newline still decodes") {
    let body = "[package]\nname = \"app\"\nversion = \"0.1.0\"";
    let out = deps_insert_line(body, "b = { path = \"../b\" }")?;
    let deps = deps_parse(out)?;
    assert!(deps.len() == 1);
}

test("git deps accept rev pins and trusted") {
    let body = "[dependencies]\ntoml = { git = \"https://example.com/a/toml.git\", rev = \"main\", trusted = true }\n";
    let deps = deps_parse(body)?;
    assert!(dep_rev(deps[0]) == "main");
    assert!(dep_req(deps[0]) == "@main");
}

test("deps_remove_line drops only the named entry") {
    let body = "[dependencies]\nab = { path = \"../ab\" }\na = { path = \"../a\" }\n";
    let out = deps_remove_line(body, "a")?;
    let deps = deps_parse(out)?;
    assert!(deps.len() == 1);
    assert!(dep_name(deps[0]) == "ab");
}

fn validate_err(string body) -> string {
    return match manifest_validate(body) {
        Result::Ok(_) => "",
        Result::Err(e) => e,
    };
}

test("manifest_validate accepts every known section and key") {
    let body = "[package]
name = \"app\"
version = \"0.1.0\"
coil = \">=0.1.0\"
include = \"./hooks/include.sh\"

[module]
roots = [\"./src\"]

[entry]
file = \"./src/main.hy\"

[permissions]
read = true
all = false

[env]
allow_exec = true
allow_exit = true
allow_ffi_exec = false

[ffi]
search_paths = [\"./native\"]
allow = [\"plugin\"]
allow_attach = true

[[ffi.native]]
name = \"regex\"
version = \"0.3.0\"
path = \"./native\"

[scripts]
pre_install = \"./scripts/pre.sh\"

[dependencies]
http = { git = \"https://x/http.git\", version = \"^0.2\", trusted = true }
";
    assert!(validate_err(body) == "");
    assert!(validate_err("") == "");
}

test("manifest_validate rejects unknown sections and keys") {
    assert!(validate_err("[permisions]
read = true
").contains("unknown section [permisions]"));
    assert!(validate_err("[env]
allow_exce = true
").contains("unknown key env.allow_exce"));
    assert!(validate_err("[package]
name = \"a\"
version = \"1\"
authors = [\"x\"]
").contains("unknown key package.authors"));
    assert!(validate_err("[module]
preludes = []
").contains("unknown key module.preludes"));
    assert!(validate_err("name = \"a\"
").contains("unknown key name"));
    assert!(validate_err("[scripts]
pre_build = \"./x.sh\"
").contains("unknown scripts key"));
    assert!(validate_err("[[ffi.native]]
name = \"r\"
version = \"1\"
path = \".\"
url2 = \"x\"
").contains("unknown key ffi.native.url2"));
}

test("[[ffi.native]] sha256 is optional, checked and stored lowercase (coil-lang#1657)") {
    let row = "[[ffi.native]]
name = \"r\"
version = \"1\"
path = \".\"
url = \"https://x/libr.so\"
";
    let rows = ffi_natives_parse(row)?;
    assert!(native_sha256(rows[0]) == "");
    assert!(native_url(rows[0]) == "https://x/libr.so");
    let hex = "4FF52DF5D95227DB32FDE1C372FC45EC07F2D939937B8E8F5971223037023A67";
    rows = ffi_natives_parse(row + "sha256 = \"" + hex + "\"\n")?;
    assert!(native_sha256(rows[0]) == "4ff52df5d95227db32fde1c372fc45ec07f2d939937b8e8f5971223037023a67");
    assert!(validate_err(row + "sha256 = \"" + hex + "\"\n") == "");
    assert!(validate_err(row + "sha256 = \"abc\"\n").contains("sha256 must be 64 hex digits"));
    assert!(validate_err(row + "sha256 = \"" + "0g" + "2df5d95227db32fde1c372fc45ec07f2d939937b8e8f5971223037023a67" + "\"\n").contains("sha256 must be 64 hex digits"));
}

test("version = latest parses as a latest requirement (#32)") {
    let body = "[dependencies]
msgpack = { git = \"https://x/msgpack.git\", version = \"latest\" }
";
    let deps = deps_parse(body)?;
    assert!(deps.len() == 1);
    assert!(dep_version(deps[0]) == "latest");
    assert!(dep_rev(deps[0]) == "");
    assert!(dep_req(deps[0]) == "latest");
}

test("version = latest cannot be combined with rev (#32)") {
    let body = "[dependencies]
msgpack = { git = \"https://x/msgpack.git\", version = \"latest\", rev = \"main\" }
";
    match deps_parse(body) {
        Result::Ok(_) => {
            assert!(false);
        },
        Result::Err(e) => {
            assert!(e.contains("msgpack"));
            assert!(e.contains("latest"));
            assert!(e.contains("rev"));
        },
    };
}

test("version other than latest cannot be combined with rev (#40)") {
    let body = "[dependencies]
foo = { git = \"https://example/foo.git\", version = \"^1.0\", rev = \"main\" }
";
    match deps_parse(body) {
        Result::Ok(_) => {
            assert!(false);
        },
        Result::Err(e) => {
            assert!(e.contains("foo"));
            assert!(e.contains("version"));
            assert!(e.contains("rev"));
        },
    };
}

test("format_dep_line writes version = latest (#32)") {
    let line = format_dep_line(make_git_dep("msgpack", "https://x/msgpack.git", "latest"))?;
    assert!(line == "msgpack = { git = \"https://x/msgpack.git\", version = \"latest\" }");
}
