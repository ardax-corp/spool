use cache_url::{url_cache_key, strip_scheme};

test("url_cache_key parses https github url") {
    let key = url_cache_key("https://github.com/acme/widgets.git")?;
    let (host, owner, repo) = key;
    assert(host == "github.com")?;
    assert(owner == "acme")?;
    assert(repo == "widgets")?;
}

test("url_cache_key parses ssh github url") {
    let key = url_cache_key("git@github.com:acme/widgets.git")?;
    let (host, owner, repo) = key;
    assert(host == "github.com")?;
    assert(owner == "acme")?;
    assert(repo == "widgets")?;
}

test("strip_scheme drops https prefix") {
    assert(strip_scheme("https://example.com/a/b") == "example.com/a/b")?;
}

test("url_cache_key uses last three segments for file urls") {
    let key = url_cache_key("file:///tmp/cache/github.com/acme/widgets.git")?;
    let (host, owner, repo) = key;
    assert(host == "github.com")?;
    assert(owner == "acme")?;
    assert(repo == "widgets")?;
}

test("url_cache_key keeps hosts that contain .git") {
    let key = url_cache_key("https://my.gitea.io/acme/widgets.git")?;
    let (host, owner, repo) = key;
    assert(host == "my.gitea.io")?;
    assert(owner == "acme")?;
    assert(repo == "widgets")?;
}

test("url_cache_key only strips a trailing .git") {
    let key = url_cache_key("https://github.com/acme/site.github.io.git/")?;
    let (host, owner, repo) = key;
    assert(host == "github.com")?;
    assert(repo == "site.github.io")?;
}

test("url_cache_key drops ssh:// user") {
    let key = url_cache_key("ssh://git@example.com/acme/widgets.git")?;
    let (host, owner, repo) = key;
    assert(host == "example.com")?;
    assert(owner == "acme")?;
    assert(repo == "widgets")?;
}
