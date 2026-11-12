/**
 * The text protocol: parsing `<op> <a> [<b>]` lines of hexadecimal bit
 * patterns and formatting results as 8 lowercase hex digits.
 */
module softfloat.text;

import softfloat.addsub;
import softfloat.div;
import softfloat.mul;
import softfloat.sqrt;

/// The operations understood by $(LREF evaluateLine).
enum Operation
{
    add,
    sub,
    mul,
    div,
    sqrt,
}

/// Thrown when an input line is not a valid `<op> <a> [<b>]` line.
class ParseException : Exception
{
    /// 1-based line number, or 0 when unknown.
    size_t line;

    this(string msg, size_t line = 0, string file = __FILE__, size_t ln = __LINE__) @safe pure nothrow
    {
        super(msg, file, ln);
        this.line = line;
    }
}

/// Applies `op` to the bit patterns `a` and `b` (`b` is ignored by `sqrt`).
uint apply(Operation op, uint a, uint b = 0) @safe pure nothrow @nogc
{
    final switch (op)
    {
    case Operation.add:
        return softfloat.addsub.add(a, b);
    case Operation.sub:
        return softfloat.addsub.sub(a, b);
    case Operation.mul:
        return softfloat.mul.mul(a, b);
    case Operation.div:
        return softfloat.div.div(a, b);
    case Operation.sqrt:
        return softfloat.sqrt.sqrt(a);
    }
}

