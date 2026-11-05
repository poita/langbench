/// Cell names such as `A1` or `ZZ9999`.
module spreadsheet.cellref;

/// Highest valid column (`ZZ`) and row.
enum uint maxColumn = 702, maxRow = 9999;

/// Multiplier of the row in a cell key; keys sort in row-major order.
enum uint keyStride = 703;

/// A cell position.  `col` is 1..702 (`A`..`ZZ`), `row` is 1..9999.
struct CellRef
{
    ushort col;
    ushort row;

    /// Row-major sortable key: `row * 703 + col`.
    uint key() const @safe pure nothrow @nogc { return row * keyStride + col; }

    /// Inverse of `key`.
    static CellRef fromKey(uint key) @safe pure nothrow @nogc
    {
        return CellRef(cast(ushort)(key % keyStride), cast(ushort)(key / keyStride));
    }

    /// Append the cell name (e.g. `AB12`) to an output range of `char`s.
    void toString(Sink)(ref Sink sink) const
    {
        char[8] buf = void;
        size_t n = 0;
        if (col > 26)
            buf[n++] = cast(char)('A' + (col - 1) / 26 - 1);
        buf[n++] = cast(char)('A' + (col - 1) % 26);
        char[4] digits = void;
        size_t d = digits.length;
        uint r = row;
        while (r != 0)
        {
            digits[--d] = cast(char)('0' + r % 10);
            r /= 10;
        }
        buf[n .. n + digits.length - d] = digits[d .. $];
        n += digits.length - d;
        sink.put(buf[0 .. n]);
    }

    /// The cell name as a string.
    string toString() const @safe
    {
        import std.array : appender;
        auto app = appender!string();
        toString(app);
        return app.data;
    }
}

/**
 * Parse a cell name: one or two uppercase letters then a row number 1..9999
 * without leading zeros.  Returns false (leaving `ref_` unspecified) if `s`
 * is not a valid name.
 */
bool tryParseCellRef(const(char)[] s, out CellRef ref_) @safe pure nothrow @nogc
{
    size_t i = 0;
    uint col = 0;
    while (i < s.length && s[i] >= 'A' && s[i] <= 'Z')
    {
        if (i == 2)
            return false;
        col = col * 26 + (s[i] - 'A' + 1);
        i++;
    }
    if (i == 0)
        return false;
    size_t digitsStart = i;
    uint row = 0;
    while (i < s.length && s[i] >= '0' && s[i] <= '9')
    {
        if (i - digitsStart >= 4)
            return false;
        row = row * 10 + (s[i] - '0');
        i++;
    }
    if (i == digitsStart || i != s.length)
        return false;
    if (s[digitsStart] == '0' || row < 1 || row > maxRow)
        return false;
    ref_ = CellRef(cast(ushort) col, cast(ushort) row);
    return true;
}
