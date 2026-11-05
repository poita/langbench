/// Undo/redo bookkeeping.
module textbuffer.history;

import textbuffer.cursor;
import textbuffer.position;

/// One replacement made by an edit command: the text in the range starting at
/// `start` (and ending where `removedLength` characters of removed text end)
/// was replaced by the entry's inserted text.
///
/// `start` is expressed in the document as it was immediately before this
/// replacement was applied.
struct Replacement
{
    Pos start;
    /// Offset of the removed text inside `HistoryEntry.removed`.
    uint removedOffset;
    /// Length of the removed text.
    uint removedLength;
}

/// Everything needed to undo and redo one edit command.
final class HistoryEntry
{
    /// Cursors as they were before the command.
    Cursor[] cursorsBefore;
    /// Cursors after the command (normalised).
    Cursor[] cursorsAfter;
    /// The replacements, in the order they were applied.
    Replacement[] replacements;
    /// All removed texts, concatenated.
    string removed;
    /// The text inserted by every replacement (empty for deletions).
    string inserted;
    /// Geometry of `inserted`.
    TextShape insertedShape;
}

/// A LIFO stack with O(1) push/pop and O(n) clear.
struct Stack(T)
{
    private T[] items;
    private size_t used;

    size_t length() const pure nothrow @nogc @safe { return used; }
    bool empty() const pure nothrow @nogc @safe { return used == 0; }

    void push(T value) nothrow
    {
        if (used == items.length)
            items.length = items.length ? items.length * 2 : 16;
        items[used++] = value;
    }

    /// Removes and returns the top element. The stack must not be empty.
    T pop() nothrow @nogc
    {
        assert(used != 0);
        auto v = items[--used];
        items[used] = T.init;
        return v;
    }

    /// Removes all elements.
    void clear() nothrow @nogc
    {
        items[0 .. used] = T.init;
        used = 0;
    }
}
