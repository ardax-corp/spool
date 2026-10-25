use tests::assert;
use setup::{release_triple, valid_channel, release_base, listed_sum};

test("release triples exist only for the published builds") {
    assert!(release_triple("linux", "x86_64", false) == "x86_64-unknown-linux-gnu");
    assert!(release_triple("linux", "aarch64", false) == "aarch64-unknown-linux-gnu");
    assert!(release_triple("macos", "aarch64", false) == "aarch64-apple-darwin");
    assert!(release_triple("linux", "x86_64", true) == "");
    assert!(release_triple("macos", "x86_64", false) == "");
    assert!(release_triple("windows", "x86_64", false) == "");
    assert!(release_triple("linux", "riscv64", false) == "");
}

test("channels are tag-safe") {
    assert!(valid_channel("stable") && valid_channel("edge") && valid_channel("v0.2.0-rc_1"));
    assert!(!valid_channel(""));
    assert!(!valid_channel("../x"));
    assert!(!valid_channel("a b"));
    assert!(!valid_channel("v1;rm"));
}

test("stable is the latest release, anything else a tag") {
    let repo = "https://github.com/ardax-corp/coil-lang";
    assert!(release_base(repo, "stable") == repo + "/releases/latest/download");
    assert!(release_base(repo, "edge") == repo + "/releases/download/edge");
    assert!(release_base(repo, "v0.2.0") == repo + "/releases/download/v0.2.0");
}

test("SHA256SUMS lookup") {
    let sums = "aaaa  coil-x86_64-unknown-linux-gnu.tar.gz\nBBBB *coil-aarch64-apple-darwin.tar.gz\n";
    assert!(listed_sum(sums, "coil-x86_64-unknown-linux-gnu.tar.gz") == "aaaa");
    assert!(listed_sum(sums, "coil-aarch64-apple-darwin.tar.gz") == "bbbb");
    assert!(listed_sum(sums, "coil-aarch64-unknown-linux-gnu.tar.gz") == "");
    assert!(listed_sum(sums, "x86_64-unknown-linux-gnu.tar.gz") == "");
}
