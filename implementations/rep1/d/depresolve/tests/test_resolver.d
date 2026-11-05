module tests.test_resolver;

import depresolve;

private string solve(string input)
{
    const res = resolveText(input);
    return formatResolution(res);
}

unittest // diamond that needs backtracking
{
    assert(solve("a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n")
            == "a 1.0.0\nb 1.0.0\nc 1.2.5\n");
}

unittest // first solution, not globally newest
{
    assert(solve("a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\nroot: a *, b *\n")
            == "a 2.0.0\nb 1.0.5\n");
}

unittest // conflicting majors
{
    assert(solve("a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n")
            == "unsatisfiable\n");
}

unittest // requirement order matters
{
    enum reg = "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n";
    assert(solve(reg ~ "root: a *, b *\n") == "a 2.0.0\nb 1.0.0\nc 2.0.0\n");
    assert(solve(reg ~ "root: b *, a *\n") == "a 1.0.0\nb 2.0.0\nc 1.0.0\n");
}

unittest // empty root, missing package, numeric version order, name order
{
    assert(solve("root:\n") == "");
    assert(solve("root: ghost *\n") == "unsatisfiable\n");
    assert(solve("a 1.9.0:\na 1.10.0:\nroot: a *\n") == "a 1.10.0\n");
    assert(solve("mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n")
            == "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n");
}

unittest // cycles and self-requirements
{
    assert(solve("a 1.0.0: b *\nb 1.0.0: a *\nroot: a *\n") == "a 1.0.0\nb 1.0.0\n");
    assert(solve("a 2.0.0: a ^1.0.0\na 1.0.0: a ^1.0.0\nroot: a *\n") == "a 1.0.0\n");
}

unittest // chronological backtracking undoes unrelated choices
{
    // x is chosen before the failing requirement and is retried first.
    assert(solve("x 2.0.0:\nx 1.0.0:\ny 1.0.0: x 1.0.0\nroot: x *, y *\n") == "x 1.0.0\ny 1.0.0\n");
}

unittest // deep chain does not overflow the stack
{
    import std.array : appender;
    import std.format : format;

    auto buf = appender!string();
    enum n = 5000;
    foreach (i; 0 .. n)
        buf.put(i + 1 < n ? format("p%d 1.0.0: p%d *\n", i, i + 1) : format("p%d 1.0.0:\n", i));
    buf.put("root: p0 *\n");
    const res = resolveText(buf.data);
    assert(res.satisfiable && res.choices.length == n);
}

unittest // resolution structure
{
    const res = resolveText("b 1.2.3:\na 0.0.1:\nroot: b *, a *\n");
    assert(res.satisfiable && res.choices.length == 2);
    assert(res.choices[0].name == "a" && res.choices[0].versionString == "0.0.1");
    assert(res.choices[1].name == "b" && res.choices[1].versionString == "1.2.3");
}
