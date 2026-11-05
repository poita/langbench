/// Tests for the module stream splitter.
module langvm.test_source;

import langvm;
import langvm.source;
import std.exception : collectException;

unittest
{
    auto m = splitModules("@module a\nx\r\ny\n@module b\n");
    assert(m.length == 2);
    assert(m[0].name == "a" && m[0].lines.length == 2 && m[0].lines[0] == "x"d);
    assert(m[1].name == "b" && m[1].lines.length == 0);
}

unittest
{
    foreach (bad; ["", "x\n", "@module  a\n", "@module a \n", "@module _\n", "@module fn\n", "@modulea\n"])
    {
        auto e = collectException!CompileError(splitModules(bad));
        assert(e !is null && e.kind == "bad-module" && e.line == 1 && e.col == 1, bad);
    }
    auto e = collectException!CompileError(splitModules("@module a\nfine\n@oops\n"));
    assert(e !is null && e.kind == "bad-module" && e.line == 3 && e.col == 1);
}

unittest
{
    auto e = collectException!CompileError(splitModules("@module a\n@module b\n@module a\n"));
    assert(e !is null && e.kind == "dup-module" && e.line == 3);
}

unittest
{
    assert(isIdentifier("abc_1"));
    assert(!isIdentifier("1abc"));
    assert(!isIdentifier("_"));
    assert(!isIdentifier("while"));
}
