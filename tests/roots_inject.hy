use roots::{inject_spool_root};
use text::{contains};

test("inject_spool_root extends existing roots line") {
    let body = "[module]
roots = ['./src']
";
    let out = inject_spool_root(body)?;
    assert(contains(out, "./.spool/deps"))?;
    assert(contains(out, "./src"))?;
}

test("inject_spool_root appends module when missing roots") {
    let body = "# empty project
";
    let out = inject_spool_root(body)?;
    assert(contains(out, "[module]"))?;
    assert(contains(out, "./.spool/deps"))?;
}
