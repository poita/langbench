/// Cursors, selections and the normalisation that merges colliding cursors.
module textbuffer.cursor;

import std.algorithm.sorting : sort;
import std.algorithm.mutation : SwapStrategy;

import textbuffer.position;

/// A caret with an optional selection.
struct Cursor
{
    /// Where the caret is.
    Pos head;
    /// The other end of the selection; meaningful only if `hasSelection`.
    Pos anchor;
    /// Whether a (non-empty) selection exists.
    bool hasSelection;
    /// Exactly one cursor of a buffer is primary.
    bool primary;
    /// Remembered column for vertical movement.
    int goal;

    /// First position of the cursor's range.
    Pos start() const pure nothrow @nogc @safe
    {
        return hasSelection && anchor < head ? anchor : head;
    }

    /// Last position of the cursor's range.
    Pos end() const pure nothrow @nogc @safe
    {
        return hasSelection && head < anchor ? anchor : head;
    }

    /// True if the head is at the start of a non-empty selection.
    bool backward() const pure nothrow @nogc @safe
    {
        return hasSelection && head < anchor;
    }

    /// Removes the selection, leaving the head where it is.
    void collapse() pure nothrow @nogc @safe
    {
        hasSelection = false;
        anchor = head;
    }
}

private bool before(ref const Cursor a, ref const Cursor b) pure nothrow @nogc @safe
{
    immutable sa = a.start, sb = b.start;
    if (sa != sb)
        return sa < sb;
    return b.end < a.end;
}

/// Sorts cursors (start ascending, end descending, stable) and merges the
/// ones that collide, in place. The array is shrunk to the survivors.
void normalize(ref Cursor[] cs)
{
    if (cs.length < 2)
        return;

    bool ordered = true;
    foreach (i; 1 .. cs.length)
    {
        if (before(cs[i], cs[i - 1]))
        {
            ordered = false;
            break;
        }
    }
    if (!ordered)
        cs.sort!(before, SwapStrategy.stable)();

    size_t w = 0;
    Cursor cur = cs[0];
    Pos curStart = cur.start, curEnd = cur.end;
    foreach (i; 1 .. cs.length)
    {
        immutable c = cs[i];
        immutable cStart = c.start;
        immutable joins = (!cur.hasSelection || !c.hasSelection)
            ? cStart <= curEnd : cStart < curEnd;
        if (!joins)
        {
            cs[w++] = cur;
            cur = c;
            curStart = cStart;
            curEnd = c.end;
            continue;
        }
        immutable cEnd = c.end;
        if (curEnd < cEnd)
            curEnd = cEnd;
        if (curStart == curEnd)
        {
            cur.head = curStart;
            cur.hasSelection = false;
            cur.anchor = curStart;
        }
        else if (cur.backward)
        {
            cur.head = curStart;
            cur.anchor = curEnd;
            cur.hasSelection = true;
        }
        else
        {
            cur.head = curEnd;
            cur.anchor = curStart;
            cur.hasSelection = true;
        }
        cur.primary = cur.primary || c.primary;
    }
    cs[w++] = cur;
    if (w < cs.length)
    {
        cs = cs[0 .. w];
        assumeSafeAppend(cs);
    }
}

/// Overwrites `dst` with a copy of `src`, reusing `dst`'s storage if possible.
void assignCursors(ref Cursor[] dst, const Cursor[] src) nothrow
{
    dst.length = 0;
    assumeSafeAppend(dst);
    dst ~= src;
}
