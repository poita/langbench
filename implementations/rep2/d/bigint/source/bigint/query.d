/**
 * Evaluation of textual queries of the form `<a> <op> <b>`.
 *
 * This is the layer the command-line tool is built on. `op` is one of
 * `+ - * / % ^ cmp`. Operands are decimal integers as accepted by
 * $(REF BigInt, bigint, bigint).
 *
 * The result of an arithmetic query is its canonical decimal form, `cmp`
 * yields `-1`, `0` or `1`, and a division by zero or negative exponent
 * yields `error`.
 */
module bigint.query;

import bigint.bigint;
import bigint.decimal : ParseException;

/// The text printed for a query that has no value.
enum string errorText = "error";

/**
 * Evaluates one query line (without its line terminator) and appends the
 * result, without a newline, to `buf`.
 *
 * Throws: $(REF ParseException, bigint, decimal) if the line is malformed.
 */
char[] evaluate(char[] buf, const(char)[] line) pure @safe
{
    // Exactly "<a> <op> <b>", tokens separated by a single space.
    size_t s1 = indexOfSpace(line, 0);
    size_t s2 = indexOfSpace(line, s1 + 1);
    if (s1 == 0 || s1 >= line.length || s2 >= line.length || s2 + 1 >= line.length
            || s2 == s1 + 1)
        throw new ParseException("malformed query");
    auto a = BigInt(line[0 .. s1]);
    auto op = line[s1 + 1 .. s2];
    auto b = BigInt(line[s2 + 1 .. $]);

    try
    {
        switch (op)
        {
        case "+":
            return (a + b).appendTo(buf);
        case "-":
            return (a - b).appendTo(buf);
        case "*":
            return (a * b).appendTo(buf);
        case "/":
            return (a / b).appendTo(buf);
        case "%":
            return (a % b).appendTo(buf);
        case "^":
            return (a ^^ b).appendTo(buf);
        case "cmp":
            immutable c = a.opCmp(b);
            buf ~= c < 0 ? "-1" : (c == 0 ? "0" : "1");
            return buf;
        default:
            throw new ParseException("unknown operator");
        }
    }
    catch (BigIntException)
    {
        buf ~= errorText;
        return buf;
    }
}

/// Convenience wrapper around $(LREF evaluate) returning a new string.
string evaluate(const(char)[] line) pure @safe
{
    return (() @trusted => cast(string) evaluate(null, line))();
}

/**
 * Evaluates every line of `input` and returns one output line per query,
 * each terminated by `\n`. A missing final newline in the input is fine and
 * empty lines are skipped.
 */
char[] evaluateAll(const(char)[] input) pure @safe
{
    char[] output;
    output.reserve(input.length / 4 + 16);
    while (input.length > 0)
    {
        size_t nl = 0;
        while (nl < input.length && input[nl] != '\n')
            ++nl;
        auto line = input[0 .. nl];
        input = nl < input.length ? input[nl + 1 .. $] : input[nl .. $];
        if (line.length == 0)
            continue;
        output = evaluate(output, line);
        output ~= '\n';
    }
    return output;
}

private size_t indexOfSpace(const(char)[] s, size_t from) pure nothrow @nogc @safe
{
    foreach (i; from .. s.length)
        if (s[i] == ' ')
            return i;
    return s.length;
}

@("query: worked examples")
unittest
{
    assert(evaluateAll("12 + 30\n5 - 7\n-7 / 2\n-7 % 2") == "42\n-2\n-3\n-1\n");
    assert(evaluateAll("-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0\n")
            == "0\n0\n0\n100000000000000000000\n1024\n1\n");
    assert(evaluateAll("1 / 0\n0 % 0\n2 ^ -1\n1000000000000000000000000000000 - 1\n-3 cmp -2\n")
            == "error\nerror\nerror\n999999999999999999999999999999\n-1\n");
}

@("query: empty input and zero forms")
unittest
{
    assert(evaluateAll("") == "");
    assert(evaluateAll("5 ^ -0\n-0 ^ -00\n5 / -0\n-1 / 2\n-7 % 7\n") == "1\n1\nerror\n0\n0\n");
}

@("query: malformed lines are rejected")
unittest
{
    import std.exception : assertThrown;

    assertThrown!ParseException(evaluate("1 +"));
    assertThrown!ParseException(evaluate("1  + 2"));
    assertThrown!ParseException(evaluate("1 ? 2"));
    assertThrown!ParseException(evaluate("x + 2"));
}
