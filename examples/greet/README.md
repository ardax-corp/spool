# greet

Demo Coil library for [spool](https://github.com/ardax-corp/spool). Function-style on purpose, to keep the demo small.

## Layout

```text
coil.toml
src/hello.coil    # use greet::hello
```

`spool` links `.spool/deps/greet` at this package's `src/` directory so `use greet::hello` resolves to `hello.coil`.

## Consume

```toml
[dependencies]
greet = { git = "https://github.com/ardax-corp/coil-greet.git", version = "^0.1" }
```

```bash
spool add greet --git https://github.com/ardax-corp/coil-greet.git --version '^0.1'
# or: spool add greet --path /path/to/coil-greet
```

```coil
use greet::hello;
```
