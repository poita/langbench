/// Unit tests for the batch protocol (input views and output formatting).
module regex.test_batch;

import std.exception : assertThrown;

import regex.batch;
import regex.parser : RegexException;

private string run(string input)
{
    OutputBuffer o;
    processBatch(cast(const(ubyte)[]) input, o);
    return cast(string) o.bytes.idup;
}

unittest // the worked examples of the specification
{
    assert(run("3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n")
        == "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n");
    assert(run("2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n")
        == "match 0 2|1,2|0,1\nmatch 0 2|1,2|1,2\nmatch 1 6\nno\n");
}

unittest // strictly positional lines: spaces, empty lines, numeric-looking lines
{
    // pattern is a single space; subjects: "", " ", "2", " a"
    assert(run("1\n \n4\n\n \n2\n a\n") == "no\nmatch 0 1\nno\nmatch 0 1\n");
    // pattern "2", then count 1, subject "2"
    assert(run("1\n2\n1\n2\n") == "match 0 1\n");
}

unittest // M = 0 produces no output and consumes no subject lines
{
    assert(run("2\nx\n0\ny\n1\nzyz\n") == "match 1 2\n");
    assert(run("1\nx\n0\n") == "");
}

unittest // malformed input and invalid patterns
{
    assertThrown!BatchFormatException(run(""));
    assertThrown!BatchFormatException(run("1\nx\n2\na\n"));
    assertThrown!BatchFormatException(run("x\n"));
    assertThrown!RegexException(run("1\n(\n1\na\n"));
}

unittest // output buffer formatting
{
    OutputBuffer o;
    o.putInt(0);
    o.put(' ');
    o.putInt(1234567890);
    o.put('\n');
    assert(cast(string) o.bytes == "0 1234567890\n");
    foreach (i; 0 .. 5000)
        o.put("xy");
    assert(o.length == 13 + 10000);
}

unittest // line reader handles a missing final newline
{
    auto r = LineReader(cast(const(ubyte)[]) "ab\n\ncd");
    assert(cast(const(char)[]) r.next() == "ab");
    assert(r.next().length == 0);
    assert(cast(const(char)[]) r.next() == "cd");
    assertThrown!BatchFormatException(r.next());
}
