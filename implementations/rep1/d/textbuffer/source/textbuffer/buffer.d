/// The text buffer: a document, a set of cursors and an undo history.
module textbuffer.buffer;

import std.algorithm.comparison : min;

import textbuffer.cursor;
import textbuffer.document;
import textbuffer.history;
import textbuffer.pos;

/// Cursor movement directions.
enum Direction
{
    left,
    right,
    up,
    down,
    home,
    end,
}

/// The editing core of a text editor.
///
/// Holds a document, a set of cursors (each with an optional selection) and
/// undo/redo history. All commands apply to every cursor. After each command
/// the cursor set is normalised, so cursors never overlap and are always
/// listed in cursor order (ascending range start).
final class TextBuffer
{
    private Document doc;
    private Cursor[] cs;
    private History hist;

    /// Creates a buffer from its lines (none means one empty line) with a
    /// single primary cursor at the start of the document.
    this(const(char)[][] lines = null) @safe nothrow
    {
        doc = new Document(lines);
        cs = [Cursor.at(Pos(0, 0), true)];
    }

    // ------------------------------------------------------------ inspection

    /// Number of lines (at least 1).
    size_t lineCount() const @safe nothrow @nogc
    {
        return doc.lineCount;
    }

    /// Text of line `i`, valid until the next editing command.
    const(char)[] line(size_t i) const @safe nothrow @nogc
    {
        return doc.line(i);
    }

    /// The whole text, lines joined by newlines.
    string text() const @safe
    {
        return doc.text;
    }

    /// The cursors in cursor order.
    const(Cursor)[] cursors() const @safe nothrow @nogc
    {
        return cs;
    }

    /// Whether `undo` would do anything.
    bool canUndo() const @safe nothrow @nogc
    {
        return hist.canUndo;
    }

    /// Whether `redo` would do anything.
    bool canRedo() const @safe nothrow @nogc
    {
        return hist.canRedo;
    }

    // --------------------------------------------------------------- editing

    /// Inserts `text` at every cursor, replacing selections. `text` may contain
    /// newlines; it must be printable ASCII otherwise.
    void insert(string text) @safe
    {
        if (text.length == 0)
        {
            finish();
            return;
        }
        edit(EditKind.insert, text);
    }

    /// Backspace: deletes each selection, or the character before each cursor.
    void deleteBackward() @safe
    {
        edit(EditKind.backward, "");
    }

    /// Delete: deletes each selection, or the character after each cursor.
    void deleteForward() @safe
    {
        edit(EditKind.forward, "");
    }

    // -------------------------------------------------------------- movement

    /// Moves every cursor; with `select` the selection is extended (or started).
    void move(Direction dir, bool select = false) @safe
    {
        foreach (ref c; cs)
            moveCursor(c, dir, select);
        normalize(cs);
        if (dir != Direction.up && dir != Direction.down)
            resetGoals();
    }

    /// Replaces all cursors by one primary cursor at the (clamped) position.
    void goTo(long line, long col) @safe
    {
        cs = [Cursor.at(doc.clamp(line, col), true)];
    }

    /// Adds a non-primary cursor at the (clamped) position; merges if it collides.
    void addCursor(long line, long col) @safe
    {
        cs ~= Cursor.at(doc.clamp(line, col));
        normalize(cs);
        resetGoals();
    }

    /// Removes every cursor except the primary one.
    void clearCursors() @safe
    {
        foreach (c; cs)
            if (c.primary)
            {
                cs = [c];
                break;
            }
        resetGoals();
    }

    // ------------------------------------------------------------ undo/redo

    /// Reverts the most recent edit command. Returns false if there was none.
    bool undo() @safe
    {
        if (!hist.canUndo)
        {
            resetGoals();
            return false;
        }
        auto e = hist.popUndo();
        foreach_reverse (ref r; e.replacements)
            doc.replace(r.start, endOfText(r.start, r.inserted), r.removed);
        cs = e.before.dup;
        resetGoals();
        return true;
    }

    /// Re-applies the most recently undone edit command. Returns false if there was none.
    bool redo() @safe
    {
        if (!hist.canRedo)
        {
            resetGoals();
            return false;
        }
        auto e = hist.popRedo();
        foreach (ref r; e.replacements)
            doc.replace(r.start, endOfText(r.start, r.removed), r.inserted);
        cs = e.after.dup;
        resetGoals();
        return true;
    }

