/**
 * Text rendering of `Event`s in the wire format of the command-line tool,
 * plus a buffered writer for producing large outputs quickly.
 */
module orderbook.format;

import std.range.primitives : put;
import std.stdio : File;

import orderbook.types;

/// Write `value` in decimal to `w` (any output range of `char[]`).
void putDecimal(W)(ref W w, ulong value)
{
    char[20] buf = void;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value != 0);
    put(w, buf[i .. $]);
}

/**
 * Write one event as a line, including the trailing `'\n'`, to `w`, an
 * output range accepting `const(char)[]` and `char`.
 */
void writeEvent(W)(ref W w, in Event e)
{
    final switch (e.kind)
    {
    case EventKind.trade:
        put(w, "TRADE ");
        put(w, e.id);
        put(w, ' ');
        put(w, e.makerId);
        put(w, ' ');
        putDecimal(w, e.price);
        put(w, ' ');
        putDecimal(w, e.qty);
        break;
    case EventKind.rest:
        put(w, "REST ");
        put(w, e.id);
        break;
    case EventKind.cancel:
        put(w, "CANCEL ");
        put(w, e.id);
        put(w, ' ');
        putDecimal(w, e.qty);
        break;
    case EventKind.reject:
        put(w, "REJECT ");
        put(w, e.id);
        break;
    case EventKind.filled:
        put(w, "FILLED ");
        put(w, e.id);
        break;
    case EventKind.bid:
    case EventKind.ask:
        put(w, e.kind == EventKind.bid ? "BID " : "ASK ");
        putDecimal(w, e.price);
        put(w, ' ');
        putDecimal(w, e.qty);
        put(w, ' ');
        putDecimal(w, e.orders);
        break;
    case EventKind.endOfBook:
        put(w, "--");
        break;
    }
    put(w, '\n');
}

/// The event as a string without the trailing newline.
string formatEvent(in Event e) @safe pure
{
    static struct Collector
    {
        char[] data;
        void put(const(char)[] s) @safe pure
        {
            data ~= s;
        }

        void put(char c) @safe pure
        {
            data ~= c;
        }
    }

    Collector c;
    writeEvent(c, e);
    return c.data[0 .. $ - 1].idup;
}

/// A buffered output range of characters in front of a `File`.
struct BufferedWriter
{
    private File file;
    private char[] buffer;
    private size_t used;

    /// Wrap `file`, flushing to it whenever `capacity` bytes accumulate.
    this(File file, size_t capacity = 1 << 16)
    {
        this.file = file;
        buffer = new char[capacity];
    }

    /// Append text.
    void put(const(char)[] s)
    {
        if (s.length > buffer.length - used)
        {
            flush();
            if (s.length >= buffer.length)
            {
                file.rawWrite(s);
                return;
            }
        }
        buffer[used .. used + s.length] = s[];
        used += s.length;
    }

    /// ditto
    void put(char c)
    {
        if (used == buffer.length)
            flush();
        buffer[used++] = c;
    }

    /// Write out buffered data. Call before the writer goes out of scope.
    void flush()
    {
        if (used)
            file.rawWrite(buffer[0 .. used]);
        used = 0;
    }
}

/**
 * An `Event` output range that renders every event as a text line into a
 * character output range `W`, for use as the `sink` of `OrderBook` calls.
 */
struct TextSink(W)
{
    W* writer;

    /// Render `e` as a line.
    void put(in Event e)
    {
        writeEvent(*writer, e);
    }
}

/// Convenience constructor for `TextSink`.
TextSink!W textSink(W)(ref W writer)
{
    return TextSink!W(&writer);
}

unittest
{
    assert(Event.trade("a", "b", 100, 7).toString == "TRADE a b 100 7");
    assert(Event.cancel("a", 12_000_000_000).toString == "CANCEL a 12000000000");
    assert(Event.level(Side.buy, 5, 0, 1).toString == "BID 5 0 1");
    assert(Event.level(Side.sell, 5, 9, 2).toString == "ASK 5 9 2");
    assert(Event.endOfBook.toString == "--");
    assert(Event.reject("x").toString == "REJECT x");
}
