/// Reading mailboxes: mbox files and directories of `.eml` files.
module mime.mailbox;

import std.algorithm : endsWith, sort;
import std.array : array;
import std.conv : to;
import std.file : DirEntry, dirEntries, isDir, read, SpanMode;
import std.path : baseName, buildPath;
import mime.lines;

@safe:

/// One message as extracted from a mailbox.
struct RawMessage
{
    string sourceId;       /// `mbox:<n>` or the `.eml` file name
    const(ubyte)[] bytes;  /// the message bytes (line endings untouched)
}

/// Splits mbox data into messages (numbered from 1).
RawMessage[] splitMbox(const(ubyte)[] data) pure
{
    RawMessage[] result;
    size_t pos = 0;
    bool prevEmpty = false;    // the previous line was empty
    bool first = true;         // we are on the first line of the file
    size_t msgStart = 0;
    bool inMessage = false;

    void finish(size_t end)
    {
        if (!inMessage)
            return;
        auto bytes = data[msgStart .. end];
        if (bytes.length >= 2 && bytes[$ - 1] == '\n' && bytes[$ - 2] == '\n')
            bytes = bytes[0 .. $ - 1];
        result ~= RawMessage("mbox:" ~ (result.length + 1).to!string, bytes);
    }

    while (pos < data.length)
    {
        const ln = nextLine(data, pos);
        const line = data[ln.start .. ln.end];
        const isSeparator = (first || prevEmpty) && line.length >= 5 && line[0 .. 5] == cast(const(ubyte)[]) "From ";
        if (isSeparator)
        {
            finish(ln.start);
            inMessage = true;
            msgStart = ln.next;
        }
        first = false;
        prevEmpty = line.length == 0;
        pos = ln.next;
    }
    finish(data.length);
    return result;
}

/// Reads a mailbox: a directory of `.eml` files (sorted by name) or an mbox
/// file.
RawMessage[] readMailbox(string path) @trusted
{
    if (isDir(path))
    {
        string[] names;
        foreach (DirEntry e; dirEntries(path, SpanMode.shallow))
            if (e.isFile && baseName(e.name).endsWith(".eml"))
                names ~= baseName(e.name);
        sort(names);
        RawMessage[] result;
        foreach (n; names)
            result ~= RawMessage(n, cast(const(ubyte)[]) read(buildPath(path, n)));
        return result;
    }
    return splitMbox(cast(const(ubyte)[]) read(path));
}

pure unittest
{
    static const(ubyte)[] u(string s) @trusted { return cast(const(ubyte)[]) s; }
    auto r = splitMbox(u("junk\nFrom a\nS: 1\n\nbody\n\nFrom b\nS: 2\n\n"));
    // "From a" is neither the first line nor after a blank line: not a separator.
    assert(r.length == 1 && r[0].bytes == u("S: 2\n"));
    r = splitMbox(u("From a\nS: 1\n\nbody\n\nFrom b\nS: 2\n\nx\n\n\n"));
    assert(r.length == 2);
    assert(r[0].sourceId == "mbox:1" && r[0].bytes == u("S: 1\n\nbody\n"));
    assert(r[1].sourceId == "mbox:2" && r[1].bytes == u("S: 2\n\nx\n\n"));
    assert(splitMbox(u("")).length == 0);
    assert(splitMbox(u("no separator\n")).length == 0);
    r = splitMbox(u("junk\n\nFrom a\nx\nFrom not separator\n"));
    assert(r.length == 1 && r[0].bytes == u("x\nFrom not separator\n"));
}
