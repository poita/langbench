/**
 * Evaluator for the line-oriented query protocol used by the command-line tool.
 *
 * Each query is `<a> <op> <b>` with `op` one of `+ - * / % ^ cmp`. The result
 * is printed in canonical decimal form (`cmp` prints -1, 0 or 1); a division
 * or remainder by zero or a negative exponent prints `error`.
 */
module bigint.query;

import bigint.bigint;
import bigint.exceptions;

/// Thrown for a line that is not a well-formed query.
class QueryFormatException : BigIntException
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// The text printed for a query that has no numeric result.
enum string errorText = "error";

/**
 * Evaluates a single query line (without its terminating newline).
 *
 * Returns the output text, or `"error"` for division by zero / negative
 * exponent. Throws `QueryFormatException` or `ParseException` for malformed
 * lines.
 */
string evaluateQuery(scope const(char)[] line) @safe
{
    // Strip a stray carriage return for robustness.
    if (line.length > 0 && line[$ - 1] == '\r')
        line = line[0 .. $ - 1];

    const s1 = indexOfSpace(line, 0);
    if (s1 == size_t.max)
        throw new QueryFormatException("expected '<a> <op> <b>'");
    const s2 = indexOfSpace(line, s1 + 1);
    if (s2 == size_t.max)
        throw new QueryFormatException("expected '<a> <op> <b>'");

    const op = line[s1 + 1 .. s2];
    const a = BigInt(line[0 .. s1]);
    const b = BigInt(line[s2 + 1 .. $]);

    try
    {
        switch (op)
        {
        case "+":
            return (a + b).toString;
        case "-":
            return (a - b).toString;
        case "*":
            return (a * b).toString;
        case "/":
            return (a / b).toString;
        case "%":
            return (a % b).toString;
        case "^":
            return (a ^^ b).toString;
        case "cmp":
            const c = a.opCmp(b);
            return c < 0 ? "-1" : (c > 0 ? "1" : "0");
        default:
            throw new QueryFormatException("unknown operator");
        }
    }
    catch (DivisionByZeroException)
        return errorText;
    catch (NegativeExponentException)
        return errorText;
}

/**
 * Evaluates every non-empty line of `input` and passes each result line
 * (including its trailing newline) to `sink`.
 */
void processQueries(scope const(char)[] input, scope void delegate(scope const(char)[]) @safe sink) @safe
{
    while (input.length > 0)
    {
        size_t eol = 0;
        while (eol < input.length && input[eol] != '\n')
            ++eol;
        const line = input[0 .. eol];
        input = eol < input.length ? input[eol + 1 .. $] : input[$ .. $];
        if (line.length == 0)
            continue;
        sink(evaluateQuery(line));
        sink("\n");
    }
}

private size_t indexOfSpace(scope const(char)[] s, size_t from) @safe pure nothrow @nogc
{
    foreach (i; from .. s.length)
        if (s[i] == ' ')
            return i;
    return size_t.max;
}

unittest
{
    assert(evaluateQuery("12 + 30") == "42");
    assert(evaluateQuery("5 - 7") == "-2");
    assert(evaluateQuery("-7 / 2") == "-3");
    assert(evaluateQuery("-7 % 2") == "-1");
    assert(evaluateQuery("007 cmp 7") == "0");
    assert(evaluateQuery("-3 cmp -2") == "-1");
    assert(evaluateQuery("3 cmp -2") == "1");
    assert(evaluateQuery("0 ^ 0") == "1");
    assert(evaluateQuery("1 / 0") == "error");
    assert(evaluateQuery("0 % 0") == "error");
    assert(evaluateQuery("2 ^ -1") == "error");
    assert(evaluateQuery("5 ^ -0") == "1");
    assert(evaluateQuery("5 / -0") == "error");
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!QueryFormatException(evaluateQuery("1 +"));
    assertThrown!QueryFormatException(evaluateQuery("1 ? 2"));
    assertThrown!ParseException(evaluateQuery("x + 2"));
}

unittest
{
    string output;
    processQueries("12 + 30\n5 - 7\n-7 / 2\n-7 % 2", (scope const(char)[] s) { output ~= s; });
    assert(output == "42\n-2\n-3\n-1\n");
    output = null;
    processQueries("", (scope const(char)[] s) { output ~= s; });
    assert(output.length == 0);
}
