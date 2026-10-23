use tests::assert;
use scaffold::main_template;
use text::Searchable;

test("spool new main uses println(...)? like the tutorial (#50)") {
    let body = main_template("demo");
    assert!(body.contains("    println(\"hello from demo\")?;\n"));
    assert!(!body.contains("match"));
}
