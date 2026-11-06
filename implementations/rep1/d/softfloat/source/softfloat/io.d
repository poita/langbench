/**
 * Text I/O for the batch format: one operation per line, hex bit patterns.
 *
 * Input lines look like `add 3f800000 3f800000` or `sqrt 40000000`; each
 * produces one line of eight lowercase hex digits.
 */
module softfloat.io;

import softfloat.arith;

/**
 * Processes a whole input buffer and returns the output text.
 *
 * Lines may end in `\n` or `\r\n`; the final newline is optional. Empty
 * lines are skipped.
 */
ubyte[] processBatch(scope const(ubyte)[] input) @safe pure nothrow
{
    // Upper bound on the number of lines: one per newline plus a final one.
    size_t lines = 1;
    foreach (c; input)
        if (c == '\n')
            ++lines;
    auto output = new ubyte[](9 * lines);
    size_t o = 0;

    size_t i = 0;
    immutable n = input.length;
    while (i < n)
    {
        size_t end = i;
        while (end < n && input[end] != '\n')
            ++end;
        auto line = input[i .. end];
        i = end + 1;
        if (line.length >= 1 && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        if (line.length < 8)
            continue;

        uint result;
        if (line[0] == 's' && line[1] == 'q')
        {
            result = softfloat.arith.sqrt(parseHex32(line[5 .. 13]));
        }
        else
        {
            immutable a = parseHex32(line[4 .. 12]);
            immutable b = parseHex32(line[13 .. 21]);
            switch (line[0])
            {
            case 'a': result = softfloat.arith.add(a, b); break;
            case 's': result = softfloat.arith.sub(a, b); break;
            case 'm': result = softfloat.arith.mul(a, b); break;
            default:  result = softfloat.arith.div(a, b); break;
            }
        }
        formatHex32(result, output[o .. o + 9]);
        o += 9;
    }
    return output[0 .. o];
}

@safe pure nothrow @nogc:

/// The supported operations.
enum Op : ubyte { add, sub, mul, div, sqrt }

/// Applies `op` to the operands (`b` is ignored for `sqrt`).
uint execute(Op op, uint a, uint b = 0)
{
    final switch (op)
    {
    case Op.add:  return softfloat.arith.add(a, b);
    case Op.sub:  return softfloat.arith.sub(a, b);
    case Op.mul:  return softfloat.arith.mul(a, b);
    case Op.div:  return softfloat.arith.div(a, b);
    case Op.sqrt: return softfloat.arith.sqrt(a);
    }
}

private immutable char[16] hexDigits = "0123456789abcdef";

/// Decodes eight lowercase hex digits starting at `s[0]`.
uint parseHex32(scope const(ubyte)[] s)
{
    uint v = 0;
    foreach (i; 0 .. 8)
    {
        immutable c = s[i];
        immutable d = c <= '9' ? c - '0' : c - 'a' + 10;
        v = (v << 4) | d;
    }
    return v;
}

/// Writes `v` as eight lowercase hex digits followed by `\n` into `out_[0 .. 9]`.
void formatHex32(uint v, scope ubyte[] out_)
{
    foreach (i; 0 .. 8)
        out_[i] = hexDigits[(v >> (28 - 4 * i)) & 0xf];
    out_[8] = '\n';
}
