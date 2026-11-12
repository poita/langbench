/// Undo and redo bookkeeping. Entries record replacements and cursors, never
/// copies of the document.
module textbuffer.history;

import textbuffer.cursor;
import textbuffer.pos;

/// One replacement made by an edit command.
struct Replacement
{
    /// Start of the replaced range, in the document as it was immediately
    /// before this replacement was applied.
    Pos start;
    /// The text that was removed (possibly empty).
    string removed;
    /// The text that was inserted (possibly empty).
    string inserted;
}

/// One recorded edit command: every replacement it made and the cursor sets
/// before and after it.
struct UndoEntry
{
    /// Cursors before the command.
    Cursor[] before;
    /// Cursors after the command (normalised).
    Cursor[] after;
    /// The replacements, in the order they were applied.
    Replacement[] replacements;
}

/// The undo and redo stacks.
struct History
{
    private UndoEntry[] undoStack;
    private UndoEntry[] redoStack;

    /// Whether `popUndo` would yield an entry.
    bool canUndo() const @safe nothrow @nogc
    {
        return undoStack.length != 0;
    }

    /// Whether `popRedo` would yield an entry.
    bool canRedo() const @safe nothrow @nogc
    {
        return redoStack.length != 0;
    }

    /// Number of entries that can be undone.
    size_t undoDepth() const @safe nothrow @nogc
    {
        return undoStack.length;
    }

    /// Number of entries that can be redone.
    size_t redoDepth() const @safe nothrow @nogc
    {
        return redoStack.length;
    }

    /// Records a freshly executed edit; clears the redo stack.
    void record(UndoEntry e) @safe nothrow
    {
        redoStack[] = UndoEntry.init;
        redoStack.length = 0;
        () @trusted { redoStack.assumeSafeAppend(); }();
        undoStack ~= e;
    }

    /// Pops the most recent undo entry onto the redo stack and returns it.
    UndoEntry popUndo() @safe nothrow
    in (canUndo)
    {
        auto e = undoStack[$ - 1];
        undoStack[$ - 1] = UndoEntry.init;
        undoStack.length = undoStack.length - 1;
        () @trusted { undoStack.assumeSafeAppend(); }();
        redoStack ~= e;
        return e;
    }

    /// Pops the most recent redo entry back onto the undo stack and returns it.
    UndoEntry popRedo() @safe nothrow
    in (canRedo)
    {
        auto e = redoStack[$ - 1];
        redoStack[$ - 1] = UndoEntry.init;
        redoStack.length = redoStack.length - 1;
        () @trusted { redoStack.assumeSafeAppend(); }();
        undoStack ~= e;
        return e;
    }
}

@safe nothrow unittest
{
    History h;
    assert(!h.canUndo && !h.canRedo);
    h.record(UndoEntry(null, null, [Replacement(Pos(0, 0), "", "a")]));
    h.record(UndoEntry(null, null, [Replacement(Pos(0, 1), "", "b")]));
    assert(h.undoDepth == 2);
    assert(h.popUndo().replacements[0].inserted == "b");
    assert(h.canRedo && h.undoDepth == 1);
    assert(h.popRedo().replacements[0].inserted == "b");
    assert(h.undoDepth == 2 && !h.canRedo);
    h.popUndo();
    h.record(UndoEntry(null, null, [Replacement(Pos(0, 1), "", "c")]));
    assert(!h.canRedo);  // recording clears the redo stack
}
