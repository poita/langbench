/// Unit tests for depresolve.resolver, depresolve.output and resolveText.
module test_resolver;

import std.array : appender, replicate;
import std.conv : to;
import depresolve;

@safe unittest // spec example 1: diamond that needs backtracking
{
    assert(resolveText("a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\n"
            ~ "root: a *, b *\n") == "a 1.0.0\nb 1.0.0\nc 1.2.5\n");
}

@safe unittest // spec example 2: first solution, not the newest set
{
    assert(resolveText("a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\n"
            ~ "root: a *, b *\n") == "a 2.0.0\nb 1.0.5\n");
}

@safe unittest // spec example 3: conflicting majors
{
    assert(resolveText("a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n"
            ~ "root: a *, b *\n") == "unsatisfiable\n");
}

@safe unittest // spec example 4: requirement order matters
{
    enum reg = "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\n"
        ~ "c 1.0.0:\nc 2.0.0:\n";
    assert(resolveText(reg ~ "root: a *, b *\n") == "a 2.0.0\nb 1.0.0\nc 2.0.0\n");
    assert(resolveText(reg ~ "root: b *, a *\n") == "a 1.0.0\nb 2.0.0\nc 1.0.0\n");
}

@safe unittest // empty root, empty registry, missing package
{
    assert(resolveText("root:\n") == "");
    assert(resolveText("a 1.0.0:\nroot:\n") == "");
    assert(resolveText("root: ghost *\n") == "unsatisfiable\n");
}

@safe unittest // cycles and self-requirements
{
    assert(resolveText("a 1.0.0: b *\nb 1.0.0: a *\nroot: a *\n") == "a 1.0.0\nb 1.0.0\n");
    assert(resolveText("a 2.0.0: a ^1.0.0\na 1.0.0:\nroot: a *\n") == "a 1.0.0\n");
}

@safe unittest // output order is byte order
{
    assert(resolveText("mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\n"
            ~ "root: mylib *, my-lib2 *, my-lib *\n")
        == "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n");
}

@safe unittest // numeric, not lexical, version order; steps down through versions
{
    assert(resolveText("a 1.9.0:\na 1.10.0:\nroot: a *\n") == "a 1.10.0\n");
    assert(resolveText("a 1.9.0:\na 1.10.0:\nroot: a <1.10.0\n") == "a 1.9.0\n");
}

@safe unittest // chronological backtracking revisits unrelated earlier choices
{
    // x's newest version is wrong for z, though unrelated: the search must retry x.
    assert(resolveText("x 2.0.0:\nx 1.0.0:\nz 1.0.0: x 1.0.0\nroot: x *, z *\n")
        == "x 1.0.0\nz 1.0.0\n");
}

@safe unittest // Resolution structure
{
    auto reg = Registry.parse("a 1.2.3:\nroot: a *\n");
    auto res = resolve(reg);
    assert(res.satisfiable && res.picks.length == 1);
    assert(res.picks[0].name == "a" && res.picks[0].version_ == Version(1, 2, 3));
}

@safe unittest // deep chain does not overflow the stack
{
    enum n = 20_000;
    auto text = appender!string();
    foreach (i; 0 .. n)
    {
        text ~= "p" ~ i.to!string;
        text ~= " 1.0.0: ";
        text ~= "p" ~ (i + 1).to!string;
        text ~= " *\n";
    }
    text ~= "p" ~ n.to!string ~ " 1.0.0:\nroot: p0 *\n";
    auto res = resolve(Registry.parse(text[]));
    assert(res.satisfiable && res.picks.length == n + 1);
}

@safe unittest // exhaustive failure terminates
{
    // Many versions of a and b, but c is never satisfiable.
    auto text = appender!string();
    foreach (i; 0 .. 30)
    {
        text ~= "a 1.0." ~ i.to!string ~ ":\n";
        text ~= "b 1.0." ~ i.to!string ~ ":\n";
    }
    text ~= "root: a *, b *, c *\n";
    assert(resolveText(text[]) == "unsatisfiable\n");
}
