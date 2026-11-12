/// The command language: parsing command lines and running whole scripts.
///
/// A script is a document followed by commands, one per line:
///
/// ---
/// 2
/// hello world
/// second line
/// move end
/// insert !
/// print
/// ---
module textbuffer.script;

import std.array : appender;
import std.conv : to;
import std.range.primitives : put;

import textbuffer.buffer;
import textbuffer.cursor;

/// Raised for malformed input.
class ScriptException : Exception
{
    /// 1-based input line the problem was found on (0 if unknown).
    size_t lineNumber;

    this(string msg, size_t lineNumber = 0, string file = __FILE__, size_t line = __LINE__)
        @safe nothrow
    {
        super(msg, file, line);
        this.lineNumber = lineNumber;
    }
}

/// Kinds of command.
enum CommandKind
{
    insert,
    deleteBackward,
    deleteForward,
    move,
    goTo,
    addCursor,
    clearCursors,
    undo,
    redo,
    print,
}

/// A parsed command.
struct Command
{
    /// What to do.
    CommandKind kind;
    /// `insert`: the decoded text.
    string text;
    /// `move`: direction.
    Direction direction;
    /// `move`: whether the selection is extended.
    bool select;
    /// `goto` / `add-cursor`: the (unclamped) position.
    long line, col;
}

/// Decodes the escapes of an `insert` argument: `\n` is a newline, `\\` a backslash.
string decodeInsertText(string raw) @safe
{
    import std.string : indexOf;

    if (raw.indexOf('\\') < 0)
        return raw;
    auto app = appender!string();
    app.reserve(raw.length);
    for (size_t i = 0; i < raw.length; ++i)
    {
        immutable ch = raw[i];
        if (ch != '\\')
        {
            app.put(ch);
            continue;
        }
        if (++i == raw.length)
            throw new ScriptException("dangling backslash in insert text");
        switch (raw[i])
        {
        case 'n': app.put('\n'); break;
        case '\\': app.put('\\'); break;
        default: throw new ScriptException("unknown escape in insert text");
        }
    }
    return app[];
}

private long parseNumber(string s) @safe
{
    if (s.length == 0 || s.length > 18)
        throw new ScriptException("invalid number '" ~ s ~ "'");
    long v = 0;
    foreach (ch; s)
    {
        if (ch < '0' || ch > '9')
            throw new ScriptException("invalid number '" ~ s ~ "'");
        v = v * 10 + (ch - '0');
    }
    return v;
}

private bool splitWord(ref string rest, out string word) @safe nothrow @nogc
{
    foreach (i, ch; rest)
        if (ch == ' ')
        {
            word = rest[0 .. i];
            rest = rest[i + 1 .. $];
            return true;
        }
    word = rest;
    rest = rest[$ .. $];
    return false;
}

/// Parses one command line (without its terminating newline).
Command parseCommand(string text) @safe
{
    string rest = text;
    string name;
    splitWord(rest, name);
    Command cmd;
    switch (name)
    {
    case "insert":
        if (rest.length == 0)
            throw new ScriptException("insert needs text");
        cmd.kind = CommandKind.insert;
        cmd.text = decodeInsertText(rest);
        break;
    case "delete":
        cmd.kind = CommandKind.deleteBackward;
        break;
    case "delete-forward":
        cmd.kind = CommandKind.deleteForward;
        break;
    case "move":
        cmd.kind = CommandKind.move;
        string dir, sel;
        splitWord(rest, dir);
        splitWord(rest, sel);
        switch (dir)
        {
        case "left": cmd.direction = Direction.left; break;
        case "right": cmd.direction = Direction.right; break;
        case "up": cmd.direction = Direction.up; break;
        case "down": cmd.direction = Direction.down; break;
        case "home": cmd.direction = Direction.home; break;
        case "end": cmd.direction = Direction.end; break;
        default: throw new ScriptException("unknown direction '" ~ dir ~ "'");
        }
        if (sel == "select")
            cmd.select = true;
        else if (sel.length)
            throw new ScriptException("unexpected move argument '" ~ sel ~ "'");
        break;
    case "goto":
    case "add-cursor":
        cmd.kind = name == "goto" ? CommandKind.goTo : CommandKind.addCursor;
        string l, c;
        splitWord(rest, l);
        splitWord(rest, c);
        cmd.line = parseNumber(l);
        cmd.col = parseNumber(c);
        break;
    case "clear-cursors":
        cmd.kind = CommandKind.clearCursors;
        break;
    case "undo":
        cmd.kind = CommandKind.undo;
        break;
    case "redo":
        cmd.kind = CommandKind.redo;
        break;
    case "print":
        cmd.kind = CommandKind.print;
        break;
    default:
        throw new ScriptException("unknown command '" ~ name ~ "'");
    }
    return cmd;
}

