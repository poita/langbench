/// Unit tests for orderedmap.commands (the spec's worked examples and edge cases).
module commands_test;

import orderedmap;

private string run(string input)
{
    auto m = OrderedMap(commandCount(input) + 1);
    OutBuffer o;
    runScript(input, m, o);
    return o.data.idup;
}

unittest // example 1
{
    assert(run("12\nsize\nmin\ninsert 5 five\ninsert 5 FIVE\nget 5\ninsert 2 two\n"
        ~ "insert 9 nine\nmin\nmax\nrange 2 9\ndelete 5\nrange 3 8")
        == "0\nempty\nok\nupdated\nFIVE\nok\nok\n2\n9\n2 5 9\nok\nempty\n");
}

unittest // example 2
{
    assert(run("14\ninsert 10 a\ninsert 20 b\ninsert 30 c\nfloor 25\nceil 25\nfloor 10\n"
        ~ "ceil 10\nsucc 10\npred 10\nsucc 30\nrank 20\nrank 21\nselect 2\nselect 3\n")
        == "ok\nok\nok\n20\n30\n10\n10\n20\nmissing\nmissing\n1\n2\n30\nmissing\n");
}

unittest // example 3: extreme keys
{
    assert(run("9\ninsert -9223372036854775808 lo\ninsert 9223372036854775807 hi\n"
        ~ "insert 0 zero\nsucc 9223372036854775807\npred -9223372036854775808\n"
        ~ "floor -9223372036854775807\nceil 1\n"
        ~ "range -9223372036854775808 9223372036854775807\ndelete 0\n")
        == "ok\nok\nok\nmissing\nmissing\n-9223372036854775808\n9223372036854775807\n"
        ~ "-9223372036854775808 0 9223372036854775807\nok\n");
}

unittest // zero commands, empty-map answers
{
    assert(run("0\n") == "");
    assert(run("8\nmin\nmax\nsize\nrank 3\nselect 0\nrange 1 2\nget 1\nfloor 1\n")
        == "empty\nempty\n0\n0\nmissing\nempty\nmissing\nmissing\n");
}

unittest // values are opaque, including keyword lookalikes and punctuation
{
    assert(run("5\ninsert 1 missing\ninsert 2 \"'`\\<>|{}#\nget 1\nget 2\nrange 5 1\n")
        == "ok\nok\nmissing\n\"'`\\<>|{}#\nempty\n");
}

unittest // CRLF line endings tolerated
{
    assert(run("2\r\ninsert 1 a\r\nget 1\r\n") == "ok\na\n");
}
