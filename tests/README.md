# cfctx tests

Uses [bats-core](https://github.com/bats-core/bats-core). Install via Homebrew:

```bash
brew install bats-core
```

Run all tests:

```bash
bats tests/
```

Tests spin up a disposable `CFCTX_ROOT` inside `$BATS_TMPDIR`, source
`cfctx.sh` into the test shell, exercise the function, and assert on
files created and env mutations.

Gotcha: because `bats` itself runs each test in a subshell, you cannot
directly inspect the parent shell's env after a `cfctx` call. Tests work
around this by sourcing `cfctx.sh` inside the test's own process and
inspecting `$CF_HOME` / `$OM_PASSWORD` / etc. in the same process.
