module test_cursor;

import textbuffer.cursor;
import textbuffer.position;

private Cursor point(int line, int col, bool primary = false, int goal = 0)
{
    return Cursor(Pos(line, col), Pos(line, col), false, primary, goal);
}

private Cursor sel(Pos anchor, Pos head, bool primary = false)
{
    return Cursor(head, anchor, true, primary, 0);
}

unittest // range accessors
{
    auto f = sel(Pos(0, 1), Pos(0, 4));
    assert(f.start == Pos(0, 1) && f.end == Pos(0, 4) && !f.backward);
    auto b = sel(Pos(0, 4), Pos(0, 1));
    assert(b.start == Pos(0, 1) && b.end == Pos(0, 4) && b.backward);
    auto p = point(2, 2);
    assert(p.start == p.end && !p.backward);
    b.collapse();
    assert(!b.hasSelection && b.anchor == b.head);
}

unittest // sorting
{
    auto cs = [point(2, 0), point(0, 5, true), point(1, 1)];
    normalize(cs);
    assert(cs.length == 3);
    assert(cs[0].head == Pos(0, 5) && cs[1].head == Pos(1, 1) && cs[2].head == Pos(2, 0));
}

unittest // points on the same position merge, primary wins
{
    auto cs = [point(0, 3), point(0, 3, true)];
    normalize(cs);
    assert(cs.length == 1 && cs[0].primary);
}

unittest // equal ranges keep the first goal column
{
    auto cs = [point(0, 3, false, 10), point(0, 3, false, 20)];
    normalize(cs);
    assert(cs.length == 1 && cs[0].goal == 10);
}

unittest // a point inside or at the edge of a selection merges into it
{
    foreach (col; [1, 2, 3, 4])
    {
        auto cs = [sel(Pos(0, 1), Pos(0, 4)), point(0, col)];
        normalize(cs);
        assert(cs.length == 1);
        assert(cs[0].start == Pos(0, 1) && cs[0].end == Pos(0, 4));
        assert(!cs[0].backward);
    }
    auto outside = [sel(Pos(0, 1), Pos(0, 4)), point(0, 5)];
    normalize(outside);
    assert(outside.length == 2);
}

unittest // touching selections stay apart, overlapping ones merge
{
    auto touch = [sel(Pos(0, 0), Pos(0, 2)), sel(Pos(0, 2), Pos(0, 4))];
    normalize(touch);
    assert(touch.length == 2);

    auto overlap = [sel(Pos(0, 0), Pos(0, 3)), sel(Pos(0, 2), Pos(0, 6), true)];
    normalize(overlap);
    assert(overlap.length == 1);
    assert(overlap[0].start == Pos(0, 0) && overlap[0].end == Pos(0, 6));
    assert(overlap[0].primary);
}

unittest // the merged selection keeps the first cursor's direction
{
    auto cs = [sel(Pos(0, 3), Pos(0, 0)), sel(Pos(0, 2), Pos(0, 6))];
    normalize(cs);
    assert(cs.length == 1);
    assert(cs[0].backward);
    assert(cs[0].head == Pos(0, 0) && cs[0].anchor == Pos(0, 6));
}

unittest // a longer selection sorts before a shorter one with the same start
{
    auto cs = [sel(Pos(0, 0), Pos(0, 2)), sel(Pos(0, 0), Pos(0, 5))];
    normalize(cs);
    assert(cs.length == 1 && cs[0].end == Pos(0, 5));
}

unittest // assignCursors copies
{
    auto a = [point(0, 0)];
    Cursor[] b;
    assignCursors(b, a);
    a[0].head = Pos(9, 9);
    assert(b.length == 1 && b[0].head == Pos(0, 0));
    assignCursors(b, [point(1, 1), point(2, 2)]);
    assert(b.length == 2);
}
