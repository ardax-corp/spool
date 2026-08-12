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
