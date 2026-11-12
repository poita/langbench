/// Cursors, selections and the normalisation that merges colliding cursors.
module textbuffer.cursor;

import std.algorithm.comparison : max, min;
import std.algorithm.sorting : sort;
import std.algorithm.mutation : SwapStrategy;

import textbuffer.pos;

/// A caret with an optional selection.
struct Cursor
{
    /// Where the caret is.
    Pos head;
    /// The other end of the selection; equal to `head` when there is none.
    Pos anchor;
    /// Whether a selection is present (the anchor then differs from the head).
    bool hasSelection;
    /// Exactly one cursor of a set is primary.
    bool primary;
    /// Goal column used by vertical movement.
    int goal;

    /// A cursor without selection at `p`.
    static Cursor at(Pos p, bool primary = false) @safe pure nothrow @nogc
    {
        return Cursor(p, p, false, primary, p.col);
    }

    /// Start of the range (the head when there is no selection).
    Pos start() const @safe pure nothrow @nogc
    {
        return hasSelection ? min(head, anchor) : head;
    }

    /// End of the range (the head when there is no selection).
    Pos end() const @safe pure nothrow @nogc
    {
        return hasSelection ? max(head, anchor) : head;
    }

    /// Whether the selection extends before the head.
    bool backward() const @safe pure nothrow @nogc
    {
        return hasSelection && head < anchor;
    }

    /// Drops the selection, keeping the head.
    void collapse() @safe pure nothrow @nogc
    {
        anchor = head;
        hasSelection = false;
    }

    /// Sets the range with the given direction; an empty range has no selection.
    void setRange(Pos start, Pos end, bool backward) @safe pure nothrow @nogc
    {
        if (start == end)
        {
            head = anchor = start;
            hasSelection = false;
        }
        else
        {
            hasSelection = true;
            head = backward ? start : end;
            anchor = backward ? end : start;
        }
    }
}

/// Cursor order: range start ascending, then range end descending.
private bool inOrder(const Cursor a, const Cursor b) @safe pure nothrow @nogc
{
    immutable sa = a.start, sb = b.start;
    return sa < sb || (sa == sb && a.end > b.end);
}

/// Normalises a cursor set in place: a stable sort into cursor order followed by
/// one sweep merging cursors whose ranges collide. O(C log C), O(C) when
/// already ordered.
void normalize(ref Cursor[] cs) @safe pure
{
    if (cs.length < 2)
        return;
    bool ordered = true;
    foreach (i; 1 .. cs.length)
        if (inOrder(cs[i], cs[i - 1]))
        {
            ordered = false;
            break;
        }
    if (!ordered)
        sort!(inOrder, SwapStrategy.stable)(cs);

    size_t w = 0;  // index of the current group's merged cursor
    foreach (i; 1 .. cs.length)
    {
        immutable c = cs[i];
        auto cur = &cs[w];
        immutable joins = (!cur.hasSelection || !c.hasSelection)
            ? c.start <= cur.end : c.start < cur.end;
        if (joins)
        {
            immutable newEnd = max(cur.end, c.end);
            immutable backward = cur.backward;
            cur.setRange(cur.start, newEnd, backward);
            cur.primary = cur.primary || c.primary;
        }
        else
            cs[++w] = c;
    }
    cs = cs[0 .. w + 1];
}

version (unittest)
{
    private Cursor sel(Pos a, Pos h, bool primary = false) @safe pure nothrow @nogc
    {
        auto c = Cursor.at(h, primary);
        c.anchor = a;
        c.hasSelection = true;
        return c;
    }
}

@safe pure unittest
{
    // Point cursors on the same spot merge; primary survives.
    auto cs = [Cursor.at(Pos(0, 3), true), Cursor.at(Pos(0, 3)), Cursor.at(Pos(1, 0))];
    normalize(cs);
    assert(cs.length == 2);
    assert(cs[0].primary && !cs[1].primary);
}

@safe pure unittest
{
    // Sorting by start; point cursor inside a selection merges (even at edges).
    auto cs = [Cursor.at(Pos(2, 0)), sel(Pos(0, 1), Pos(0, 5)), Cursor.at(Pos(0, 5), true)];
    normalize(cs);
    assert(cs.length == 2);
    assert(cs[0].hasSelection && cs[0].head == Pos(0, 5) && cs[0].primary);
    assert(cs[1].head == Pos(2, 0));
}

@safe pure unittest
{
    // Selections that only touch end-to-start stay separate; overlapping ones merge.
    auto cs = [sel(Pos(0, 0), Pos(0, 3)), sel(Pos(0, 3), Pos(0, 6))];
    normalize(cs);
    assert(cs.length == 2);
    cs = [sel(Pos(0, 0), Pos(0, 4)), sel(Pos(0, 6), Pos(0, 3))];
    normalize(cs);
    assert(cs.length == 1);
    // Direction of the first cursor in sorted order wins.
    assert(cs[0].start == Pos(0, 0) && cs[0].end == Pos(0, 6) && cs[0].head == Pos(0, 6));
}

@safe pure unittest
{
    // Same start: the larger range comes first and absorbs the other.
    auto a = Cursor.at(Pos(0, 2));
    a.goal = 7;
    auto cs = [a, sel(Pos(0, 2), Pos(0, 5))];
    normalize(cs);
    assert(cs.length == 1 && cs[0].hasSelection && cs[0].end == Pos(0, 5));
    // Equal ranges keep the earlier cursor's goal column.
    auto x = Cursor.at(Pos(1, 1));
    x.goal = 4;
    auto y = Cursor.at(Pos(1, 1));
    y.goal = 9;
    cs = [x, y];
    normalize(cs);
    assert(cs.length == 1 && cs[0].goal == 4);
}
