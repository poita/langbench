module test_buffer;

import textbuffer.buffer;
import textbuffer.cursor;
import textbuffer.position;
import textbuffer.vec;

private string heads(const TextBuffer b)
{
    import std.conv : to;
    string r;
    foreach (ref c; b.cursors)
        r ~= "(" ~ c.head.line.to!string ~ "," ~ c.head.col.to!string ~ ")";
    return r;
}

unittest // a new buffer
{
    auto b = new TextBuffer;
    assert(b.lineCount == 1 && b.text == "");
    assert(b.cursors.length == 1 && b.cursors[0].primary);
    assert(!b.canUndo && !b.canRedo);
    assert(TextBuffer.fromText("a\nb\n").text == "a\nb\n");
    assert(TextBuffer.fromText("a\nb\n").lineCount == 3);
}

unittest // clamping
{
    auto b = TextBuffer.fromText("abc\nde");
    assert(b.clamp(0, 99) == Pos(0, 3));
    assert(b.clamp(99, 99) == Pos(1, 2));
    assert(b.clamp(1, 1) == Pos(1, 1));
    b.goTo(1_000_000_000, 1_000_000_000);
    assert(heads(b) == "(1,2)");
}

unittest // insert, delete, delete-forward
{
    auto b = TextBuffer.fromText("hello");
    b.move(Direction.end);
    b.insert("!");
    assert(b.text == "hello!");
    b.deleteBackward();
    b.deleteBackward();
    assert(b.text == "hell");
    b.goTo(0, 0);
    b.deleteBackward(); // nothing to delete
    assert(b.text == "hell" && !b.canRedo);
    b.deleteForward();
    assert(b.text == "ell");
    b.move(Direction.end);
    b.deleteForward(); // end of document
    assert(b.text == "ell");
}

unittest // newlines join and split
{
    auto b = TextBuffer.fromText("ab\ncd");
    b.goTo(1, 0);
    b.deleteBackward();
    assert(b.text == "abcd" && heads(b) == "(0,2)");
    b.insert("\n");
    assert(b.text == "ab\ncd" && heads(b) == "(1,0)");
    b.goTo(0, 2);
    b.deleteForward();
    assert(b.text == "abcd");
}

unittest // movement and goal column
{
    auto b = TextBuffer.fromText("long line\nx\nlonger line");
    b.goTo(0, 7);
    b.move(Direction.down);
    assert(heads(b) == "(1,1)");
    b.move(Direction.down);
    assert(heads(b) == "(2,7)");
    b.move(Direction.down);
    assert(heads(b) == "(2,11)"); // end of the document sets the goal
    b.move(Direction.up);
    b.move(Direction.up);
    b.move(Direction.up);
    b.move(Direction.up);
    assert(heads(b) == "(0,0)");
    b.move(Direction.left);
    assert(heads(b) == "(0,0)");
    b.move(Direction.end);
    b.move(Direction.right);
    assert(heads(b) == "(1,0)");
    b.move(Direction.left);
    assert(heads(b) == "(0,9)");
    b.move(Direction.home);
    assert(heads(b) == "(0,0)");
}

unittest // selections collapse towards the requested side
{
    auto b = TextBuffer.fromText("abcdef");
    b.goTo(0, 2);
    b.move(Direction.right, true);
    b.move(Direction.right, true);
    assert(b.cursors[0].hasSelection && b.cursors[0].anchor == Pos(0, 2));
    b.move(Direction.left);
    assert(heads(b) == "(0,2)" && !b.cursors[0].hasSelection);

    b.goTo(0, 4);
    b.move(Direction.left, true);
    b.move(Direction.left, true);
    b.move(Direction.right);
    assert(heads(b) == "(0,4)");

    b.move(Direction.left, true);
    b.move(Direction.right, true);
    assert(!b.cursors[0].hasSelection); // head came back to the anchor
}

unittest // typing over a selection
{
    auto b = TextBuffer.fromText("abcdef");
    b.goTo(0, 1);
    b.move(Direction.right, true);
    b.move(Direction.right, true);
    b.insert("XYZ");
    assert(b.text == "aXYZdef" && heads(b) == "(0,4)");
    b.undo();
    assert(b.text == "abcdef");
    assert(b.cursors[0].hasSelection && b.cursors[0].head == Pos(0, 3));
}

unittest // multiple cursors on several lines
{
    auto b = TextBuffer.fromText("a\nb\nc");
    b.addCursor(1, 0);
    b.addCursor(2, 0);
    assert(b.cursors.length == 3);
    b.insert("> ");
    assert(b.text == "> a\n> b\n> c" && heads(b) == "(0,2)(1,2)(2,2)");
    b.insert("1\n2");
    assert(b.text == "> 1\n2a\n> 1\n2b\n> 1\n2c");
    b.undo();
    b.undo();
    assert(b.text == "a\nb\nc" && heads(b) == "(0,0)(1,0)(2,0)");
    b.redo();
    assert(b.text == "> a\n> b\n> c");
}

