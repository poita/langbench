module test_lines;

import textbuffer.lines;
import textbuffer.position;
import textbuffer.vec;

private string textOf(LineStore s)
{
    CharBuf b;
    s.writeText(b);
    return b[].idup;
}

private LineStore make(string text)
{
    const(char)[][] parts;
    size_t from = 0;
    foreach (i, ch; text)
        if (ch == '\n') { parts ~= text[from .. i]; from = i + 1; }
    parts ~= text[from .. $];
    return new LineStore(parts);
}

unittest // construction
{
    assert(new LineStore().length == 1);
    assert(textOf(new LineStore()) == "");
    auto s = make("a\n\nccc");
    assert(s.length == 3 && s.lineLength(1) == 0 && s[2].view == "ccc");
}

unittest // splice inside one line
{
    auto s = make("hello world");
    assert(s.splice(Pos(0, 5), Pos(0, 5), ",") == Pos(0, 6));
    assert(textOf(s) == "hello, world");
    assert(s.splice(Pos(0, 0), Pos(0, 5), "J") == Pos(0, 1));
    assert(textOf(s) == "J, world");
    assert(s.splice(Pos(0, 1), Pos(0, 3), "") == Pos(0, 1));
    assert(textOf(s) == "Jworld");
}

unittest // inserting newlines
{
    auto s = make("abcdef");
    assert(s.splice(Pos(0, 3), Pos(0, 3), "X\nY\nZ") == Pos(2, 1));
    assert(textOf(s) == "abcX\nY\nZdef");
    assert(s.length == 3);
    assert(s.splice(Pos(1, 0), Pos(1, 1), "\n") == Pos(2, 0));
    assert(textOf(s) == "abcX\n\n\nZdef");
}

unittest // removing across lines
{
    auto s = make("one\ntwo\nthree\nfour");
    assert(s.splice(Pos(0, 2), Pos(2, 2), "") == Pos(0, 2));
    assert(textOf(s) == "onree\nfour");
    assert(s.length == 2);
    assert(s.splice(Pos(0, 0), Pos(1, 4), "x") == Pos(0, 1));
    assert(textOf(s) == "x");
}

unittest // replacing multi-line by multi-line, equal and unequal counts
{
    auto s = make("a\nb\nc\nd");
    s.splice(Pos(0, 1), Pos(1, 1), "\n");
    assert(textOf(s) == "a\n\nc\nd");
    s.splice(Pos(1, 0), Pos(2, 0), "1\n2\n3\n");
    assert(textOf(s) == "a\n1\n2\n3\nc\nd");
}

unittest // extract
{
    auto s = make("one\ntwo\nthree");
    CharBuf b;
    s.extract(Pos(0, 1), Pos(0, 3), b);
    assert(b[] == "ne");
    b.clear();
    s.extract(Pos(0, 2), Pos(2, 2), b);
    assert(b[] == "e\ntwo\nth");
    b.clear();
    s.extract(Pos(1, 1), Pos(1, 1), b);
    assert(b.empty);
}

unittest // many ascending and descending edits keep the gap consistent
{
    string[] model;
    foreach (i; 0 .. 300) model ~= "line";
    auto s = new LineStore(cast(const(char)[][]) model);
    // Insert a line after every line, from the top.
    foreach (i; 0 .. 300)
        s.splice(Pos(2 * i, 4), Pos(2 * i, 4), "\nnew");
    assert(s.length == 600);
    foreach (i; 0 .. 600)
        assert(s[i].view == (i % 2 ? "new" : "line"));
    // Remove them again, from the bottom.
    foreach_reverse (i; 0 .. 300)
        s.splice(Pos(2 * i, 4), Pos(2 * i + 1, 3), "");
    assert(s.length == 300);
    foreach (i; 0 .. 300)
        assert(s[i].view == "line");
}

unittest // long line growth
{
    auto s = new LineStore();
    foreach (i; 0 .. 10_000)
        s.splice(Pos(0, i), Pos(0, i), "x");
    assert(s.lineLength(0) == 10_000);
    s.splice(Pos(0, 5), Pos(0, 9_995), "");
    assert(textOf(s) == "xxxxxxxxxx");
}
