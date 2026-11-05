/**
 * Evaluator for the line-oriented query format `<a> <op> <b>`.
 *
 * Operators: `+ - * / % ^ cmp`. Results are printed in canonical decimal
 * form, one per line; `/` and `%` by zero and `^` with a negative exponent
 * print `error`.
 */
module bigint.queries;

import bigint.integer;
import bigint.limbs;

/// Evaluates a single query line (without the line terminator), appending
/// the result line, including its trailing `\n`, to `sink`.
///
/// Throws: `BigIntException` if the line is malformed.
void evalQuery(Sink)(ref Sink sink, const(char)[] line)
{
    import std.range.primitives : put;

    // Split at the first and second space.
    size_t s1 = 0;
    while (s1 < line.length && line[s1] != ' ')
        ++s1;
    if (s1 == line.length)
        throw new BigIntException("malformed query: " ~ line.idup);
    size_t s2 = s1 + 1;
    while (s2 < line.length && line[s2] != ' ')
        ++s2;
    if (s2 == line.length)
        throw new BigIntException("malformed query: " ~ line.idup);

    auto a = BigInt(line[0 .. s1]);
    auto op = line[s1 + 1 .. s2];
    auto b = BigInt(line[s2 + 1 .. $]);

    if (op.length == 1)
    {
        switch (op[0])
        {
        case '+':
            (a + b).toDecimal(sink);
            break;
        case '-':
            (a - b).toDecimal(sink);
            break;
        case '*':
            (a * b).toDecimal(sink);
            break;
        case '/':
        case '%':
            if (b.isZero)
            {
                put(sink, "error");
            }
            else
            {
                auto qr = divMod(a, b);
                (op[0] == '/' ? qr.quotient : qr.remainder).toDecimal(sink);
            }
            break;
        case '^':
            if (b.isNegative)
            {
                put(sink, "error");
            }
            else
            {
                long e;
                // Valid exponents are tiny; anything larger is saturated.
                if (!b.toLong(e))
                    e = long.max;
                pow(a, cast(ulong) e).toDecimal(sink);
            }
            break;
        default:
            throw new BigIntException("unknown operator: " ~ op.idup);
        }
    }
    else if (op == "cmp")
    {
        immutable c = a.opCmp(b);
        put(sink, c < 0 ? "-1" : (c == 0 ? "0" : "1"));
    }
    else
        throw new BigIntException("unknown operator: " ~ op.idup);
    put(sink, '\n');
}

/// Evaluates every query in `input` (lines separated by `\n`; the final line
/// may lack a terminator; an empty input has no queries), appending one
/// output line per query to `sink`.
void evalQueries(Sink)(ref Sink sink, const(char)[] input)
{
    size_t pos = 0;
    while (pos < input.length)
    {
        size_t end = pos;
        while (end < input.length && input[end] != '\n')
            ++end;
        evalQuery(sink, input[pos .. end]);
        pos = end + 1;
    }
}
