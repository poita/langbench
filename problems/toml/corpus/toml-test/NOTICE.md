# toml-test corpus

`valid/` and `invalid/` hold the files of the official TOML test suite,
github.com/toml-lang/toml-test, fetched 2026-09-21 and restricted to the
cases listed in `files-toml-1.0.0` (the TOML 1.0.0 subset). They are
unmodified. The suite is MIT licensed; see `LICENSE`.

`gen_tests.py` turns each `valid/**/*.toml` into a decode test whose expected
output is checked against the suite's matching `.json` file, and each
`invalid/**/*.toml` into a decode test that must print `error`.
