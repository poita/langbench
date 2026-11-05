/// A text buffer with undo, redo and multiple cursors.
///
/// Import `textbuffer` to get the whole public API:
///
/// ---
/// import textbuffer;
///
/// auto buf = TextBuffer.fromText("hello\nworld");
/// buf.addCursor(1, 0);
/// buf.insert("> ");
/// assert(buf.text == "> hello\n> world");
/// buf.undo();
/// assert(buf.text == "hello\nworld");
/// ---
module textbuffer;

public import textbuffer.buffer;
public import textbuffer.cursor;
public import textbuffer.history;
public import textbuffer.lines;
public import textbuffer.position;
public import textbuffer.script;
public import textbuffer.vec;
