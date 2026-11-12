/**
 * Vertical lists: the items the page breaker works on, plus the vertical
 * placement rule shared by body, footnote stacks and the table of contents.
 */
module typeset.vlist;

import typeset.line : Line;

/// One item of a vertical list.
struct VItem
{
    /// Item kind.
    enum Kind : ubyte
    {
        line,
        glue,
        rule,
        row,
        floatMark,
        forceBreak
    }

    Kind kind;
    int index; /// line: index into the line table; row: row index; floatMark: figure index
    long h; /// glue height, rule thickness, row height
    long x, w; /// rule geometry
    int k, n; /// line: 1-based index within its group, group size
    bool heading; /// line: group kind is `heading`
}

/// One line of a table cell and its baseline offset from the row's top.
struct CellLine
{
    int line;
    long offset;
}

/// A table row: its height and the lines of all its cells.
struct Row
{
    long height;
    CellLine[] cells;
}

/// A laid-out figure block; independent of where it is placed.
struct Figure
{
    long height; /// total block height (frame + caption)
    long fx, fw; /// frame x and width
    long frameHeight;
    bool frame;
    CellLine[] caption; /// caption lines, offsets relative to the block's top
}

/// A heading's data for the table of contents and running headers.
struct Heading
{
    int level;
    string number; /// number string, empty when unnumbered
    dstring plain; /// plain text
    bool unnumbered; /// written with `*`
    int page; /// 1-based body page of its first line (0 until paginated)
}

/// Tracks the vertical placement of successive items (the "cursor" loop of
/// the specification).
struct Placer
{
    long cursor;
    bool fresh = true;
    long prevBaseline;
    long prevDepth;
    long lineSkip;

    /// Places a line, returning its baseline.
    long line(long ascent, long depth, long leading) pure nothrow @safe @nogc
    {
        long baseline;
        if (fresh)
            baseline = cursor + ascent;
        else
        {
            immutable gap = prevDepth + lineSkip + ascent;
            baseline = prevBaseline + (leading > gap ? leading : gap);
        }
        cursor = baseline + depth;
        prevBaseline = baseline;
        prevDepth = depth;
        fresh = false;
        return baseline;
    }

    /// Adds vertical glue.
    void glue(long h) pure nothrow @safe @nogc
    {
        cursor += h;
        fresh = true;
    }

    /// Places a block (rule, row, frame) of height `h`, returning its top.
    long block(long h) pure nothrow @safe @nogc
    {
        immutable top = cursor;
        cursor += h;
        fresh = true;
        return top;
    }
}

/// Accumulates a vertical list with the `pending-max`/`pending-add` space
/// registers of the specification.
struct VBuilder
{
    VItem[] items;
    long pendingMax, pendingAdd;
    bool started;

    /// Entering or leaving a container: raises `pendingMax`.
    void raise(long space) pure nothrow @safe
    {
        if (space > pendingMax)
            pendingMax = space;
    }

    /// Starts a leaf block with the given space before and after.
    void leaf(long before, long after) pure nothrow @safe
    {
        raise(before);
        if (started && pendingMax + pendingAdd > 0)
        {
            VItem g;
            g.kind = VItem.Kind.glue;
            g.h = pendingMax + pendingAdd;
            items ~= g;
        }
        pendingMax = after;
        pendingAdd = 0;
        started = true;
    }

    /// Emits a forced page break and clears the space registers.
    void forceBreak() pure nothrow @safe
    {
        VItem f;
        f.kind = VItem.Kind.forceBreak;
        items ~= f;
        pendingMax = 0;
        pendingAdd = 0;
    }

    /// Appends the lines `first .. last` of one group.
    void lines(const Line[] table, int first, int last, bool heading) pure nothrow @safe
    {
        immutable n = last - first;
        foreach (i; first .. last)
        {
            VItem v;
            v.kind = VItem.Kind.line;
            v.index = i;
            v.k = i - first + 1;
            v.n = n;
            v.heading = heading;
            items ~= v;
        }
    }

    /// Appends a plain glue item.
    void glueItem(long h) pure nothrow @safe
    {
        VItem g;
        g.kind = VItem.Kind.glue;
        g.h = h;
        items ~= g;
    }
}
