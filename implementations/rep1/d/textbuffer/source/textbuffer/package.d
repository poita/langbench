/// A text buffer with undo, redo and multiple cursors: the editing core of a
/// text editor.
///
/// Import `textbuffer` to get the whole public API:
///
/// $(UL
///   $(LI `textbuffer.buffer`: `TextBuffer`, the buffer with its editing,
///        movement and undo/redo commands;)
///   $(LI `textbuffer.cursor`: `Cursor` and cursor-set normalisation;)
///   $(LI `textbuffer.document`: `Document`, the line array;)
///   $(LI `textbuffer.line`: `Line`, a growable line;)
///   $(LI `textbuffer.history`: undo entries;)
///   $(LI `textbuffer.pos`: `Pos`;)
///   $(LI `textbuffer.script`: the line-oriented command language used by the CLI.))
module textbuffer;

public import textbuffer.buffer;
public import textbuffer.cursor;
public import textbuffer.document;
public import textbuffer.history;
public import textbuffer.line;
public import textbuffer.pos;
public import textbuffer.script;
