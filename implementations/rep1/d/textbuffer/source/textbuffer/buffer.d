/// The editing core: a document, a set of cursors and an undo history.
module textbuffer.buffer;

import core.stdc.string : memchr;

import textbuffer.cursor;
import textbuffer.history;
import textbuffer.lines;
import textbuffer.position;
import textbuffer.vec;

/// Direction of a cursor movement.
enum Direction
{
    left,
    right,
    up,
    down,
    home,
    end,
}

/// A text document with multiple cursors, selections, undo and redo.
///
/// All positions passed to the public API are clamped to the document, so no
/// call can fail. Every command normalises the cursor set (merging cursors
/// that collide) and, except for vertical movement, resets the goal columns.
final class TextBuffer
{
    private LineStore lines_;
    private Cursor[] cursors_;
    private Cursor[] beforeScratch;
    private Vec!Replacement replScratch;
    private CharBuf removedScratch;
    private Stack!HistoryEntry undoStack;
    private Stack!HistoryEntry redoStack;

    /// Creates a document with one empty line and one cursor at the start.
    this()
    {
        this(null);
    }

    /// Creates a document from `initial` lines (an empty list is one empty
    /// line). Lines must not contain newlines; they are copied.
    this(const(char)[][] initial)
    {
        lines_ = new LineStore(initial);
        cursors_ = [Cursor(Pos(0, 0), Pos(0, 0), false, true, 0)];
    }

    /// Creates a document from text, split at `'\n'`.
    static TextBuffer fromText(const(char)[] text)
    {
        const(char)[][] parts;
        size_t from = 0;
        foreach (i, ch; text)
        {
            if (ch == '\n')
            {
                parts ~= text[from .. i];
                from = i + 1;
            }
        }
        parts ~= text[from .. $];
        return new TextBuffer(parts);
    }

    // ------------------------------------------------------------ queries

    /// Number of lines (at least 1).
    size_t lineCount() const pure nothrow @nogc @safe { return lines_.length; }

    /// The text of line `i`. Invalidated by the next edit.
    const(char)[] line(size_t i) const pure nothrow @nogc @safe { return lines_[i].view; }

    /// The whole text, lines joined by `'\n'`.
    string text() const
    {
        CharBuf b;
        lines_.writeText(b);
        return b[].idup;
    }

    /// The cursors in cursor order. Invalidated by the next command.
    const(Cursor)[] cursors() const pure nothrow @nogc @safe { return cursors_; }

    /// True if there is an edit that `undo` would revert.
    bool canUndo() const pure nothrow @nogc @safe { return !undoStack.empty; }

    /// True if there is an edit that `redo` would re-apply.
    bool canRedo() const pure nothrow @nogc @safe { return !redoStack.empty; }

    /// Clamps `(line, col)` to a valid position.
    Pos clamp(long line, long col) const pure nothrow @nogc @safe
    {
        if (line < 0) line = 0;
        if (line > cast(long) lines_.length - 1) line = cast(long) lines_.length - 1;
        if (col < 0) col = 0;
        immutable len = cast(long) lines_.lineLength(cast(size_t) line);
        if (col > len) col = len;
        return Pos(cast(int) line, cast(int) col);
    }

    /// Writes the document, then one `cursor <line> <col>` line per cursor,
    /// then `--` to `output`.
    void render(ref CharBuf output) const nothrow
    {
        foreach (i; 0 .. lines_.length)
        {
            output.put(lines_[i].view);
            output.put('\n');
        }
        foreach (ref c; cursors_)
        {
            output.put("cursor ");
            output.putDecimal(c.head.line);
            output.put(' ');
            output.putDecimal(c.head.col);
            output.put('\n');
        }
        output.put("--\n");
    }

    // ------------------------------------------------------------ editing

    /// Inserts `text` (which may contain `'\n'`) at every cursor, replacing
    /// selections. Does nothing if `text` is empty and no cursor has a selection.
    void insert(const(char)[] text)
    {
        edit(EditKind.insert, text.idup);
    }

    /// Backspace: deletes each selection, or the character before each cursor.
    void deleteBackward()
    {
        edit(EditKind.backward, "");
    }

    /// Deletes each selection, or the character after each cursor.
    void deleteForward()
    {
        edit(EditKind.forward, "");
    }

    // ----------------------------------------------------------- movement

    /// Moves every cursor; with `select`, extends (or starts) selections.
    void move(Direction dir, bool select = false)
    {
        foreach (ref c; cursors_)
            moveCursor(c, dir, select);
        normalize(cursors_);
        if (dir != Direction.up && dir != Direction.down)
            resetGoals();
    }

    /// Replaces all cursors with one primary cursor at the clamped position.
    void goTo(long line, long col)
    {
        immutable p = clamp(line, col);
        cursors_.length = 1;
        cursors_[0] = Cursor(p, p, false, true, p.col);
    }

    /// Adds a non-primary cursor at the clamped position (merging if it
    /// collides with an existing cursor).
    void addCursor(long line, long col)
    {
        immutable p = clamp(line, col);
        cursors_ ~= Cursor(p, p, false, false, 0);
        normalize(cursors_);
        resetGoals();
    }

    /// Removes every cursor except the primary one.
    void clearCursors()
    {
        size_t w = 0;
        foreach (ref c; cursors_)
            if (c.primary)
                cursors_[w++] = c;
        cursors_ = cursors_[0 .. w];
        resetGoals();
    }

    // ------------------------------------------------------- undo / redo

