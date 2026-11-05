module tests.header_test;

import mime.ascii;
import mime.header;

private const(ubyte)[] b(string s) { return cast(const(ubyte)[]) s; }

unittest // folding and body offset
{
    auto hb = parseHeaders(b("Subject: a\n b\nX:y\n\nbody"));
    assert(hb.fields.length == 2);
    assert(hb.fields[0].name == "subject");
    assert(hb.fields[0].rawValue == " a b");
    assert(hb.fields[1].rawValue == "y");
    assert(hb.bodyStart == 19);
}

unittest // lines that are not field lines end the block
{
    foreach (bad; ["Subject :x", "no colon here", ": novalue", "From nobody Mon Sep  1 00:00:00 2025"])
    {
        auto text = "A: 1\n" ~ bad ~ "\nrest";
        auto hb = parseHeaders(b(text));
        assert(hb.fields.length == 1);
        assert(hb.bodyStart == 5);
    }
}

unittest // a header block without a blank line has an empty body
{
    auto hb = parseHeaders(b("A: 1\nB: 2"));
    assert(hb.fields.length == 2 && hb.bodyStart == 9);
    hb = parseHeaders(b(""));
    assert(hb.fields.length == 0 && hb.bodyStart == 0);
    hb = parseHeaders(b(" leading\nA: 1\n"));
    assert(hb.fields.length == 0 && hb.bodyStart == 0);
}

unittest // field values and lookup
{
    auto hb = parseHeaders(b("Subject: =?utf-8?Q?caf=C3=A9?= x\nDate:   a \t b  \nsubject: second\n\n"));
    assert(hb.fields[0].displayValue() == "café x");
    assert(hb.fields[1].displayValue() == "a b");
    auto f = findHeader(hb.fields, "subject");
    assert(f !is null && f.rawValue == " =?utf-8?Q?caf=C3=A9?= x");
    assert(findHeader(hb.fields, "to") is null);
}

unittest // header bytes are decoded as UTF-8 with replacement
{
    auto hb = parseHeaders(b("X: caf\xE9\n"));
    assert(hb.fields[0].rawValue == " caf�");
}

unittest // collapse
{
    assert(collapse("  a \t b  ") == "a b");
    assert(collapse(" \t ") == "");
}