private int hexValue(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/**
 * Parses exactly 8 hexadecimal digits into a bit pattern.
 *
 * Returns: `true` on success; `value` is only valid then.
 */
bool parseHex32(const(char)[] text, out uint value) @safe pure nothrow @nogc
{
    value = 0;
    if (text.length != 8)
        return false;
    foreach (c; text)
    {
        immutable d = hexValue(c);
        if (d < 0)
            return false;
        value = (value << 4) | cast(uint) d;
    }
    return true;
}

/// Writes `value` as 8 lowercase hex digits into `buf`.
void formatHex32(uint value, ref char[8] buf) @safe pure nothrow @nogc
{
    static immutable digits = "0123456789abcdef";
    foreach (i; 0 .. 8)
        buf[i] = digits[(value >> (28 - 4 * i)) & 0xf];
}

private bool parseOperation(const(char)[] token, out Operation op) @safe pure nothrow @nogc
{
    switch (token)
    {
    case "add":
        op = Operation.add;
        return true;
    case "sub":
        op = Operation.sub;
        return true;
    case "mul":
        op = Operation.mul;
        return true;
    case "div":
        op = Operation.div;
        return true;
    case "sqrt":
        op = Operation.sqrt;
        return true;
    default:
        return false;
    }
}

/**
 * Evaluates one input line such as `add 3f800000 3f800000` or `sqrt 40000000`.
 *
 * Returns: the result bit pattern
 * Throws: $(LREF ParseException) if the line is malformed.
 */
uint evaluateLine(const(char)[] line) @safe pure
{
    // Split on single spaces into at most three tokens.
    const(char)[][3] tokens;
    size_t count = 0;
    size_t start = 0;
    foreach (i; 0 .. line.length + 1)
    {
        if (i == line.length || line[i] == ' ')
        {
            if (count == 3)
                throw new ParseException("too many fields: " ~ line.idup);
            tokens[count++] = line[start .. i];
            start = i + 1;
        }
    }

    Operation op;
    if (!parseOperation(tokens[0], op))
        throw new ParseException("unknown operation: " ~ line.idup);

    immutable expected = op == Operation.sqrt ? 2 : 3;
    if (count != expected)
        throw new ParseException("wrong number of operands: " ~ line.idup);

    uint a, b;
    if (!parseHex32(tokens[1], a))
        throw new ParseException("bad operand: " ~ line.idup);
    if (op != Operation.sqrt && !parseHex32(tokens[2], b))
        throw new ParseException("bad operand: " ~ line.idup);
    return apply(op, a, b);
}

/**
 * Evaluates every line of `input` and returns the output text: one 8-digit
 * lowercase hex result per line, each terminated by `\n`.
 *
 * Lines end in `\n`; the last line may omit it.  A trailing `\r` is
 * tolerated and empty lines are skipped.
 *
 * Throws: $(LREF ParseException), carrying the 1-based line number, on a
 * malformed line.
 */
char[] processInput(const(char)[] input) @safe pure
{
    auto output = new char[](input.length / 8 + 16); // grows as needed
    size_t used = 0;
    size_t lineNumber = 0;
    size_t pos = 0;
    while (pos < input.length)
    {
        size_t end = pos;
        while (end < input.length && input[end] != '\n')
            ++end;
        auto line = input[pos .. end];
        pos = end + 1;
        ++lineNumber;
        if (line.length && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        if (line.length == 0)
            continue;

        uint result;
        try
            result = evaluateLine(line);
        catch (ParseException e)
        {
            e.line = lineNumber;
            throw e;
        }

        if (used + 9 > output.length)
            output.length = output.length * 2;
        char[8] hex;
        formatHex32(result, hex);
        output[used .. used + 8] = hex[];
        output[used + 8] = '\n';
        used += 9;
    }
    return output[0 .. used];
}

unittest
{
    uint v;
    assert(parseHex32("3f800000", v) && v == 0x3f80_0000);
    assert(parseHex32("ffffffff", v) && v == uint.max);
    assert(!parseHex32("3f80000", v));
    assert(!parseHex32("3f8000000", v));
    assert(!parseHex32("3f80000g", v));
    char[8] buf;
    formatHex32(0x0000_beef, buf);
    assert(buf == "0000beef");
}

unittest
{
    assert(evaluateLine("add 3f800000 3f800000") == 0x4000_0000);
    assert(evaluateLine("sqrt 40000000") == 0x3fb5_04f3);
    assert(evaluateLine("div 3f800000 80000000") == 0xff80_0000);

    import std.exception : assertThrown;

    assertThrown!ParseException(evaluateLine("pow 3f800000 3f800000"));
    assertThrown!ParseException(evaluateLine("add 3f800000"));
    assertThrown!ParseException(evaluateLine("sqrt 3f800000 3f800000"));
    assertThrown!ParseException(evaluateLine("add 3f800000 3f80000"));
    assertThrown!ParseException(evaluateLine("add  3f800000 3f800000"));
    assertThrown!ParseException(evaluateLine(""));
}

unittest
{
    // SPEC.md, example 1, with and without a trailing newline.
    enum input = "add 3f800000 3f800000\nsub 3f800000 3f800000\n"
        ~ "mul 40400000 c0400000\ndiv 3f800000 40400000\nsqrt 40000000";
    enum expected = "40000000\n00000000\nc1100000\n3eaaaaab\n3fb504f3\n";
    assert(processInput(input) == expected);
    assert(processInput(input ~ "\n") == expected);
}

unittest
{
    // SPEC.md, example 2: special values and signed zeros.
    enum input = "add 7f800000 ff800000\nmul 7f800000 00000000\n"
        ~ "div 00000000 00000000\nsqrt 80000000\nsqrt bf800000\n"
        ~ "mul 00000000 bf800000\nadd 80000000 80000000\n"
        ~ "add 80000000 00000000\ndiv bf800000 00000000\n"
        ~ "add 7fc12345 3f800000\n";
    enum expected = "7fc00000\n7fc00000\n7fc00000\n80000000\n7fc00000\n"
        ~ "80000000\n80000000\n00000000\nff800000\n7fc00000\n";
    assert(processInput(input) == expected);
}

unittest
{
    // SPEC.md, example 3: rounding at the edges.
    enum input = "add 7f7fffff 73000000\nadd 7f7fffff 72ffffff\n"
        ~ "div 00000001 40000000\ndiv 00000003 40000000\n"
        ~ "add 3f800000 33800000\nadd 3f800001 33800000\n"
        ~ "add 3f800000 33000000\nmul 00000001 3f000000\n";
    enum expected = "7f800000\n7f7fffff\n00000000\n00000002\n"
        ~ "3f800000\n3f800002\n3f800000\n00000000\n";
    assert(processInput(input) == expected);
}

unittest
{
    import std.exception : assertThrown;

    try
    {
        processInput("add 3f800000 3f800000\nbogus\n");
        assert(false);
    }
    catch (ParseException e)
        assert(e.line == 2);
}
