module test_runner;

import std.array : appender;
import jq;

private string go(string input, out bool ok)
{
    auto app = appender!string;
    string problem;
    ok = runSpecInput(input, (const(char)[] s) { app.put(s); }, problem);
    return app.data;
}

unittest // filter on the first line, document on the rest
{
    bool ok;
    assert(go(".a\n{\"a\":[1,2]}\n", ok) == "[1,2]\n" && ok);
    assert(go(".[]\n[1,\n2,\n3]", ok) == "1\n2\n3\n" && ok);
    assert(go("empty\nnull", ok) == "" && ok);
}

unittest // partial output then error
{
    bool ok;
    assert(go("1, 2, error, 3\nnull", ok) == "1\n2\nerror\n" && !ok);
}

unittest // large outputs are flushed in chunks and stay in order
{
    bool ok;
    auto outp = go(".[]\n[" ~ numbers(100_000) ~ "]", ok);
    assert(ok);
    assert(outp.length > 100_000);
    assert(outp[$ - 6 .. $] == "99999\n");
}

private string numbers(size_t n)
{
    import std.conv : to;
    import std.array : join;
    string[] parts;
    foreach (i; 0 .. n)
        parts ~= i.to!string;
    return parts.join(",");
}

unittest // unparsable input reports error
{
    bool ok;
    assert(go("(\nnull", ok) == "error\n" && !ok);
    assert(go(".\n{", ok) == "error\n" && !ok);
}
