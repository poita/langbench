/// Parsing of commit, tree and tag payloads.
module gitrepo.objects;

import std.array : appender;
import std.conv : octal;

import gitrepo.errors;
import gitrepo.oid;

/// What a tree entry refers to, decided by the high bits of its mode.
enum EntryKind : ubyte
{
    blob,
    tree,
    commit,
}

/// One entry of a tree.
struct TreeEntry
{
    /// The mode as an integer (`040000`, `100644`, ...).
    uint mode;
    /// The bare entry name (bytes, not necessarily UTF-8).
    string name;
    ///
    ObjectId id;

    /// `mode & 0170000` equal to `0040000` is a tree, `0160000` a commit, anything else a blob.
    EntryKind kind() const @safe pure nothrow @nogc
    {
        immutable fmt = mode & octal!170000;
        return fmt == octal!40000 ? EntryKind.tree : fmt == octal!160000 ? EntryKind.commit : EntryKind.blob;
    }
}

/// A parsed tree: entries in stored order.
final class Tree
{
    ///
    TreeEntry[] entries;

    /// The entry called `name`, or null.
    const(TreeEntry)* find(scope const(char)[] name) const @trusted pure nothrow @nogc
    {
        foreach (i; 0 .. entries.length)
            if (entries[i].name == name)
                return &entries[i];
        return null;
    }
}

/// Parses a tree payload. The returned names alias `payload`. Throws `GitError` if malformed.
Tree parseTree(immutable(ubyte)[] payload) @trusted
{
    auto t = new Tree;
    auto entries = appender!(TreeEntry[]);
    size_t p = 0;
    while (p < payload.length)
    {
        uint mode = 0;
        size_t start = p;
        while (p < payload.length && payload[p] >= '0' && payload[p] <= '7')
        {
            mode = (mode << 3) | (payload[p] - '0');
            ++p;
        }
        if (p == start || p >= payload.length || payload[p] != ' ')
            throw new GitError("bad tree entry mode");
        ++p;
        start = p;
        while (p < payload.length && payload[p] != 0)
            ++p;
        if (p >= payload.length || p == start)
            throw new GitError("bad tree entry name");
        TreeEntry e;
        e.mode = mode;
        e.name = cast(string) payload[start .. p];
        ++p;
        if (payload.length - p < 20)
            throw new GitError("truncated tree entry");
        e.id.bytes[] = payload[p .. p + 20];
        p += 20;
        entries.put(e);
    }
    t.entries = entries.data;
    return t;
}

/// A parsed commit: only what the queries need.
final class Commit
{
    /// The `tree` header (valid only if `hasTree`).
    ObjectId tree;
    ///
    bool hasTree;
    /// Every `parent` header, in order.
    ObjectId[] parents;
    /// Timestamp of the `committer` line (0 if absent).
    ulong committerTime;
    /// Name from the `author` line.
    string authorName;
    /// Timestamp of the `author` line.
    ulong authorTime;
    /// First paragraph of the message, lines joined by single spaces.
    string subject;
    /// `<author name> SP <author timestamp> SP <subject>`: everything in a log line after the id.
    string logSuffix;
}

/// Splits the header block of a commit/tag payload. Calls `onHeader(key, value)` for each
/// header (continuation lines are skipped) and returns the offset of the message.
size_t parseHeaders(immutable(ubyte)[] payload,
    scope void delegate(string key, string value) @safe onHeader) @trusted
{
    size_t p = 0;
    while (p < payload.length)
    {
        size_t e = p;
        while (e < payload.length && payload[e] != '\n')
            ++e;
        if (e == p)
            return e + 1;
        if (payload[p] != ' ')
        {
            size_t sp = p;
            while (sp < e && payload[sp] != ' ')
                ++sp;
            immutable key = cast(string) payload[p .. sp];
            immutable value = sp < e ? cast(string) payload[sp + 1 .. e] : "";
            onHeader(key, value);
        }
        p = e + 1;
    }
    return payload.length;
}

/// Parses a commit payload. Throws `GitError` for an unparsable `tree`/`parent` header.
Commit parseCommit(immutable(ubyte)[] payload) @trusted
{
    auto c = new Commit;
    string authorLine, committerLine;
    immutable msgStart = parseHeaders(payload, (string key, string value) @safe {
        switch (key)
        {
        case "tree":
            ObjectId id;
            if (!ObjectId.tryParse(value, id))
                throw new GitError("bad tree header");
            c.tree = id;
            c.hasTree = true;
            break;
        case "parent":
            ObjectId id;
            if (!ObjectId.tryParse(value, id))
                throw new GitError("bad parent header");
            c.parents ~= id;
            break;
        case "author":
            authorLine = value;
            break;
        case "committer":
            committerLine = value;
            break;
        default:
            break;
        }
    });
    c.committerTime = identTime(committerLine);
    c.authorName = identName(authorLine);
    c.authorTime = identTime(authorLine);
    c.subject = subjectOf(cast(string) payload[msgStart .. $]);
    c.logSuffix = c.authorName ~ " " ~ utoa(c.authorTime) ~ " " ~ c.subject;
    return c;
}

/// Parses a tag payload and returns the id in its `object` header.
ObjectId parseTagTarget(immutable(ubyte)[] payload) @trusted
{
    ObjectId target;
    bool found;
    parseHeaders(payload, (string key, string value) @safe {
        if (key == "object")
        {
            if (!ObjectId.tryParse(value, target))
                throw new GitError("bad object header");
            found = true;
        }
    });
    if (!found)
        throw new GitError("tag without object header");
    return target;
}

private string utoa(ulong v) @safe pure nothrow
{
    char[20] buf;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v);
    return buf[i .. $].idup;
}

private bool isSpaceChar(char c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
}

/// The name part of an ident line: everything before the first `<`, trailing whitespace removed.
string identName(string line) @safe pure nothrow @nogc
{
    size_t n = 0;
    while (n < line.length && line[n] != '<')
        ++n;
    while (n > 0 && isSpaceChar(line[n - 1]))
        --n;
    return line[0 .. n];
}

/// The timestamp of an ident line (0 if there is none).
ulong identTime(string line) @safe pure nothrow @nogc
{
    size_t p = 0;
    while (p < line.length && line[p] != '<')
        ++p;
    while (p < line.length && line[p] != '>')
        ++p;
    if (p >= line.length)
        return 0;
    ++p;
    while (p < line.length && line[p] == ' ')
        ++p;
    if (p < line.length && (line[p] == '+' || line[p] == '-'))
        ++p;
    ulong v = 0;
    while (p < line.length && line[p] >= '0' && line[p] <= '9')
    {
        v = v * 10 + (line[p] - '0');
        ++p;
    }
    return v;
}

/// The subject of a commit message (see SPEC.md).
string subjectOf(string message) @safe pure
{
    string result;
    bool started = false;
    size_t p = 0;
    while (p <= message.length)
    {
        size_t e = p;
        while (e < message.length && message[e] != '\n')
            ++e;
        if (e == message.length && p == e)
            break; // nothing after the last LF
        size_t end = e;
        while (end > p && isSpaceChar(message[end - 1]))
            --end;
        if (end == p)
        {
            if (started)
                break;
        }
        else
        {
            if (started)
                result ~= ' ';
            result ~= message[p .. end];
            started = true;
        }
        p = e + 1;
    }
    return result;
}
