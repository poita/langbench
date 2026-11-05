/// Unit tests for the line reader, output formatting and batch driver.
module regexvm.test_batch;

import std.exception : assertThrown;
import regexvm;

private string batch(string input)
{
    OutputBuffer o;
    runBatch(cast(const(ubyte)[]) input, o);
    return (cast(const(char)[]) o.data).idup;
}

unittest // line reader is positional and verbatim
{
    auto r = LineReader(cast(const(ubyte)[]) "12\n  \n\nx y\nlast");
    assert(r.nextCount() == 12);
    assert(cast(const(char)[]) r.nextLine() == "  ");
    assert(cast(const(char)[]) r.nextLine() == "");
    assert(cast(const(char)[]) r.nextLine() == "x y");
    assert(!r.empty);
    assert(cast(const(char)[]) r.nextLine() == "last");
    assert(r.empty);
    assertThrown!InputFormatException(r.nextLine());
}

unittest // counts must be plain decimal
{
    assertThrown!InputFormatException(LineReader(cast(const(ubyte)[]) " 3\n").nextCount());
    assertThrown!InputFormatException(LineReader(cast(const(ubyte)[]) "\n").nextCount());
    assertThrown!InputFormatException(LineReader(cast(const(ubyte)[]) "-1\n").nextCount());
}

unittest // number formatting
{
    OutputBuffer o;
    o.putNumber(0);
    o.putChar(' ');
    o.putNumber(10_000);
    o.putChar(' ');
    o.putNumber(1234567890);
    assert(cast(const(char)[]) o.data == "0 10000 1234567890");
}

unittest // output buffer grows
{
    OutputBuffer o;
    foreach (i; 0 .. 5000)
        o.put("no\n");
    assert(o.data.length == 15_000);
}

unittest // specification example 1
{
    auto input = "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n";
    assert(batch(input) ==
        "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n");
}

unittest // empty pattern, zero subjects, numeric-looking lines
{
    // pattern "" with subjects "", "  " and "3"; then a pattern with M = 0;
    // then the pattern "3" whose subject line is "0".
    auto input = "3\n\n3\n\n  \n3\nx\n0\n3\n1\n0\n";
    assert(batch(input) == "match 0 0\nmatch 0 0\nmatch 0 0\nno\n");
    assert(batch("1\na\n0\n") == "");
}

unittest // leading and trailing spaces belong to the pattern
{
    assert(batch("1\n a \n3\na\n a \nxx a x\n") == "no\nmatch 0 3\nmatch 2 5\n");
}

unittest // malformed input and bad patterns are reported
{
    assertThrown!InputFormatException(batch("2\na\n1\nx\n"));
    assertThrown!RegexException(batch("1\n(a\n1\nx\n"));
}
