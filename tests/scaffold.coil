use tests::assert;
use scaffold::{main_template, manifest_template};
use text::Searchable;

test("spool new main uses println(...)? like the tutorial (#50)") {
    let body = main_template("demo");
    assert!(body.contains("    println(\"hello from demo\")?;\n"));
    assert!(!body.contains("match"));
}

// There is no global stdlib: a new project declares it, following the tip
// until someone pins it.
test("spool new declares the stdlib as a dependency on latest") {
    let body = manifest_template("demo", false, "https://example.test/coil-stdlib.git");
    assert!(body.contains("[dependencies]\n"));
    assert!(body.contains("stdlib = { git = \"https://example.test/coil-stdlib.git\", version = \"latest\" }\n"));
}
