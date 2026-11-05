/// Cell values: the small tagged union produced by evaluating a cell.
module spreadsheet.value;

import spreadsheet.numfmt : formatNumber;

/// Which kind of data a `Value` holds.
enum Kind : ubyte
{
    empty,    /// no value (an empty cell)
    number,   /// a finite IEEE-754 double
    text,     /// a string
    divZero,  /// the error `#DIV/0!`
    badRef,   /// the error `#REF!`
    cycle,    /// the error `#CYCLE!`
    badValue, /// the error `#VALUE!`
}

/// True if `k` is one of the four error kinds.
bool isErrorKind(Kind k) @safe pure nothrow @nogc
{
    return k >= Kind.divZero;
}

/// The displayed code of an error kind (e.g. `#DIV/0!`); empty for non-errors.
string errorCode(Kind k) @safe pure nothrow @nogc
{
    final switch (k)
    {
    case Kind.empty, Kind.number, Kind.text: return "";
    case Kind.divZero:  return "#DIV/0!";
    case Kind.badRef:   return "#REF!";
    case Kind.cycle:    return "#CYCLE!";
    case Kind.badValue: return "#VALUE!";
    }
}

/// A cell value.  Numbers and errors never allocate; text shares its string.
struct Value
{
    Kind kind = Kind.empty;
    double num = 0;
    string str;

    /// The empty value.
    static Value empty() @safe pure nothrow @nogc { return Value.init; }

    /// A number value.
    static Value number(double d) @safe pure nothrow @nogc
    {
        Value v;
        v.kind = Kind.number;
        v.num = d;
        return v;
    }

    /// A text value.
    static Value text(string s) @safe pure nothrow @nogc
    {
        Value v;
        v.kind = Kind.text;
        v.str = s;
        return v;
    }

    /// An error value; `k` must be an error kind.
    static Value error(Kind k) @safe pure nothrow @nogc
    in (isErrorKind(k))
    {
        Value v;
        v.kind = k;
        return v;
    }

    /// True for `#DIV/0!`, `#REF!`, `#CYCLE!` and `#VALUE!`.
    bool isError() const @safe pure nothrow @nogc { return isErrorKind(kind); }

    /// Append the displayed form of the value to an output range of `char`s.
    void display(Sink)(ref Sink sink) const
    {
        final switch (kind)
        {
        case Kind.empty: break;
        case Kind.number: formatNumber(num, sink); break;
        case Kind.text: sink.put(str); break;
        case Kind.divZero, Kind.badRef, Kind.cycle, Kind.badValue:
            sink.put(errorCode(kind));
            break;
        }
    }

    /// The displayed form as a string (empty for an empty value).
    string toString() const
    {
        import std.array : appender;
        auto app = appender!string();
        display(app);
        return app.data;
    }
}