unittest // several cursors in one line: shifting
{
    auto b = TextBuffer.fromText("abcdef");
    b.addCursor(0, 2);
    b.addCursor(0, 4);
    b.insert("--");
    assert(b.text == "--ab--cd--ef" && heads(b) == "(0,2)(0,6)(0,10)");
    b.deleteBackward();
    b.deleteBackward();
    assert(b.text == "abcdef" && heads(b) == "(0,0)(0,2)(0,4)");
}

unittest // adjacent cursors deleting merge
{
    auto b = TextBuffer.fromText("abcdef");
    b.goTo(0, 3);
    b.addCursor(0, 4);
    b.deleteBackward();
    assert(b.text == "abef");
    assert(b.cursors.length == 1 && heads(b) == "(0,2)");
}

unittest // adding a cursor on an existing one does nothing
{
    auto b = TextBuffer.fromText("abc");
    b.goTo(0, 1);
    b.addCursor(0, 1);
    assert(b.cursors.length == 1 && b.cursors[0].primary);
}

unittest // clear-cursors keeps the primary cursor, with its selection
{
    auto b = TextBuffer.fromText("abcdef");
    b.goTo(0, 1);
    b.move(Direction.right, true);
    b.addCursor(0, 5);
    assert(b.cursors.length == 2);
    b.clearCursors();
    assert(b.cursors.length == 1 && b.cursors[0].primary && b.cursors[0].hasSelection);
}

unittest // undo/redo bookkeeping
{
    auto b = TextBuffer.fromText("x");
    assert(!b.undo() && !b.redo());
    b.insert("a");
    b.insert("b");
    assert(b.canUndo && !b.canRedo);
    assert(b.undo() && b.text == "ax" && b.canRedo);
    assert(b.redo() && b.text == "abx");
    b.undo();
    b.insert("c"); // clears redo
    assert(!b.canRedo && b.text == "acx");
    b.undo();
    b.undo();
    assert(b.text == "x" && !b.canUndo);
}

unittest // undo keeps cursors that were not part of the edit consistent
{
    auto b = TextBuffer.fromText("ab\ncd");
    b.goTo(1, 0);
    b.deleteBackward();
    assert(b.text == "abcd");
    b.undo();
    assert(b.text == "ab\ncd" && heads(b) == "(1,0)");
}

unittest // goal column is reset by commands other than vertical moves
{
    auto b = TextBuffer.fromText("abcdef\nx\nabcdef");
    b.goTo(0, 5);
    b.move(Direction.down);
    assert(b.cursors[0].goal == 5);
    b.move(Direction.down);
    assert(heads(b) == "(2,5)");
    b.move(Direction.up);
    b.move(Direction.left); // resets the goal to the column of the head
    assert(b.cursors[0].goal == 0);
}

unittest // render
{
    auto b = TextBuffer.fromText("ab\n\nc");
    b.addCursor(2, 1);
    CharBuf o;
    b.render(o);
    assert(o[] == "ab\n\nc\ncursor 0 0\ncursor 2 1\n--\n");
}

// Random commands followed by undoing everything must restore the document,
// and redoing everything must reproduce the final document.
unittest
{
    import std.random : Mt19937, uniform;

    foreach (seed; 0 .. 50)
    {
        auto rng = Mt19937(seed);
        auto b = TextBuffer.fromText("alpha\nbeta\n\ngamma delta\nx");
        immutable original = b.text;
        foreach (step; 0 .. 120)
        {
            switch (uniform(0, 12, rng))
            {
            case 0: b.insert("ab"); break;
            case 1: b.insert("q\nr"); break;
            case 2: b.deleteBackward(); break;
            case 3: b.deleteForward(); break;
            case 4: b.move(cast(Direction) uniform(0, 6, rng), uniform(0, 2, rng) == 1); break;
            case 5: b.addCursor(uniform(0, 8, rng), uniform(0, 8, rng)); break;
            case 6: b.goTo(uniform(0, 8, rng), uniform(0, 8, rng)); break;
            case 7: b.clearCursors(); break;
            case 8: b.insert(" "); break;
            case 9: b.move(Direction.right, true); break;
            default: b.move(cast(Direction) uniform(0, 6, rng)); break;
            }
            // Invariants of the cursor set.
            size_t primaries;
            foreach (i, ref c; b.cursors)
            {
                if (c.primary) ++primaries;
                if (c.hasSelection) assert(c.head != c.anchor);
                if (i > 0) assert(b.cursors[i - 1].start < c.start);
                assert(c.head.line >= 0 && c.head.line < cast(int) b.lineCount);
                assert(c.head.col >= 0 && c.head.col <= cast(int) b.line(c.head.line).length);
            }
            assert(primaries == 1);
        }
        immutable finalText = b.text;
        while (b.undo()) {}
        assert(b.text == original);
        while (b.redo()) {}
        assert(b.text == finalText);
        while (b.undo()) {}
        assert(b.text == original);
    }
}
