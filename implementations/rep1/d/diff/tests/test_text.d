/// Unit tests for the text-level API: lines, interning, diffLines, scripts, patch.
module tests.test_text;

import std.array : appender;
import std.exception : assertThrown;
import mdiff;

private const(char)[][] L(const(char)[][] xs...) { return xs.dup; }

unittest // LineReader: views, CRLF, missing final newline
{
    auto r = LineReader("a\nb \r\n\nlast");
    assert(r.readLine() == "a");
    assert(r.readLine() == "b ");
    assert(r.readLine() == "");
    assert(r.readLine() == "last");
    assert(r.empty);
    assertThrown!FormatException(r.readLine());
}

unittest // counts
{
    auto r = LineReader("12 \t\n0\nx\n");
    assert(r.readCount() == 12);
    assert(r.readCount() == 0);
    assertThrown!FormatException(r.readCount()); // "x"
    assertThrown!FormatException(parseCount(""));
    assertThrown!FormatException(parseCount("-1"));
    assertThrown!FormatException(parseCount("99999999999999999999999"));
    assert(parseCount("150000") == 150_000);
}

unittest // readLines rejects counts larger than the input
{
    auto r = LineReader("a\nb\n");
    assertThrown!FormatException(r.readLines(1_000_000_000));
    auto r2 = LineReader("a\nb\n");
    assert(r2.readLines(2) == ["a", "b"]);
    r2.expectEnd();
}

unittest // trailing data
{
    auto r = LineReader("\n\nx\n");
    assertThrown!FormatException(r.expectEnd());
}

unittest // interning is by exact bytes
{
    Interner in_;
    assert(in_.intern("a") == 0);
    assert(in_.intern("a ") == 1);
    assert(in_.intern("a") == 0);
    assert(in_.intern("") == 2);
    assert(in_.length == 3);
    assert(in_.internAll(L("", "a ", "z")) == [2, 1, 3]);
}

private string render(const(char)[][] a, const(char)[][] b)
{
    auto sink = appender!(char[])();
    appendScript(sink, diffLines(a, b), a, b);
    return sink.data.idup;
}

unittest // diffLines + appendScript: identical, empty
{
    assert(render(L(), L()) == "0\n");
    assert(render(L("x", ""), L("x", "")) == "2\n x\n \n");
    assert(render(L(), L("q")) == "1\n+q\n");
    assert(render(L("q"), L()) == "1\n-q\n");
}

unittest // whitespace and tag look-alikes are content
{
    auto a = L("-x", "+1", " ", "5");
    auto b = L("-x", "+1", "  ", "5");
    immutable got = render(a, b);
    assert(got == "5\n -x\n +1\n- \n+  \n 5\n"
        || got == "5\n -x\n +1\n+  \n- \n 5\n");
}

unittest // patch: the specification's example
{
    auto a = L("a", "b", "c", "d", "e");
    auto s = L(" a", "-b", "+B", " c", "+c2", "-d", " e", "+f");
    assert(applyScript(a, s) == L("a", "B", "c", "c2", "e", "f"));
}

unittest // patch: tag-only lines, empty result
{
    assert(applyScript(L(" "), L("  ")) == L(" "));
    assert(applyScript(L("", "x"), L("-", "-x")).length == 0);
    assert(applyScript(L(), L("+")) == L(""));
}

unittest // patch rejects invalid scripts
{
    assertThrown!PatchException(applyScript(L("a"), L("-b")));
    assertThrown!PatchException(applyScript(L("a"), L()));
    assertThrown!PatchException(applyScript(L(), L(" a")));
    assertThrown!PatchException(applyScript(L("a"), L("*a")));
    assertThrown!PatchException(applyScript(L("a"), L("")));
}

unittest // diff then patch round-trips
{
    auto a = L("one", "two", "two", "three", "", "four ");
    auto b = L("zero", "two", "three", "four", "", "five");
    auto sink = appender!(char[])();
    foreach (e; diffLines(a, b))
    {
        sink.put(tagOf(e.kind));
        sink.put(e.kind == EditKind.insert ? b[e.index] : a[e.index]);
        sink.put('\n');
    }
    const(char)[][] script;
    foreach (l; LineReader(sink.data).readLines(diffLines(a, b).length))
        script ~= l;
    assert(applyScript(a, script) == b);
}
