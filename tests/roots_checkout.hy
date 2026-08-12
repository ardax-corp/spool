use roots::{checkout_module_root};
use text::{ends_with};

test("checkout_module_root prefers src when present") {
    let root = checkout_module_root("examples/greet");
    assert(ends_with(root, "/src") || ends_with(root, "src"))?;
}

test("checkout_module_root keeps checkout without src") {
    let root = checkout_module_root("examples");
    assert(root == "examples")?;
}
