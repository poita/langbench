/**
 * Scanning and canonical formatting of TOML integers and floats.
 *
 * Integers are validated and converted by hand (with overflow checks against
 * the signed 64-bit range). Floats are validated by hand and converted with
 * the C library's correctly rounding `strtod`; they are printed with
 * `snprintf("%.16e")`, giving the 17-significant-digit canonical form.
 */
module toml.numbers;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import std.math : isInfinity, isNaN;

private bool isDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private bool isHex(char c) @safe pure nothrow @nogc
{
    return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

private uint hexVal(char c) @safe pure nothrow @nogc
{
    if (isDigit(c)) return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return c - 'A' + 10;
}

/// The decimal text of an unsigned magnitude, with a `-` when `negative`.
private string decimalText(ulong mag, bool negative) @safe pure nothrow
{
    char[24] buf;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + mag % 10);
        mag /= 10;
    } while (mag != 0);
    return (negative ? "-" : "") ~ buf[i .. $].idup;
}

/**
 * Scans `digit ( "_"? digit )*` at `s[i..]`. Advances `i` past the run.
 * Returns false if there is no digit or an underscore is not between digits.
 */
private bool scanDigits(alias pred)(const(char)[] s, ref size_t i) @safe pure nothrow @nogc
{
    if (i >= s.length || !pred(s[i]))
        return false;
    i++;
    while (i < s.length)
    {
        if (pred(s[i]))
            i++;
        else if (s[i] == '_' && i + 1 < s.length && pred(s[i + 1]))
            i += 2;
        else
            break;
    }
    return true;
}

/// Scans a decimal integer part (no leading zeros) at `s[i..]`.
private bool scanDecimalInt(const(char)[] s, ref size_t i) @safe pure nothrow @nogc
{
    if (i >= s.length)
        return false;
    if (s[i] == '0')
    {
        i++;
        return true;
    }
    if (s[i] < '1' || s[i] > '9')
        return false;
    return scanDigits!isDigit(s, i);
}

/// Parses an integer literal (any base). Returns false when malformed or out
/// of the signed 64-bit range; otherwise `canon` is its decimal text.
bool parseInteger(const(char)[] s, out string canon) @safe pure nothrow
{
    if (s.length == 0)
        return false;
    ulong mag = 0;
    bool negative = false;
    size_t i = 0;
    uint base = 10;
    if (s.length > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'o' || s[1] == 'b'))
    {
        base = s[1] == 'x' ? 16 : s[1] == 'o' ? 8 : 2;
        i = 2;
        bool ok;
        size_t j = i;
        if (base == 16)
            ok = scanDigits!isHex(s, j);
        else if (base == 8)
            ok = scanDigits!(c => c >= '0' && c <= '7')(s, j);
        else
            ok = scanDigits!(c => c == '0' || c == '1')(s, j);
        if (!ok || j != s.length)
            return false;
    }
    else
    {
        if (s[0] == '+' || s[0] == '-')
        {
            negative = s[0] == '-';
            i = 1;
        }
        size_t j = i;
        if (!scanDecimalInt(s, j) || j != s.length)
            return false;
    }
    immutable ulong limit = (negative ? 1UL << 63 : (1UL << 63) - 1);
    foreach (c; s[i .. $])
    {
        if (c == '_')
            continue;
        immutable d = hexVal(c);
        if (mag > (limit - d) / base)
            return false;
        mag = mag * base + d;
    }
    canon = decimalText(mag, negative && mag != 0);
    return true;
}

/// Formats a double in the canonical text form: `nan`, `inf`, `-inf`, or
/// exactly 17 significant digits in scientific notation (`%.16e`).
string formatFloat(double x) @trusted
{
    if (isNaN(x))
        return "nan";
    if (isInfinity(x))
        return x < 0 ? "-inf" : "inf";
    char[64] buf;
    immutable n = snprintf(buf.ptr, buf.length, "%.16e", x);
    assert(n > 0 && n < buf.length);
    return buf[0 .. n].idup;
}

