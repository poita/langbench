module test_position;

import textbuffer.position;

unittest
{
    assert(Pos(1, 5) < Pos(2, 0));
    assert(Pos(2, 0) > Pos(1, 99));
    assert(Pos(2, 3) < Pos(2, 4));
    assert(Pos(2, 3) == Pos(2, 3));
    assert(minPos(Pos(1, 1), Pos(0, 9)) == Pos(0, 9));
    assert(maxPos(Pos(1, 1), Pos(0, 9)) == Pos(1, 1));
}

unittest
{
    immutable one = shapeOf("abc");
    assert(one.newlines == 0 && one.lastLineLength == 3 && one.length == 3);
    assert(advance(Pos(4, 2), one) == Pos(4, 5));

    immutable multi = shapeOf("ab\ncde\nf");
    assert(multi.newlines == 2 && multi.lastLineLength == 1 && multi.length == 8);
    assert(advance(Pos(4, 2), multi) == Pos(6, 1));

    immutable trailing = shapeOf("x\n");
    assert(advance(Pos(0, 7), trailing) == Pos(1, 0));

    immutable none = shapeOf("");
    assert(advance(Pos(3, 3), none) == Pos(3, 3));
}
