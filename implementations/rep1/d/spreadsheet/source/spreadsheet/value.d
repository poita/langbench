/**
 * Cell values and their textual display.
 */
module spreadsheet.value;

import core.stdc.stdio : snprintf;
import std.math : isFinite;

/// The four error codes a cell can evaluate to.
enum ErrorCode : ubyte
{
    divZero, /// `#DIV/0!`
    ref_,    /// `#REF!`
    cycle,   /// `#CYCLE!`
    value,   /// `#VALUE!`
}

/// The display text of an error code, e.g. `"#DIV/0!"`.
string errorText(ErrorCode code) pure nothrow @nogc @safe
{
    final switch (code)
    {
    case ErrorCode.divZero: return "#DIV/0!";
    case ErrorCode.ref_:    return "#REF!";
    case ErrorCode.cycle:   return "#CYCLE!";
    case ErrorCode.value:   return "#VALUE!";
    }
}

/// What kind of thing a $(LREF Value) holds.
enum ValueKind : ubyte
{
    empty,  /// no value (an empty cell)
    number, /// a finite double
    text,   /// a string
    error,  /// an $(LREF ErrorCode)
}

/**
 * A spreadsheet value: empty, a number, a string or an error.
 *
 * Construct with the static helpers $(LREF Value.makeNumber),
 * $(LREF Value.makeText), $(LREF Value.makeError); the default value is empty.
 */
struct Value
{
    /// Which member is meaningful.
    ValueKind kind = ValueKind.empty;
    /// Valid when `kind == ValueKind.number`.
    double number = 0;
    /// Valid when `kind == ValueKind.text`.
    string text;
    /// Valid when `kind == ValueKind.error`.
    ErrorCode error;

    /// A number value.
    static Value makeNumber(double v) pure nothrow @nogc @safe
    {
        Value r;
        r.kind = ValueKind.number;
        r.number = v;
        return r;
    }

    /// A string value.
    static Value makeText(string s) pure nothrow @nogc @safe
    {
        Value r;
        r.kind = ValueKind.text;
        r.text = s;
        return r;
    }

    /// An error value.
    static Value makeError(ErrorCode e) pure nothrow @nogc @safe
    {
        Value r;
        r.kind = ValueKind.error;
        r.error = e;
        return r;
    }

    @property bool isEmpty() const pure nothrow @nogc @safe { return kind == ValueKind.empty; }
    @property bool isNumber() const pure nothrow @nogc @safe { return kind == ValueKind.number; }
    @property bool isText() const pure nothrow @nogc @safe { return kind == ValueKind.text; }
    @property bool isError() const pure nothrow @nogc @safe { return kind == ValueKind.error; }

    /// The displayed form of the value (see $(LREF formatNumber)); empty displays as `""`.
    string toString() const nothrow @safe
    {
        final switch (kind)
        {
        case ValueKind.empty:  return "";
        case ValueKind.number: return formatNumber(number);
        case ValueKind.text:   return text;
        case ValueKind.error:  return errorText(error);
        }
    }
}

/**
 * Formats a number for display.
 *
 * Zero is `0`; an integral value below 1e15 in magnitude is written as a
 * plain integer; anything else is exactly C's `printf("%.10g")`.
 */
string formatNumber(double v) nothrow @trusted
{
    if (v == 0)
        return "0";
    if ((v < 0 ? -v : v) < 1e15 && v == cast(long) v)
        return formatInteger(cast(long) v);
    // %.10g never needs more than 17 characters ("-1.234567890e-300" is 16).
    char[40] buf;
    const n = snprintf(buf.ptr, buf.length, "%.10g".ptr, v);
    assert(n > 0 && n < buf.length);
    return buf[0 .. n].idup;
}

private string formatInteger(long v) pure nothrow @safe
{
    char[24] digits;
    size_t i = digits.length;
    const neg = v < 0;
    ulong u = neg ? -cast(ulong) v : cast(ulong) v;
    do
    {
        digits[--i] = cast(char)('0' + u % 10);
        u /= 10;
    }
    while (u);
    if (neg)
        digits[--i] = '-';
    return digits[i .. $].idup;
}

@safe nothrow unittest
{
    // every example from the display rules
    assert(formatNumber(0.0) == "0");
    assert(formatNumber(-0.0) == "0");
    assert(formatNumber(42) == "42");
    assert(formatNumber(-7) == "-7");
    assert(formatNumber(123456789012345) == "123456789012345");
    assert(formatNumber(1e14) == "100000000000000");
    assert(formatNumber(1e15) == "1e+15");
    assert(formatNumber(1e20) == "1e+20");
    assert(formatNumber(-1.5e15) == "-1.5e+15");
    assert(formatNumber(1.23456789e15) == "1.23456789e+15");
    assert(formatNumber(0.00001) == "1e-05");
    assert(formatNumber(2.5e-10) == "2.5e-10");
    assert(formatNumber(0.5) == "0.5");
    assert(formatNumber(1234567.891) == "1234567.891");
    assert(formatNumber(1.0 / 3) == "0.3333333333");
    assert(formatNumber(2.0 / 3) == "0.6666666667");
    assert(formatNumber(0.0001234) == "0.0001234");
    assert(formatNumber(-2.5) == "-2.5");
    assert(formatNumber(1234567890.4) == "1234567890");
    assert(formatNumber(1234567890.5) == "1234567890"); // tie rounds to even
    assert(formatNumber(2500000000.75) == "2500000001");
    assert(formatNumber(1200000000.4) == "1200000000");
    assert(formatNumber(9999999999.7) == "1e+10");
}

@safe nothrow unittest
{
    assert(Value().toString == "");
    assert(Value.makeNumber(3.5).toString == "3.5");
    assert(Value.makeText("hi").toString == "hi");
    assert(Value.makeError(ErrorCode.cycle).toString == "#CYCLE!");
    assert(Value().isEmpty && Value.makeNumber(1).isNumber);
}
