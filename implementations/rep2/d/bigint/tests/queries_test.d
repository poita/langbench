/// Unit tests for bigint.queries (the query evaluator behind the CLI).
module queries_test;

import bigint.integer : BigIntException;
import bigint.queries;
import std.array : appender;
import std.exception : assertThrown;

private string run(string input)
{
    auto app = appender!string();
    evalQueries(app, input);
    return app[];
}

unittest // spec example 1
{
    assert(run("12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n") == "42\n-2\n-3\n-1\n");
}

unittest // spec example 2
{
    assert(run("-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0\n")
        == "0\n0\n0\n100000000000000000000\n1024\n1\n");
}

unittest // spec example 3: errors
{
    assert(run("1 / 0\n0 % 0\n2 ^ -1\n-3 cmp -2\n") == "error\nerror\nerror\n-1\n");
}

unittest // negative-zero operands
{
    assert(run("5 ^ -0\n-0 ^ -00\n5 / -0\n-7 % 7\n-1 / 2\n")
        == "1\n1\nerror\n0\n0\n");
}

unittest // framing: empty input, missing final newline
{
    assert(run("") == "");
    assert(run("1 + 1") == "2\n");
    assert(run("1 + 1\n2 + 2") == "2\n4\n");
}

unittest // huge negative exponent is an error, not an overflow
{
    string e = "1";
    foreach (_; 0 .. 5000)
        e ~= "0";
    assert(run("2 ^ -" ~ e ~ "\n") == "error\n");
}

unittest // malformed queries are rejected
{
    assertThrown!BigIntException(run("1 +\n"));
    assertThrown!BigIntException(run("1 ? 2\n"));
}
