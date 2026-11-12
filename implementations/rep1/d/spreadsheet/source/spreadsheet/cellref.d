/**
 * Cell addresses (`A1`, `ZZ9999`) and their compact integer keys.
 *
 * A column is one or two uppercase letters (`A`..`Z`, `AA`..`ZZ`, columns
 * 1..702) and a row is 1..9999.  A $(LREF CellRef) packs both into a single
 * integer key whose numeric order is row-major order, which makes it cheap
 * to hash, sort and iterate over rectangular ranges.
 */
module spreadsheet.cellref;

/// Largest valid column number (`ZZ`).
enum maxColumn = 702;
/// Largest valid row number.
enum maxRow = 9999;

/// A valid cell address.  Compare with `==` / `<`; ordering is row-major.
struct CellRef
{
    /// 1-based column number, `A` = 1, `Z` = 26, `AA` = 27, ..., `ZZ` = 702.
    ushort column;
    /// 1-based row number.
    ushort row;

    /// Packs the address into an integer; numeric order is row-major order.
    @property uint key() const pure nothrow @nogc @safe
    {
        return (cast(uint) row << 10) | column;
    }

    /// Inverse of $(LREF key).
    static CellRef fromKey(uint key) pure nothrow @nogc @safe
    {
        return CellRef(cast(ushort)(key & 1023), cast(ushort)(key >> 10));
    }

    int opCmp(const CellRef other) const pure nothrow @nogc @safe
    {
        const a = key, b = other.key;
        return a < b ? -1 : (a > b ? 1 : 0);
    }

    /// The textual name, e.g. `"AB12"`.
    string toString() const pure nothrow @safe
    {
        char[2] letters;
        size_t n;
        if (column > 26)
            letters[n++] = cast(char)('A' + (column - 1) / 26 - 1);
        letters[n++] = cast(char)('A' + (column - 1) % 26);
        char[5] digits;
        size_t d = digits.length;
        uint r = row;
        do
        {
            digits[--d] = cast(char)('0' + r % 10);
            r /= 10;
        }
        while (r);
        return (letters[0 .. n] ~ digits[d .. $]).idup;
    }
}

/**
 * Parses a cell name.
 *
 * Params:
 *     text = candidate name such as `"B7"`
 *     result = receives the address on success
 * Returns: `true` if `text` is a valid cell name (at most two uppercase
 * letters, then a row 1..9999 without leading zeros, and nothing else).
 */
bool tryParseCellRef(const(char)[] text, out CellRef result) pure nothrow @nogc @safe
{
    size_t i;
    uint col;
    while (i < text.length && text[i] >= 'A' && text[i] <= 'Z')
    {
        if (i == 2)
            return false;
        col = col * 26 + (text[i] - 'A' + 1);
        i++;
    }
    if (i == 0 || i == text.length || text[i] == '0')
        return false;
    uint row;
    while (i < text.length && text[i] >= '0' && text[i] <= '9')
    {
        row = row * 10 + (text[i] - '0');
        if (row > maxRow)
            return false;
        i++;
    }
    if (i != text.length)
        return false;
    result = CellRef(cast(ushort) col, cast(ushort) row);
    return true;
}

///
@safe pure unittest
{
    CellRef r;
    assert(tryParseCellRef("A1", r) && r == CellRef(1, 1));
    assert(tryParseCellRef("ZZ9999", r) && r == CellRef(702, 9999));
    assert(tryParseCellRef("AB123", r) && r.column == 28 && r.row == 123);
    assert(r.toString == "AB123");
}

@safe pure unittest
{
    CellRef r;
    foreach (bad; ["", "A", "1", "AAA1", "A0", "A01", "A10000", "a1", "A1B", "A-1"])
        assert(!tryParseCellRef(bad, r), bad);
    assert(CellRef(26, 5).toString == "Z5");
    assert(CellRef(27, 10).toString == "AA10");
    assert(CellRef(702, 9999).toString == "ZZ9999");
    assert(CellRef.fromKey(CellRef(30, 77).key) == CellRef(30, 77));
    assert(CellRef(702, 1) < CellRef(1, 2));
}
