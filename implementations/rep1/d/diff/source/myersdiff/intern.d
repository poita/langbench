/// Line interning: maps each distinct line to a small integer id so that
/// the diff search can compare lines in O(1).
module myersdiff.intern;

/// A line of text (not necessarily valid UTF-8; compared byte-for-byte).
alias Line = const(char)[];

/**
 * Assigns consecutive integer ids (starting at 0) to distinct lines.
 *
 * Interned lines are not copied: the caller must keep the underlying
 * memory alive and unchanged while the `Interner` is in use.
 */
struct Interner
{
    private int[Line] ids;

    /// Number of distinct lines seen so far.
    @property size_t length() const @safe pure nothrow @nogc { return ids.length; }

    /// Returns the id of `line`, allocating a new one if it is unseen.
    int intern(Line line) @safe pure nothrow
    {
        if (auto p = line in ids)
            return *p;
        const id = cast(int) ids.length;
        ids[line] = id;
        return id;
    }
}

/// Interns every line of `lines`, returning the id sequence.
int[] internLines(ref Interner interner, scope const(Line)[] lines) @safe pure nothrow
{
    auto r = new int[lines.length];
    foreach (i, l; lines)
        r[i] = interner.intern(l);
    return r;
}

///
@safe pure nothrow unittest
{
    Interner t;
    auto a = t.internLines(["x", "y", "x", ""]);
    auto b = t.internLines(["", "y", "z"]);
    assert(a == [0, 1, 0, 2]);
    assert(b == [2, 1, 3]);
    assert(t.length == 4);
    // Whitespace is significant.
    assert(t.intern("x ") == 4);
}