    // ------------------------------------------------------------- internals

    private enum EditKind
    {
        insert,
        backward,
        forward,
    }

    /// Maps positions of the document as it was before an edit command into
    /// the document as it is now, through the composed effect of the
    /// replacements made so far. Only valid for positions at or after the end
    /// of the last replacement; O(1).
    private struct Shift
    {
        bool active;
        Pos oldEnd;  // end of the last replacement, before the command
        Pos newEnd;  // where its cursor ended up

        Pos map(Pos p) const @safe nothrow @nogc
        {
            if (!active)
                return p;
            if (p.line == oldEnd.line)
                return Pos(newEnd.line, newEnd.col + p.col - oldEnd.col);
            return Pos(p.line + newEnd.line - oldEnd.line, p.col);
        }
    }

    private void resetGoals() @safe nothrow @nogc
    {
        foreach (ref c; cs)
            c.goal = c.head.col;
    }

    private void finish() @safe
    {
        normalize(cs);
        resetGoals();
    }

    private void edit(EditKind kind, string ins) @safe
    {
        auto before = cs.dup;
        Replacement[] reps;
        Shift shift;
        immutable shape = TextShape.of(ins);

        foreach (ref c; cs)
        {
            Pos s, e, oldEnd;
            if (c.hasSelection)
            {
                s = shift.map(c.start);
                e = shift.map(c.end);
                oldEnd = c.end;
            }
            else
            {
                s = e = shift.map(c.head);
                oldEnd = c.head;
                if (kind == EditKind.backward && s != Pos(0, 0))
                    s = s.col > 0 ? Pos(s.line, s.col - 1)
                        : Pos(s.line - 1, cast(int) doc.lineLength(s.line - 1));
                else if (kind == EditKind.forward && s != doc.end)
                {
                    if (s.col < doc.lineLength(s.line))
                    {
                        e = Pos(s.line, s.col + 1);
                        oldEnd = Pos(c.head.line, c.head.col + 1);
                    }
                    else
                    {
                        e = Pos(s.line + 1, 0);
                        oldEnd = Pos(c.head.line + 1, 0);
                    }
                }
            }
            immutable text = kind == EditKind.insert ? ins : "";

            Pos newHead = s;
            if (s != e || text.length)
            {
                reps ~= Replacement(s, s != e ? doc.slice(s, e) : "", text);
                doc.replace(s, e, text);
                newHead = shape.endFrom(s);
            }
            shift = Shift(true, oldEnd, newHead);
            c.head = c.anchor = newHead;
            c.hasSelection = false;
        }

        finish();
        if (reps.length)
            hist.record(UndoEntry(before, cs.dup, reps));
    }

    private void moveCursor(ref Cursor c, Direction dir, bool select) @safe nothrow @nogc
    {
        if (!select && c.hasSelection && (dir == Direction.left || dir == Direction.right))
        {
            c.head = dir == Direction.left ? c.start : c.end;
            c.collapse();
            return;
        }
        if (!select)
            c.collapse();
        else if (!c.hasSelection)
            c.anchor = c.head;

        final switch (dir)
        {
        case Direction.left:
            if (c.head.col > 0)
                --c.head.col;
            else if (c.head.line > 0)
                c.head = Pos(c.head.line - 1, cast(int) doc.lineLength(c.head.line - 1));
            break;
        case Direction.right:
            if (c.head.col < doc.lineLength(c.head.line))
                ++c.head.col;
            else if (c.head.line + 1 < doc.lineCount)
                c.head = Pos(c.head.line + 1, 0);
            break;
        case Direction.home:
            c.head.col = 0;
            break;
        case Direction.end:
            c.head.col = cast(int) doc.lineLength(c.head.line);
            break;
        case Direction.up:
            if (c.head.line == 0)
            {
                c.head = Pos(0, 0);
                c.goal = 0;
            }
            else
                c.head = Pos(c.head.line - 1,
                    cast(int) min(cast(size_t) c.goal, doc.lineLength(c.head.line - 1)));
            break;
        case Direction.down:
            if (c.head.line + 1 == doc.lineCount)
            {
                c.head = doc.end;
                c.goal = c.head.col;
            }
            else
                c.head = Pos(c.head.line + 1,
                    cast(int) min(cast(size_t) c.goal, doc.lineLength(c.head.line + 1)));
            break;
        }

        if (select)
            c.hasSelection = c.head != c.anchor;
        else
            c.anchor = c.head;
    }
}

