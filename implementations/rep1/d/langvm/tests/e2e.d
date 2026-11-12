/// End-to-end tests: whole Vellum programs run through the library.
module e2e;

import std.array : appender;
import std.conv : to;
import std.string : join;

import langvm;
import cases;

/// Run `source` and compare everything it prints with `expected`.
private string mismatch(const Case c)
{
    const got = interpretToString(c.source);
    if (got == c.expected)
        return null;
    return "case \"" ~ c.name ~ "\"\n  expected: " ~ c.expected.to!string ~ "\n  got:      " ~ got;
}

private void runAll(const Case[] list)
{
    string[] failures;
    foreach (c; list)
        if (auto m = mismatch(c))
            failures ~= m;
    assert(failures.length == 0, "\n" ~ failures.join("\n"));
}

/// The worked examples of SPEC.md section 17 print exactly what the spec says.
unittest
{
    runAll(specExamples);
}

/// Language rules, standard library behaviour, run-time panics and one case
/// per error kind.
unittest
{
    runAll(ruleCases);
}

/// The library API: compile once, run with a custom sink.
unittest
{
    auto p = compile("@module main\nfn main() { emit(\"a\"); emit(\"b\"); print(\"c\"); }\n");
    auto buf = appender!string();
    execute(p, (const(char)[] s) { buf.put(s); });
    assert(buf.data == "abc\n");
}

/// Compile errors carry a kind and a module-local position.
unittest
{
    try
    {
        compile("@module main\nfn main() {\n    let n: Int = 1;\n    print(n + \"x\");\n}\n");
        assert(false, "expected a compile error");
    }
    catch (CompileError e)
    {
        assert(e.kind == Kind.typeMismatch);
        assert(e.pos == Pos(3, 15));
        assert(e.diagnostic == "error: type-mismatch at 3:15");
    }
}

/// A panic keeps the output printed before it and appends one line.
unittest
{
    assert(interpretToString("@module main\nfn main() { emit(\"a\"); panic(\"boom\"); }\n")
            == "apanic: boom\n");
}

/// Deep Vellum recursion runs in the VM's own frames, not on the host stack.
unittest
{
    enum src = q"VELLUM
@module main
fn depth(n: Int) -> Int { if n == 0 { 0 } else { 1 + depth(n - 1) } }
fn main() {
    print(showInt(depth(19998)));
    print(showInt(depth(19999)));
}
VELLUM";
    assert(interpretToString(src) == "19998\npanic: call stack overflow\n");
}
