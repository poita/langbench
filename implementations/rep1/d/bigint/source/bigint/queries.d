/**
 * The line-oriented calculator behind the CLI: parses `<a> <op> <b>` queries
 * and renders results into a single output buffer.
 */
module bigint.queries;

import bigint.decimal;
import bigint.magnitude;

/**
 * Evaluates every query in `input` (newline-terminated lines, the last
 * newline optional) and returns the output text: one line per query, each
 * ending in `\n`. Division by zero and negative exponents give `error`.
 */
char[] evaluateQueries(scope const(char)[] input) pure nothrow @safe
{
    char[] out_;
    out_.reserve(input.length / 2 + 64);
    size_t pos = 0;
    while (pos < input.length)
    {
        size_t eol = pos;
        while (eol < input.length && input[eol] != '\n')
            ++eol;
        evaluateLine(input[pos .. eol], out_);
        pos = eol + 1;
    }
    return out_;
}

/// Evaluates one query line (without its newline), appending the result and
/// a trailing `\n` to `output`.
void evaluateLine(scope const(char)[] line, ref char[] output) pure nothrow @safe
{
    // Split at the first and the last space; the middle is the operator.
    size_t s1 = 0;
    while (s1 < line.length && line[s1] != ' ')
        ++s1;
    size_t s2 = line.length;
    while (s2 > s1 && line[s2 - 1] != ' ')
        --s2;
    if (s1 >= line.length || s2 <= s1 + 1)
        return; // malformed (not expected); emit nothing
    auto ta = line[0 .. s1];
    auto op = line[s1 + 1 .. s2 - 1];
    auto tb = line[s2 .. $];

    auto a = parseDecimal(ta);
    auto b = parseDecimal(tb);

    if (op.length == 3) // cmp
    {
        int c;
        if (a.negative != b.negative)
            c = a.negative ? -1 : 1;
        else
        {
            c = compare(a.magnitude, b.magnitude);
            if (a.negative)
                c = -c;
        }
        output ~= c < 0 ? "-1\n" : (c == 0 ? "0\n" : "1\n");
        return;
    }

    bool neg;
    const(uint)[] res;
    switch (op[0])
    {
    case '+':
    case '-':
        {
            immutable bneg = op[0] == '-' ? (!b.negative && b.magnitude.length != 0) : b.negative;
            if (a.negative == bneg)
            {
                neg = a.negative;
                res = add(a.magnitude, b.magnitude);
            }
            else
            {
                immutable c = compare(a.magnitude, b.magnitude);
                if (c > 0)
                {
                    neg = a.negative;
                    res = sub(a.magnitude, b.magnitude);
                }
                else if (c < 0)
                {
                    neg = bneg;
                    res = sub(b.magnitude, a.magnitude);
                }
            }
            break;
        }
    case '*':
        neg = a.negative != b.negative;
        res = mul(a.magnitude, b.magnitude);
        break;
    case '/':
    case '%':
        {
            if (b.magnitude.length == 0)
            {
                output ~= "error\n";
                return;
            }
            auto dm = divMod(a.magnitude, b.magnitude);
            if (op[0] == '/')
            {
                neg = a.negative != b.negative;
                res = dm.quotient;
            }
            else
            {
                neg = a.negative;
                res = dm.remainder;
            }
            break;
        }
    default: // '^'
        {
            if (b.negative)
            {
                output ~= "error\n";
                return;
            }
            // Valid exponents are <= 5000, so at most two limbs matter.
            ulong e = 0;
            foreach_reverse (l; b.magnitude)
                e = e * BASE + l;
            neg = a.negative && (e & 1) != 0;
            res = pow(a.magnitude, e);
            break;
        }
    }
    if (res.length == 0)
        neg = false;
    immutable len = decimalLength(neg, res);
    immutable old = output.length;
    output.length = old + len + 1;
    formatDecimal(output[old .. old + len], neg, res);
    output[old + len] = '\n';
}

@safe pure nothrow unittest
{
    assert(evaluateQueries("12 + 30\n5 - 7\n-7 / 2\n-7 % 2") == "42\n-2\n-3\n-1\n");
}
