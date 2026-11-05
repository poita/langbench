/// Line interning: map each distinct line to a dense integer id.
module mdiff.intern;

/**
 * Maps line contents to dense `int` ids (0, 1, 2, ... in order of first
 * appearance). Equal lines (byte for byte) get equal ids, so later equality
 * tests are single integer comparisons.
 *
 * The interner stores `line` slices without copying: the memory they refer to
 * must stay alive and unchanged while the interner is used.
 */
struct Interner
{
    private int[const(char)[]] ids;

    /// The id of `line`, assigning the next free id if it is new.
    int intern(const(char)[] line) @safe pure nothrow
    {
        if (auto p = line in ids)
            return *p;
        immutable id = cast(int) ids.length;
        ids[line] = id;
        return id;
    }

    /// Interns every line; returns the ids in order.
    int[] internAll(scope const(const(char)[])[] lines) @safe pure nothrow
    {
        auto result = new int[lines.length];
        foreach (i, l; lines)
            result[i] = intern(l);
        return result;
    }

    /// The number of distinct lines seen so far.
    size_t length() const @safe pure nothrow @nogc
    {
        return ids.length;
    }
}
