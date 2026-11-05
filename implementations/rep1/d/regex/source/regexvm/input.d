/// Zero-copy line access over a bulk-read input buffer.
module regexvm.input;

import core.stdc.string : memchr;
import regexvm.errors;

/// Walks a byte buffer as `\n`-terminated lines without copying.  Lines are
/// returned verbatim (no trimming); the final line may lack its terminator.
struct LineReader
{
    private const(ubyte)[] data;
    private size_t pos;

    ///
    this(const(ubyte)[] data) pure nothrow @nogc @safe { this.data = data; }

    /// True when every line has been consumed.
    bool empty() const pure nothrow @nogc @safe { return pos >= data.length; }

    /// Returns the next line (without its `\n`).
    /// Throws: `InputFormatException` at end of input.
    const(ubyte)[] nextLine() @trusted
    {
        if (pos >= data.length)
            throw new InputFormatException("unexpected end of input");
        const rest = data.length - pos;
        const nl = cast(const(ubyte)*) memchr(data.ptr + pos, '\n', rest);
        const end = nl is null ? data.length : cast(size_t)(nl - data.ptr);
        auto line = data[pos .. end];
        pos = end + 1;
        return line;
    }

    /// Reads a line holding a plain decimal count.
    /// Throws: `InputFormatException` if the line is not all digits.
    size_t nextCount()
    {
        auto line = nextLine();
        if (line.length == 0 || line.length > 18)
            throw new InputFormatException("expected a count");
        size_t v;
        foreach (c; line)
        {
            if (c < '0' || c > '9')
                throw new InputFormatException("expected a count");
            v = v * 10 + (c - '0');
        }
        return v;
    }
}