/// Parses a float literal (including `inf`/`nan` forms). Returns false when
/// malformed; otherwise `canon` is the canonical text.
bool parseFloat(const(char)[] s, out string canon) @trusted
{
    switch (s)
    {
    case "inf": case "+inf":
        canon = "inf";
        return true;
    case "-inf":
        canon = "-inf";
        return true;
    case "nan": case "+nan": case "-nan":
        canon = "nan";
        return true;
    default:
        break;
    }
    size_t i = 0;
    if (s.length && (s[0] == '+' || s[0] == '-'))
        i = 1;
    if (!scanDecimalInt(s, i))
        return false;
    bool seen = false;
    if (i < s.length && s[i] == '.')
    {
        i++;
        if (!scanDigits!isDigit(s, i))
            return false;
        seen = true;
    }
    if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
    {
        i++;
        if (i < s.length && (s[i] == '+' || s[i] == '-'))
            i++;
        if (!scanDigits!isDigit(s, i))
            return false;
        seen = true;
    }
    if (!seen || i != s.length)
        return false;
    char[] clean;
    clean.reserve(s.length + 1);
    foreach (c; s)
        if (c != '_')
            clean ~= c;
    clean ~= '\0';
    canon = formatFloat(strtod(clean.ptr, null));
    return true;
}

unittest
{
    string c;
    assert(parseInteger("0", c) && c == "0");
    assert(parseInteger("-0", c) && c == "0");
    assert(parseInteger("+42", c) && c == "42");
    assert(parseInteger("1_000", c) && c == "1000");
    assert(parseInteger("0xDEAD_beef", c) && c == "3735928559");
    assert(parseInteger("0o755", c) && c == "493");
    assert(parseInteger("0b1101", c) && c == "13");
    assert(parseInteger("9223372036854775807", c) && c == "9223372036854775807");
    assert(parseInteger("-9223372036854775808", c) && c == "-9223372036854775808");
    assert(!parseInteger("9223372036854775808", c));
    assert(!parseInteger("-9223372036854775809", c));
    assert(parseInteger("0x7FFFFFFFFFFFFFFF", c) && c == "9223372036854775807");
    assert(!parseInteger("0xFFFFFFFFFFFFFFFF", c));
    assert(!parseInteger("01", c));
    assert(!parseInteger("+01", c));
    assert(!parseInteger("1__0", c));
    assert(!parseInteger("_1", c));
    assert(!parseInteger("1_", c));
    assert(!parseInteger("0X1", c));
    assert(!parseInteger("-0x1", c));
    assert(!parseInteger("0b2", c));
    assert(!parseInteger("0x", c));
    assert(!parseInteger("", c));
}

unittest
{
    string c;
    assert(parseFloat("1.0", c) && c == "1.0000000000000000e+00");
    assert(parseFloat("3.1415", c) && c == "3.1415000000000002e+00");
    assert(parseFloat("-0.0", c) && c == "-0.0000000000000000e+00");
    assert(parseFloat("0e0", c) && c == "0.0000000000000000e+00");
    assert(parseFloat("0e00", c));
    assert(parseFloat("1e308", c) && c == "1.0000000000000000e+308");
    assert(parseFloat("6.626e-34", c) && c == "6.6259999999999998e-34");
    assert(parseFloat("5e-324", c) && c == "4.9406564584124654e-324");
    assert(parseFloat("1e999", c) && c == "inf" || c == "inf");
    assert(parseFloat("-1e999", c) && c == "-inf");
    assert(parseFloat("1e-999", c) && c == "0.0000000000000000e+00");
    assert(parseFloat("224_617.445_991_228", c) && c == "2.2461744599122801e+05");
    assert(parseFloat("-nan", c) && c == "nan");
    assert(parseFloat("+inf", c) && c == "inf");
    assert(!parseFloat(".5", c));
    assert(!parseFloat("5.", c));
    assert(!parseFloat("1.e2", c));
    assert(!parseFloat("1e", c));
    assert(!parseFloat("01.5", c));
    assert(!parseFloat("1_.5", c));
    assert(!parseFloat("1._5", c));
    assert(!parseFloat("1e_5", c));
    assert(!parseFloat("Inf", c));
    assert(!parseFloat("NaN", c));
    assert(!parseFloat("1", c));
}