/// Writes the document (each line followed by a newline), one `cursor <line> <col>`
/// line per cursor in cursor order, and a final `--` line to `sink`.
void printState(Sink)(const TextBuffer buffer, ref Sink sink)
{
    foreach (i; 0 .. buffer.lineCount)
    {
        put(sink, buffer.line(i));
        put(sink, "\n");
    }
    foreach (c; buffer.cursors)
    {
        put(sink, "cursor ");
        put(sink, to!string(c.head.line));
        put(sink, " ");
        put(sink, to!string(c.head.col));
        put(sink, "\n");
    }
    put(sink, "--\n");
}

/// Executes `cmd` on `buffer`; `print` writes to `sink`.
void execute(Sink)(TextBuffer buffer, in Command cmd, ref Sink sink)
{
    final switch (cmd.kind)
    {
    case CommandKind.insert: buffer.insert(cmd.text); break;
    case CommandKind.deleteBackward: buffer.deleteBackward(); break;
    case CommandKind.deleteForward: buffer.deleteForward(); break;
    case CommandKind.move: buffer.move(cmd.direction, cmd.select); break;
    case CommandKind.goTo: buffer.goTo(cmd.line, cmd.col); break;
    case CommandKind.addCursor: buffer.addCursor(cmd.line, cmd.col); break;
    case CommandKind.clearCursors: buffer.clearCursors(); break;
    case CommandKind.undo: buffer.undo(); break;
    case CommandKind.redo: buffer.redo(); break;
    case CommandKind.print: printState(buffer, sink); break;
    }
}

/// Runs a whole script: the first line is the number `N` of document lines,
/// then come `N` document lines (verbatim), then one command per line.
/// Output of `print` commands goes to `sink`.
///
/// Throws: `ScriptException` on malformed input; output produced before the
/// error has already been written.
void runScript(Sink)(string input, ref Sink sink)
{
    size_t pos = 0;
    size_t lineNo = 0;

    bool nextLine(out string line)
    {
        if (pos >= input.length)
            return false;
        size_t e = pos;
        while (e < input.length && input[e] != '\n')
            ++e;
        line = input[pos .. e];
        pos = e < input.length ? e + 1 : e;
        ++lineNo;
        return true;
    }

    string line;
    if (!nextLine(line))
        throw new ScriptException("empty input");
    size_t n;
    try
        n = cast(size_t) parseNumber(line);
    catch (ScriptException e)
        throw new ScriptException("bad document line count", 1);

    const(char)[][] lines;
    lines.reserve(n);
    foreach (i; 0 .. n)
    {
        if (!nextLine(line))
            throw new ScriptException("input ends inside the document", lineNo);
        lines ~= line;
    }
    auto buffer = new TextBuffer(lines);
    lines = null;

    while (nextLine(line))
    {
        if (line.length == 0)
            continue;
        try
            execute(buffer, parseCommand(line), sink);
        catch (ScriptException e)
        {
            e.lineNumber = lineNo;
            throw e;
        }
    }
}

version (unittest)
{
    private string run(string input) @safe
    {
        auto app = appender!string();
        runScript(input, app);
        return app[];
    }
}

