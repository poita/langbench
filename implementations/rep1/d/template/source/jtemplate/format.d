/// Conversion of values to text: printing (`{{ x }}`), `repr`, and the
/// shortest-round-trip float layout of the specification.
module jtemplate.format;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;

import jtemplate.buffer;
import jtemplate.errors;
import jtemplate.value;

/// Append the printed form of `v` (as `{{ v }}` shows it). Throws an
/// `undefined` error for the undefined value.
void putValue(ref OutBuf out_, Value v)
{
    switch (v.kind)
    {
        case Kind.str:      out_.put(v.s); break;
        case Kind.integer:  out_.putInt(v.i); break;
        case Kind.floating: putFloat(out_, v.d); break;
        case Kind.boolean:  out_.put(v.i ? "True" : "False"); break;
        case Kind.none:     out_.put("None"); break;
        case Kind.list:
            out_.put('[');
            foreach (k, ref e; v.list)
            {
                if (k) out_.put(", ");
                putRepr(out_, e);
            }
            out_.put(']');
            break;
        case Kind.dict:
            out_.put('{');
            foreach (k, key; v.dict.keys)
            {
                if (k) out_.put(", ");
                putQuoted(out_, key);
                out_.put(": ");
                putRepr(out_, v.dict.vals[k]);
            }
            out_.put('}');
            break;
        case Kind.macro_:   out_.put("<macro "); out_.put(v.mac.node.name); out_.put('>'); break;
        case Kind.rangeFn: out_.put("<built-in range>"); break;
        case Kind.superFn: out_.put("<super>"); break;
        case Kind.loop:    out_.put("<loop>"); break;
        default:
            throw undefinedError("printing the undefined value");
    }
}

/// Append the `repr` of `v`: like [putValue] but strings are quoted.
void putRepr(ref OutBuf out_, Value v)
{
    if (v.kind == Kind.str)
        putQuoted(out_, v.s);
    else
        putValue(out_, v);
}

/// Append a string in Python `repr` style.
void putQuoted(ref OutBuf out_, const(char)[] s)
{
    bool hasSingle, hasDouble;
    foreach (c; s)
    {
        if (c == '\'') hasSingle = true;
        else if (c == '"') hasDouble = true;
    }
    immutable quote = hasSingle && !hasDouble ? '"' : '\'';
    out_.put(quote);
    size_t runStart = 0;
    foreach (i, c; s)
    {
        string rep;
        switch (c)
        {
            case '\\': rep = "\\\\"; break;
            case '\n': rep = "\\n"; break;
            case '\r': rep = "\\r"; break;
            case '\t': rep = "\\t"; break;
            default:
                if (c == quote) rep = "\\'";
                break;
        }
        if (rep !is null)
        {
            out_.put(s[runStart .. i]);
            out_.put(rep);
            runStart = i + 1;
        }
    }
    out_.put(s[runStart .. $]);
    out_.put(quote);
}

/// The printed form of a value as a string (strings are returned as is).
string toStr(Value v)
{
    if (v.kind == Kind.str)
        return v.s;
    OutBuf b;
    putValue(b, v);
    return b.take();
}

/// Append a double: the shortest digit string that round-trips, laid out as
/// Python's `repr(float)` does (`3.0`, `0.1`, `1e+16`, `1.5e-05`).
void putFloat(ref OutBuf out_, double x) @trusted
{
    import core.stdc.math : isinf, isnan, signbit;
    if (isnan(x)) { out_.put("nan"); return; }
    if (isinf(x)) { out_.put(x < 0 ? "-inf" : "inf"); return; }
    if (x == 0)
    {
        out_.put(signbit(x) ? "-0.0" : "0.0");
        return;
    }
    if (x < 0)
    {
        out_.put('-');
        x = -x;
    }

    char[40] buf = void;
    char[24] digits = void;
    int ndigits = 0;
    int exp10 = 0;

    // 15 significant digits round-trip whenever the shortest form has at most
    // 15; otherwise 16, then 17 (which always does). Subnormals carry fewer
    // significant digits, so for them search upwards from one digit.
    foreach (prec; (x < double.min_normal ? 1 : 15) .. 18)
    {
        snprintf(buf.ptr, buf.length, "%.*e", prec - 1, x);
        if (prec == 17 || strtod(buf.ptr, null) == x)
        {
            ndigits = splitExp(buf, digits, exp10);
            break;
        }
        if (prec == 16)
        {
            // A different 16-digit string may round-trip when the nearest
            // one does not (asymmetric interval at powers of two).
            ndigits = splitExp(buf, digits, exp10);
            if (neighbourRoundTrips(x, digits, ndigits, exp10))
                break;
            ndigits = 0;
        }
    }

    while (ndigits > 1 && digits[ndigits - 1] == '0')
        --ndigits;

    if (exp10 >= -4 && exp10 < 16)
    {
        if (exp10 < 0)
        {
            out_.put("0.");
            foreach (_; 0 .. -exp10 - 1) out_.put('0');
            out_.put(digits[0 .. ndigits]);
        }
        else
        {
            immutable intDigits = exp10 + 1;
            if (ndigits <= intDigits)
            {
                out_.put(digits[0 .. ndigits]);
                foreach (_; 0 .. intDigits - ndigits) out_.put('0');
                out_.put(".0");
            }
            else
            {
                out_.put(digits[0 .. intDigits]);
                out_.put('.');
                out_.put(digits[intDigits .. ndigits]);
            }
        }
    }
    else
    {
        out_.put(digits[0]);
        if (ndigits > 1)
        {
            out_.put('.');
            out_.put(digits[1 .. ndigits]);
        }
        out_.put('e');
        int e = exp10;
        if (e < 0) { out_.put('-'); e = -e; } else out_.put('+');
        if (e < 10) out_.put('0');
        out_.putInt(e);
    }
}

/// Split "d.ddde+XX" into its digits and decimal exponent.
private int splitExp(in char[40] buf, ref char[24] digits, out int exp10) @trusted pure nothrow @nogc
{
    int n = 0;
    size_t i = 0;
    while (buf[i] != 'e' && buf[i] != '\0')
    {
        if (buf[i] != '.') digits[n++] = buf[i];
        ++i;
    }
    int e = 0;
    bool neg = false;
    if (buf[i] == 'e')
    {
        ++i;
        if (buf[i] == '-') { neg = true; ++i; }
        else if (buf[i] == '+') ++i;
        while (buf[i] >= '0' && buf[i] <= '9')
            e = e * 10 + (buf[i++] - '0');
    }
    exp10 = neg ? -e : e;
    return n;
}

/// For a 16-digit candidate, try the two adjacent 16-digit strings; if one
/// round-trips, store it in `digits` and return true.
private bool neighbourRoundTrips(double x, ref char[24] digits, int ndigits, ref int exp10)
    @trusted
{
    if (ndigits != 16) return false;
    ulong n = 0;
    foreach (i; 0 .. 16) n = n * 10 + (digits[i] - '0');
    foreach (delta; [cast(long) 1, -1])
    {
        immutable m = cast(ulong)(cast(long) n + delta);
        if (m < 1_000_000_000_000_000UL || m >= 10_000_000_000_000_000UL)
            continue;
        char[40] tmp = void;
        // m * 10^(exp10 - 15) is the candidate's value.
        snprintf(tmp.ptr, tmp.length, "%llue%d", m, exp10 - 15);
        if (strtod(tmp.ptr, null) == x)
        {
            ulong rest = m;
            for (int i = 15; i >= 0; --i)
            {
                digits[i] = cast(char)('0' + rest % 10);
                rest /= 10;
            }
            return true;
        }
    }
    return false;
}
