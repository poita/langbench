/// The line-oriented command language: parses and runs a script against a
/// `TextBuffer`.
module textbuffer.script;

import core.stdc.string : memchr;

import textbuffer.buffer;
import textbuffer.vec;

/// Thrown for malformed scripts.
class ScriptException : Exception
{
    this(string msg, size_t lineNo, string file = __FILE__, size_t line = __LINE__) nothrow pure @safe
    {
        import std.conv : to;
        string m;
        try m = "line " ~ lineNo.to!string ~ ": " ~ msg; catch (Exception) m = msg;
        super(m, file, line);
    }
}

/// Decodes the escape sequences of an `insert` argument (`\n`, `\\`) into
/// `scratch` and returns the decoded text. If the argument has no backslash
/// it is returned as is and `scratch` is untouched.
const(char)[] decodeInsert(const(char)[] raw, ref CharBuf scratch) @trusted
{
    if (raw.length == 0 || memchr(raw.ptr, '\\', raw.length) is null)
        return raw;
    scratch.clear();
    for (size_t i = 0; i < raw.length; ++i)
    {
        char ch = raw[i];
        if (ch == '\\' && i + 1 < raw.length)
        {
            ++i;
            ch = raw[i] == 'n' ? '\n' : raw[i];
        }
        scratch.put(ch);
    }
    return scratch[];
}

/// Splits `input` into the initial document lines and returns the offset of
/// the first command. The first line holds the line count `N`; the next `N`
/// lines are the document, verbatim.
size_t parseDocument(const(char)[] input, out const(char)[][] initial)
{
    size_t pos = 0;
    size_t lineNo = 1;
    size_t n = 0;
    bool any = false;
    while (pos < input.length && input[pos] != '\n')
    {
        immutable ch = input[pos];
        if (ch < '0' || ch > '9')
            throw new ScriptException("expected the line count", lineNo);
        n = n * 10 + (ch - '0');
        any = true;
        ++pos;
    }
    if (!any && input.length != 0)
        throw new ScriptException("expected the line count", lineNo);
    if (pos < input.length)
        ++pos;
    initial.length = 0;
    initial.reserve(n < 1_000_000 ? n : 1_000_000);
    foreach (i; 0 .. n)
    {
        // Lines missing at the end of the input count as empty.
        size_t end = pos;
        while (end < input.length && input[end] != '\n')
            ++end;
        initial ~= input[pos .. end];
        pos = end < input.length ? end + 1 : end;
    }
    return pos;
}

private bool parseNumber(const(char)[] s, out long value) pure nothrow @nogc @safe
{
    if (s.length == 0)
        return false;
    long v = 0;
    foreach (ch; s)
    {
        if (ch < '0' || ch > '9')
            return false;
        if (v < 1_000_000_000_000L)
            v = v * 10 + (ch - '0');
    }
    value = v;
    return true;
}

private void parsePair(const(char)[] args, size_t lineNo, out long a, out long b)
{
    size_t sp = 0;
    while (sp < args.length && args[sp] != ' ')
        ++sp;
    if (sp == args.length || !parseNumber(args[0 .. sp], a) || !parseNumber(args[sp + 1 .. $], b))
        throw new ScriptException("expected two numbers", lineNo);
}

/// Executes the commands in `input[offset .. $]` against `buf`, appending the
/// output of every `print` to `output`.
void runCommands(TextBuffer buf, const(char)[] input, size_t offset, ref CharBuf output)
{
    CharBuf scratch;
    size_t pos = offset;
    size_t lineNo = 1; // only used in error messages; counts commands, not input lines
    while (pos < input.length)
    {
        size_t end = pos;
        {
            auto p = cast(const(char)*) memchr(input.ptr + pos, '\n', input.length - pos);
            end = p is null ? input.length : p - input.ptr;
        }
        const ln = input[pos .. end];
        pos = end + 1;
        ++lineNo;

        size_t sp = 0;
        while (sp < ln.length && ln[sp] != ' ')
            ++sp;
        const word = ln[0 .. sp];
        const args = sp < ln.length ? ln[sp + 1 .. $] : ln[$ .. $];

        switch (word)
        {
        case "insert":
            buf.insert(decodeInsert(args, scratch));
            break;
        case "delete":
            buf.deleteBackward();
            break;
        case "delete-forward":
            buf.deleteForward();
            break;
        case "move":
        {
            size_t d = 0;
            while (d < args.length && args[d] != ' ')
                ++d;
            const dir = args[0 .. d];
            const sel = d < args.length ? args[d + 1 .. $] : args[$ .. $];
            if (sel.length != 0 && sel != "select")
                throw new ScriptException("unknown move modifier", lineNo);
            Direction dd;
            switch (dir)
            {
            case "left": dd = Direction.left; break;
            case "right": dd = Direction.right; break;
            case "up": dd = Direction.up; break;
            case "down": dd = Direction.down; break;
            case "home": dd = Direction.home; break;
            case "end": dd = Direction.end; break;
            default: throw new ScriptException("unknown direction", lineNo);
            }
            buf.move(dd, sel.length != 0);
            break;
        }
        case "goto":
        {
            long a, b;
            parsePair(args, lineNo, a, b);
            buf.goTo(a, b);
            break;
        }
        case "add-cursor":
        {
            long a, b;
            parsePair(args, lineNo, a, b);
            buf.addCursor(a, b);
            break;
        }
        case "clear-cursors":
            buf.clearCursors();
            break;
        case "undo":
            buf.undo();
            break;
        case "redo":
            buf.redo();
            break;
        case "print":
            buf.render(output);
            break;
        default:
            throw new ScriptException("unknown command", lineNo);
        }
    }
}

/// Runs a complete script (document header followed by commands) and appends
/// the printed output to `output`.
void runScript(const(char)[] input, ref CharBuf output)
{
    const(char)[][] initial;
    immutable offset = parseDocument(input, initial);
    runCommands(new TextBuffer(initial), input, offset, output);
}