version (unittest)
{
    private TextBuffer make(const(char)[][] lines...) @safe nothrow
    {
        return new TextBuffer(lines);
    }

    private string describe(const TextBuffer b) @safe
    {
        import std.format : format;
        import std.array : appender;

        auto app = appender!string();
        app.put(b.text);
        foreach (c; b.cursors)
        {
            app.put(c.hasSelection
                ? format!" [%d:%d-%d:%d%s]"(c.anchor.line, c.anchor.col, c.head.line,
                    c.head.col, c.primary ? "*" : "")
                : format!" [%d:%d%s]"(c.head.line, c.head.col, c.primary ? "*" : ""));
        }
        return app[];
    }
}

@safe unittest
{
    // Single-cursor typing and movement (spec example 1).
    auto b = make("hello world", "second line");
    b.move(Direction.end);
    b.insert("!");
    b.move(Direction.down);
    b.insert(" (edited)");
    b.goTo(0, 5);
    b.insert(",");
    assert(b.text == "hello, world!\nsecond line (edited)");
    assert(b.cursors[0].head == Pos(0, 6));
    b.deleteBackward();
    b.deleteBackward();
    assert(b.text == "hell world!\nsecond line (edited)");
    assert(b.cursors[0].head == Pos(0, 4));
}

@safe unittest
{
    // Multiple cursors and selections (spec example 2).
    auto b = make("alpha", "beta", "gamma");
    b.addCursor(1, 0);
    b.addCursor(2, 0);
    b.insert("- ");
    assert(b.text == "- alpha\n- beta\n- gamma");
    assert(b.cursors.length == 3 && b.cursors[2].head == Pos(2, 2));
    b.move(Direction.end, true);
    b.insert("X");
    assert(b.text == "- X\n- X\n- X");
    b.goTo(0, 1);
    b.move(Direction.right, true);
    b.move(Direction.right, true);
    b.deleteBackward();
    assert(b.text == "-\n- X\n- X");
    assert(b.cursors.length == 1 && b.cursors[0].head == Pos(0, 1));
}

@safe unittest
{
    // Undo and redo (spec example 3).
    auto b = make("abc");
    b.move(Direction.end);
    b.insert("d\ne");
    assert(b.text == "abcd\ne" && b.cursors[0].head == Pos(1, 1));
    b.deleteBackward();
    b.deleteBackward();
    assert(b.text == "abcd");
    assert(b.undo());
    assert(b.text == "abcd\n" && b.cursors[0].head == Pos(1, 0));
    assert(b.undo());
    assert(b.text == "abcd\ne" && b.cursors[0].head == Pos(1, 1));
    assert(b.redo());
    assert(b.text == "abcd\n");
    b.insert("Z");
    assert(!b.redo());
    assert(b.text == "abcd\nZ");
}

@safe unittest
{
    // Adjacent cursors both deleting backwards end up merged (spec note).
    auto b = make("abcdef");
    b.goTo(0, 3);
    b.addCursor(0, 4);
    b.deleteBackward();
    assert(b.text == "abef");
    assert(b.cursors.length == 1 && b.cursors[0].head == Pos(0, 2));
    b.undo();
    assert(b.text == "abcdef");
    assert(b.cursors.length == 2);
    assert(b.cursors[0].head == Pos(0, 3) && b.cursors[1].head == Pos(0, 4));
    assert(b.cursors[0].primary && !b.cursors[1].primary);
}

@safe unittest
{
    // Forward delete at line ends joins lines; at the end of the document it is a no-op.
    auto b = make("ab", "cd", "ef");
    b.move(Direction.end);
    b.addCursor(1, 2);
    b.deleteForward();
    assert(b.text == "abcdef");
    assert(b.cursors.length == 2 && b.cursors[1].head == Pos(0, 4));
    b.goTo(0, 6);
    b.deleteForward();
    assert(b.canUndo);  // the no-op delete recorded nothing; the earlier edit remains
    assert(b.text == "abcdef");
    b.undo();
    assert(b.text == "ab\ncd\nef");
    assert(!b.canUndo);
    b.undo();  // nothing left
    assert(b.text == "ab\ncd\nef");
}

