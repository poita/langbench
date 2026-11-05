module test_resolver;

import std.array : appender, replicate;
import std.conv : to;
import depresolve;

unittest // SPEC example 1: diamond that needs backtracking
{
    assert(solve(
        "a 1.0.0: c ^1.0.0\n" ~
        "b 1.0.0: c ~1.2.0\n" ~
        "c 1.1.0:\nc 1.2.5:\nc 1.3.0:\n" ~
        "root: a *, b *\n") == "a 1.0.0\nb 1.0.0\nc 1.2.5\n");
}

unittest // SPEC example 2: first solution, not the globally newest set
{
    assert(solve(
        "a 2.0.0: b ~1.0.0\na 1.0.0:\n" ~
        "b 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\n" ~
        "root: a *, b *\n") == "a 2.0.0\nb 1.0.5\n");
}

unittest // SPEC example 3: conflicting majors
{
    assert(solve(
        "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n" ~
        "root: a *, b *\n") == "unsatisfiable\n");
}

unittest // SPEC example 4: requirement order matters
{
    enum reg = "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\n" ~
               "b 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n";
    assert(solve(reg ~ "root: a *, b *\n") == "a 2.0.0\nb 1.0.0\nc 2.0.0\n");
    assert(solve(reg ~ "root: b *, a *\n") == "a 1.0.0\nb 2.0.0\nc 1.0.0\n");
}

unittest // empty cases
{
    assert(solve("root:\n") == "");
    assert(solve("a 1.0.0:\nroot:\n") == "");              // unreached packages are not listed
    assert(solve("a 1.0.0:\nroot: b *\n") == "unsatisfiable\n"); // missing package
    assert(solve("a 1.0.0:\nroot: a ^2.0.0\n") == "unsatisfiable\n");
}

unittest // numeric version ordering picks 1.10.0 over 1.9.0
{
    assert(solve("a 1.9.0:\na 1.10.0:\na 1.2.0:\nroot: a *\n") == "a 1.10.0\n");
}

unittest // output is sorted by byte order of names
{
    assert(solve("mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\n" ~
                 "root: mylib *, my-lib2 *, my-lib *\n")
        == "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n");
}

unittest // self-dependency and cycles
{
    assert(solve("a 2.0.0: a ^1.0.0\na 1.0.0: a ^1.0.0\nroot: a *\n") == "a 1.0.0\n");
    assert(solve("a 1.0.0: b *\nb 1.0.0: a *\nroot: a *\n") == "a 1.0.0\nb 1.0.0\n");
}

unittest // chronological backtracking revisits an unrelated package
{
    // x is chosen before the conflict between y and z surfaces; the search
    // must step x down even though x is unrelated to the failing requirement.
    // x 2.0.0 -> w ^2; x 1.0.0 -> w ^1. y needs w ^1.
    assert(solve(
        "x 2.0.0: w ^2.0.0\nx 1.0.0: w ^1.0.0\n" ~
        "w 1.0.0:\nw 2.0.0:\ny 1.0.0: w ^1.0.0\n" ~
        "root: x *, y *\n") == "w 1.0.0\nx 1.0.0\ny 1.0.0\n");
}

unittest // backtracking restores state: retried subtree must see a clean slate
{
    assert(solve(
        "a 2.0.0: b ^2.0.0, z ^9.0.0\n" ~
        "a 1.0.0: b ^1.0.0\n" ~
        "b 2.0.0:\nb 1.0.0:\nz 1.0.0:\n" ~
        "root: a *\n") == "a 1.0.0\nb 1.0.0\n");
}

unittest // already-chosen package satisfying a later requirement
{
    // a fixes c 3.0.0; b needs <3.0.0, so c steps down to 2.0.0.
    assert(solve("a 1.0.0: c *\nb 1.0.0: c >=1.0.0 <3.0.0\nc 1.0.0:\nc 2.0.0:\nc 3.0.0:\n" ~
                 "root: a *, b *\n") == "a 1.0.0\nb 1.0.0\nc 2.0.0\n");
}

unittest // deep chain does not overflow the stack
{
    enum n = 20_000;
    auto input = appender!string;
    foreach (i; 0 .. n)
        input.put("p" ~ i.to!string ~ " 1.0.0: p" ~ (i + 1).to!string ~ " *\n");
    input.put("p" ~ n.to!string ~ " 1.0.0:\nroot: p0 *\n");
    auto res = resolve(parseInput(input.data));
    assert(res.satisfiable && res.picks.length == n + 1);
}

unittest // exhaustive failure terminates with the right answer
{
    // Each of k packages has two versions; the last root requirement is
    // impossible, so every combination is tried before giving up.
    enum k = 10;
    auto input = appender!string;
    foreach (i; 0 .. k)
    {
        input.put("p" ~ i.to!string ~ " 1.0.0:\n");
        input.put("p" ~ i.to!string ~ " 2.0.0:\n");
    }
    input.put("root:");
    foreach (i; 0 .. k)
        input.put((i ? ", p" : " p") ~ i.to!string ~ " *");
    input.put(", nope *\n");
    assert(solve(input.data) == "unsatisfiable\n");
}

unittest // formatResolution
{
    Resolution r;
    assert(formatResolution(r) == "unsatisfiable\n");
    r.satisfiable = true;
    assert(formatResolution(r) == "");
    r.picks = [Pick("a", Version(1, 2, 3)), Pick("b", Version(0, 10, 0))];
    assert(formatResolution(r) == "a 1.2.3\nb 0.10.0\n");
}
