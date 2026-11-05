module sat.output_test;

import sat.output;

private string text(bool sat, bool[] model)
{
    return cast(string) renderResult(sat, model).idup;
}

unittest
{
    assert(text(false, []) == "UNSAT\n");
    assert(text(true, []) == "SAT\n0\n");
    assert(text(true, [true, false, true]) == "SAT\n1 -2 3 0\n");
}

unittest // multi-digit variable numbers
{
    auto m = new bool[120];
    m[9] = true;       // variable 10
    m[99] = true;      // variable 100
    auto s = text(true, m);
    assert(s[0 .. 4] == "SAT\n");
    assert(s[$ - 2 .. $] == "0\n");
    import std.algorithm : canFind;
    assert(s.canFind(" 10 ") && s.canFind(" 100 ") && s.canFind(" -99 ") && s.canFind(" -120 "));
}
