/// Unit tests for bigint.queries (the CLI's query language).
module queries_test;

import bigint.queries;

unittest // the worked examples from the specification
{
    assert(evaluateQueries("12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n") == "42\n-2\n-3\n-1\n");
    assert(evaluateQueries("-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0")
            == "0\n0\n0\n100000000000000000000\n1024\n1\n");
    assert(evaluateQueries("1 / 0\n0 % 0\n2 ^ -1\n"
            ~ "-123456789012345678901234567890 * 987654321098765432109876543210\n"
            ~ "1000000000000000000000000000000 - 1\n-3 cmp -2\n")
            == "error\nerror\nerror\n"
            ~ "-121932631137021795226185032733622923332237463801111263526900\n"
            ~ "999999999999999999999999999999\n-1\n");
}

unittest // empty input, optional trailing newline
{
    assert(evaluateQueries("") == "");
    assert(evaluateQueries("1 + 1") == "2\n");
    assert(evaluateQueries("1 + 1\n") == "2\n");
}

unittest // zero forms and no negative zero
{
    assert(evaluateQueries("-7 % 7\n-1 / 2\n-0 - 0\n0 - -0\n5 ^ -0\n-0 ^ -00\n5 / -0\n")
            == "0\n0\n0\n0\n1\n1\nerror\n");
    assert(evaluateQueries("-0 cmp 0\n-5 cmp 0\n0 cmp -5\n3 cmp 3\n") == "0\n-1\n1\n0\n");
}

unittest // signs of division and power
{
    assert(evaluateQueries("7 / -2\n-7 / -2\n7 % -2\n-7 % -2\n-2 ^ 3\n-2 ^ 2\n")
            == "-3\n3\n1\n-1\n-8\n4\n");
}