@safe unittest
{
    // Goal column is remembered across vertical moves and reset by other commands.
    auto b = make("abcdefgh", "ab", "abcdefgh");
    b.goTo(0, 6);
    b.move(Direction.down);
    assert(b.cursors[0].head == Pos(1, 2));
    b.move(Direction.down);
    assert(b.cursors[0].head == Pos(2, 6));
    b.move(Direction.up);
    b.move(Direction.left);
    b.move(Direction.down);
    assert(b.cursors[0].head == Pos(2, 1));
    // Edges.
    b.move(Direction.down);
    assert(b.cursors[0].head == Pos(2, 8) && b.cursors[0].goal == 8);
    b.goTo(0, 3);
    b.move(Direction.up);
    assert(b.cursors[0].head == Pos(0, 0) && b.cursors[0].goal == 0);
}

@safe unittest
{
    // Selection movement rules.
    auto b = make("abcdef");
    b.goTo(0, 2);
    b.move(Direction.right, true);
    b.move(Direction.right, true);
    assert(describe(b) == "abcdef [0:2-0:4*]");
    b.move(Direction.left);  // collapses to the start
    assert(describe(b) == "abcdef [0:2*]");
    b.move(Direction.right, true);
    b.move(Direction.left, true);  // selection becomes empty again
    assert(describe(b) == "abcdef [0:2*]");
    b.move(Direction.right, true);
    b.move(Direction.home);  // selection dropped, head moves from the head
    assert(describe(b) == "abcdef [0:0*]");
}

@safe unittest
{
    // Cursors merging on move, and clear-cursors keeps the primary one.
    auto b = make("abc");
    b.goTo(0, 1);
    b.addCursor(0, 3);
    b.addCursor(0, 2);
    assert(b.cursors.length == 3);
    b.move(Direction.home);
    assert(b.cursors.length == 1 && b.cursors[0].primary);
    b.addCursor(0, 2);
    b.addCursor(0, 3);
    b.clearCursors();
    assert(describe(b) == "abc [0:0*]");
}

@safe unittest
{
    // Randomised round trip: undoing every edit restores the initial state, redoing
    // every edit restores the final state, and the cursor invariants always hold.
    import std.random : Random, uniform;

    auto rng = Random(1234);
    foreach (round; 0 .. 40)
    {
        auto b = make("one two three", "", "four", "five six");
        immutable initialText = b.text;
        size_t edits = 0;
        foreach (step; 0 .. 120)
        {
            switch (uniform(0, 11, rng))
            {
            case 0: b.insert("ab"); break;
            case 1: b.insert("x\ny\n"); break;
            case 2: b.deleteBackward(); break;
            case 3: b.deleteForward(); break;
            case 4: b.move(cast(Direction) uniform(0, 6, rng), uniform(0, 2, rng) == 1); break;
            case 5: b.addCursor(uniform(0, 8, rng), uniform(0, 20, rng)); break;
            case 6: b.goTo(uniform(0, 8, rng), uniform(0, 20, rng)); break;
            case 7: b.clearCursors(); break;
            case 8: b.move(cast(Direction) uniform(0, 6, rng), true); break;
            case 9: b.insert("\\"); break;
            default: b.deleteBackward(); break;
            }
            // Invariants: exactly one primary, ordered, non-overlapping, valid.
            size_t primaries;
            foreach (i, c; b.cursors)
            {
                primaries += c.primary;
                assert(c.head.line < b.lineCount && c.head.col <= b.line(c.head.line).length);
                if (i > 0)
                    assert(b.cursors[i - 1].start < c.start);
            }
            assert(primaries == 1);
        }
        immutable finalText = b.text;
        size_t undone;
        while (b.undo())
            ++undone;
        assert(b.text == initialText);
        size_t redone;
        while (b.redo())
            ++redone;
        assert(undone == redone);
        assert(b.text == finalText);
    }
}
