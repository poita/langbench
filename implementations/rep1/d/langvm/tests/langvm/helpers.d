/// Shared helpers for the unit tests.
module langvm.helpers;

import core.exception : AssertError;
import langvm;

/// Runs a single-module program given only the module body.
string runMain(string body_)
{
    return runSource("@module main\n" ~ body_ ~ "\n").stdout;
}

/// Runs a program that consists of the body of `fn main() { ... }` only.
string runBody(string stmts)
{
    return runMain("fn main() {\n" ~ stmts ~ "\n}");
}

/// Expects the run of `body_` to produce exactly `expected` (a diagnostic line, output, ...).
void expectMain(string body_, string expected, string file = __FILE__, size_t line = __LINE__)
{
    auto got = runMain(body_);
    if (got != expected)
        throw new AssertError("\nprogram:\n" ~ body_ ~ "\nexpected: " ~ expected ~ "\n     got: " ~ got, file, line);
}

/// Expects `fn main() { stmts }` to produce exactly `expected`.
void expectBody(string stmts, string expected, string file = __FILE__, size_t line = __LINE__)
{
    auto got = runBody(stmts);
    if (got != expected)
        throw new AssertError("\nbody:\n" ~ stmts ~ "\nexpected: " ~ expected ~ "\n     got: " ~ got, file, line);
}
