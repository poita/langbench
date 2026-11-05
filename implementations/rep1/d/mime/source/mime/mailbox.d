/// Mailbox input: splits an mbox file, or lists a directory of `.eml` files,
/// into raw messages.
module mime.mailbox;

import std.algorithm.sorting : sort;
import std.file : DirEntry, dirEntries, isDir, isFile, read, SpanMode;
import std.path : baseName, buildPath;

/// One raw message: where it came from and its bytes.
struct RawMessage
{
    string sourceId; /// file name, or `mbox:<i>`
    const(ubyte)[] data; /// the message bytes (CRLF line endings untouched)
}

/// Splits an mbox archive into messages; message *i* has source id `mbox:i`.
///
/// A separator line starts with `From ` and is the first line or follows an
/// empty line. The returned messages are slices of `file`.
RawMessage[] splitMbox(const(ubyte)[] file) @safe pure
{
    RawMessage[] result;
    immutable n = file.length;

    size_t pos = 0;
    bool prevEmpty = true; // "first line" counts like "after an empty line"
    size_t msgStart = size_t.max;
    size_t sepStart = 0;

    void finish(size_t end) @safe pure
    {
        if (msgStart == size_t.max)
            return;
        auto bytes = file[msgStart .. end];
        if (bytes.length >= 2 && bytes[$ - 1] == '\n' && bytes[$ - 2] == '\n')
            bytes = bytes[0 .. $ - 1];
        result ~= RawMessage(mboxId(result.length + 1), bytes);
    }

    while (pos < n)
    {
        size_t e = pos;
        while (e < n && file[e] != '\n')
            e++;
        immutable next = e < n ? e + 1 : n;
        immutable isSep = prevEmpty && e - pos >= 5 && file[pos .. pos + 5] == cast(const(ubyte)[]) "From ";
        if (isSep)
        {
            finish(pos);
            msgStart = next;
        }
        // an empty line has no bytes once a single CR before the LF is dropped
        immutable lineLen = (e > pos && file[e - 1] == '\r' && e < n) ? e - pos - 1 : e - pos;
        prevEmpty = lineLen == 0 && e < n;
        pos = next;
    }
    finish(n);
    return result;
}

private string mboxId(size_t i) @safe pure
{
    import std.conv : to;

    return "mbox:" ~ i.to!string;
}

/// A mailbox on disk. Messages are loaded one at a time.
final class Mailbox
{
    private string[] names; // directory mode: sorted file names
    private string dir;
    private const(ubyte)[] mbox; // mbox mode: the whole file
    private RawMessage[] mboxMessages;
    private bool isDirectory;

    /// Opens `path`, which is a regular file (mbox) or a directory of `.eml` files.
    this(string path)
    {
        if (isDir(path))
        {
            isDirectory = true;
            dir = path;
            foreach (DirEntry e; dirEntries(path, SpanMode.shallow))
            {
                immutable name = baseName(e.name);
                if (name.length >= 4 && name[$ - 4 .. $] == ".eml" && e.isFile)
                    names ~= name;
            }
            names.sort!((a, b) => a < b);
        }
        else
        {
            mbox = cast(const(ubyte)[]) read(path);
            mboxMessages = splitMbox(mbox);
        }
    }

    /// Number of messages.
    size_t length() const @safe pure nothrow @nogc
    {
        return isDirectory ? names.length : mboxMessages.length;
    }

    /// Returns message `i` (0-based), reading the file in directory mode.
    RawMessage opIndex(size_t i)
    {
        if (isDirectory)
            return RawMessage(names[i], cast(const(ubyte)[]) read(buildPath(dir, names[i])));
        return mboxMessages[i];
    }
}