    /// Reverts the most recent edit command. Returns false if there is none.
    bool undo()
    {
        if (undoStack.empty)
        {
            resetGoals();
            return false;
        }
        auto e = undoStack.pop();
        foreach_reverse (ref r; e.replacements)
        {
            immutable end = advance(r.start, e.insertedShape);
            lines_.splice(r.start, end, e.removed[r.removedOffset .. r.removedOffset + r.removedLength]);
        }
        assignCursors(cursors_, e.cursorsBefore);
        resetGoals();
        redoStack.push(e);
        return true;
    }

    /// Re-applies the most recently undone edit. Returns false if there is none.
    bool redo()
    {
        if (redoStack.empty)
        {
            resetGoals();
            return false;
        }
        auto e = redoStack.pop();
        foreach (ref r; e.replacements)
        {
            auto removed = e.removed[r.removedOffset .. r.removedOffset + r.removedLength];
            immutable end = advance(r.start, shapeOf(removed));
            lines_.splice(r.start, end, e.inserted);
        }
        assignCursors(cursors_, e.cursorsAfter);
        resetGoals();
        undoStack.push(e);
        return true;
    }

    // ----------------------------------------------------------- internals

    private enum EditKind { insert, backward, forward }

    private void resetGoals() pure nothrow @nogc @safe
    {
        foreach (ref c; cursors_)
            c.goal = c.head.col;
    }

    private void edit(EditKind kind, string inserted)
    {
        assignCursors(beforeScratch, cursors_);
        replScratch.clear();
        removedScratch.clear();

        // Composed shift for cursors not yet processed: a position p in the
        // original coordinates maps to the current document via (A, B).
        Pos A = Pos(0, 0), B = Pos(0, 0);
        bool changed = false;
        immutable insEmpty = inserted.length == 0;

        foreach (ref c; cursors_)
        {
            Pos head = c.head, anchor = c.anchor;
            if (A.line == head.line) head = Pos(B.line, B.col + head.col - A.col);
            else head.line += B.line - A.line;
            Pos s = head, e = head;
            if (c.hasSelection)
            {
                if (A.line == anchor.line) anchor = Pos(B.line, B.col + anchor.col - A.col);
                else anchor.line += B.line - A.line;
                s = minPos(head, anchor);
                e = maxPos(head, anchor);
            }
            else if (kind == EditKind.backward)
            {
                if (head.col > 0)
                    s.col = head.col - 1;
                else if (head.line > 0)
                    s = Pos(head.line - 1, cast(int) lines_.lineLength(head.line - 1));
            }
            else if (kind == EditKind.forward)
            {
                if (cast(size_t) head.col < lines_.lineLength(head.line))
                    e.col = head.col + 1;
                else if (cast(size_t) head.line + 1 < lines_.length)
                    e = Pos(head.line + 1, 0);
            }

            if (s == e && insEmpty)
            {
                c.head = head;
                c.collapse();
                continue;
            }

            // Map the end of the replaced range back to original coordinates.
            Pos eOrig = e;
            if (e.line == B.line) eOrig = Pos(A.line, A.col + e.col - B.col);
            else eOrig.line = e.line - B.line + A.line;

            immutable off = cast(uint) removedScratch.length;
            lines_.extract(s, e, removedScratch);
            replScratch.put(Replacement(s, off, cast(uint) removedScratch.length - off));

            immutable newHead = lines_.splice(s, e, inserted);
            A = eOrig;
            B = newHead;
            c.head = newHead;
            c.collapse();
            changed = true;
        }

        normalize(cursors_);
        resetGoals();
        if (!changed)
            return;

        auto entry = new HistoryEntry;
        entry.cursorsBefore = beforeScratch.dup;
        entry.cursorsAfter = cursors_.dup;
        entry.replacements = replScratch[].dup;
        entry.removed = removedScratch[].idup;
        entry.inserted = inserted;
        entry.insertedShape = shapeOf(inserted);
        undoStack.push(entry);
        redoStack.clear();
    }

    private Pos moveHead(Pos p, Direction dir, ref int goal) const pure nothrow @nogc @safe
    {
        final switch (dir)
        {
        case Direction.left:
            if (p.col > 0) return Pos(p.line, p.col - 1);
            if (p.line > 0) return Pos(p.line - 1, cast(int) lines_.lineLength(p.line - 1));
            return p;
        case Direction.right:
            if (cast(size_t) p.col < lines_.lineLength(p.line)) return Pos(p.line, p.col + 1);
            if (cast(size_t) p.line + 1 < lines_.length) return Pos(p.line + 1, 0);
            return p;
        case Direction.home:
            return Pos(p.line, 0);
        case Direction.end:
            return Pos(p.line, cast(int) lines_.lineLength(p.line));
        case Direction.up:
            if (p.line == 0)
            {
                goal = 0;
                return Pos(0, 0);
            }
            return Pos(p.line - 1, clampCol(goal, p.line - 1));
        case Direction.down:
            if (cast(size_t) p.line + 1 == lines_.length)
            {
                immutable col = cast(int) lines_.lineLength(p.line);
                goal = col;
                return Pos(p.line, col);
            }
            return Pos(p.line + 1, clampCol(goal, p.line + 1));
        }
    }

    private int clampCol(int col, int line) const pure nothrow @nogc @safe
    {
        immutable len = cast(int) lines_.lineLength(line);
        return col < len ? col : len;
    }

    private void moveCursor(ref Cursor c, Direction dir, bool select) const pure nothrow @nogc @safe
    {
        if (!select)
        {
            if (c.hasSelection && (dir == Direction.left || dir == Direction.right))
            {
                c.head = dir == Direction.left ? c.start : c.end;
                c.collapse();
                return;
            }
            c.collapse();
            c.head = moveHead(c.head, dir, c.goal);
            c.anchor = c.head;
            return;
        }
        if (!c.hasSelection)
            c.anchor = c.head;
        c.head = moveHead(c.head, dir, c.goal);
        c.hasSelection = c.head != c.anchor;
    }
}