@safe unittest
{
    assert(decodeInsertText("plain") == "plain");
    assert(decodeInsertText(`a\nb\\c\\n`) == "a\nb\\c\\n");
    import std.exception : assertThrown;

    assertThrown!ScriptException(decodeInsertText(`oops\`));
    assertThrown!ScriptException(decodeInsertText(`\t`));
}

@safe unittest
{
    auto c = parseCommand("insert  two  spaces ");
    assert(c.kind == CommandKind.insert && c.text == " two  spaces ");
    c = parseCommand("move up select");
    assert(c.kind == CommandKind.move && c.direction == Direction.up && c.select);
    c = parseCommand("goto 1000000000 3");
    assert(c.kind == CommandKind.goTo && c.line == 1_000_000_000 && c.col == 3);
    assert(parseCommand("add-cursor 1 2").kind == CommandKind.addCursor);
    assert(parseCommand("delete-forward").kind == CommandKind.deleteForward);
    import std.exception : assertThrown;

    assertThrown!ScriptException(parseCommand("insert"));
    assertThrown!ScriptException(parseCommand("frobnicate"));
    assertThrown!ScriptException(parseCommand("move sideways"));
    assertThrown!ScriptException(parseCommand("goto x 1"));
}

@safe unittest
{
    // Spec example 1.
    immutable input = "2\nhello world\nsecond line\nmove end\ninsert !\nmove down\n"
        ~ "insert  (edited)\ngoto 0 5\ninsert ,\nprint\ndelete\ndelete\nprint\n";
    immutable expected = "hello, world!\nsecond line (edited)\ncursor 0 6\n--\n"
        ~ "hell world!\nsecond line (edited)\ncursor 0 4\n--\n";
    assert(run(input) == expected);
}

@safe unittest
{
    // Spec example 2.
    immutable input = "3\nalpha\nbeta\ngamma\nadd-cursor 1 0\nadd-cursor 2 0\ninsert - \nprint\n"
        ~ "move end select\ninsert X\nprint\ngoto 0 1\nmove right select\nmove right select\n"
        ~ "delete\nprint\n";
    immutable expected = "- alpha\n- beta\n- gamma\ncursor 0 2\ncursor 1 2\ncursor 2 2\n--\n"
        ~ "- X\n- X\n- X\ncursor 0 3\ncursor 1 3\ncursor 2 3\n--\n"
        ~ "-\n- X\n- X\ncursor 0 1\n--\n";
    assert(run(input) == expected);
}

@safe unittest
{
    // Spec example 3.
    immutable input = "1\nabc\nmove end\ninsert d\\ne\nprint\ndelete\ndelete\nprint\nundo\nprint\n"
        ~ "undo\nprint\nredo\nprint\ninsert Z\nredo\nprint";
    immutable expected = "abcd\ne\ncursor 1 1\n--\nabcd\ncursor 0 4\n--\nabcd\n\ncursor 1 0\n--\n"
        ~ "abcd\ne\ncursor 1 1\n--\nabcd\n\ncursor 1 0\n--\nabcd\nZ\ncursor 1 1\n--\n";
    assert(run(input) == expected);
}

@safe unittest
{
    // Empty document, document lines that look like commands, missing trailing newline.
    assert(run("0\nprint") == "\ncursor 0 0\n--\n");
    assert(run("2\nprint\n  undo  \nprint\n") == "print\n  undo  \ncursor 0 0\n--\n");
    assert(run("1\n\nmove left\nmove up\ndelete\nprint\n") == "\ncursor 0 0\n--\n");
    assert(run("1\nabc\nundo\nredo\nclear-cursors\n") == "");
}

@safe unittest
{
    import std.exception : assertThrown;

    string o;
    auto app = appender!string();
    assertThrown!ScriptException(runScript("", app));
    assertThrown!ScriptException(runScript("x\n", app));
    assertThrown!ScriptException(runScript("3\na\n", app));
    assertThrown!ScriptException(runScript("0\nbogus\n", app));
}
