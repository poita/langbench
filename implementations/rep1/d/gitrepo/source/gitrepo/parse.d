/// Parsers for the payloads of commits, trees and tags.
///
/// All names, messages and other text are carried as raw bytes
/// (`const(ubyte)[]`): nothing here assumes UTF-8.
module gitrepo.parse;

import gitrepo.errors;
import gitrepo.objectid;

/// The `author` / `committer` information that matters here.
struct Ident
{
    const(ubyte)[] name; /// everything before the first `<`, trailing whitespace removed
    ulong timestamp; /// seconds since the epoch (0 when absent); the sign is ignored
}

/// A parsed commit.
struct Commit
{
    ObjectId tree;
    ObjectId[] parents; /// in header order
    Ident author;
    Ident committer;
    const(ubyte)[] subject; /// see `subjectOf`
}

/// One entry of a tree object.
struct TreeEntry
{
    uint mode; /// as stored, e.g. `octal!40000`
    const(ubyte)[] name;
    ObjectId id;

    /// True if the mode says this entry is a directory (`mode & 0170000 == 0040000`).
    bool isTree() const @safe pure nothrow @nogc
    {
        return (mode & Mode.typeMask) == Mode.tree;
    }

    /// `"tree"`, `"commit"` (a submodule) or `"blob"`, decided by the mode's high bits.
    string typeName() const @safe pure nothrow @nogc
    {
        switch (mode & Mode.typeMask)
        {
        case Mode.tree:
            return "tree";
        case Mode.gitlink:
            return "commit";
        default:
            return "blob";
        }
    }
}

/// Mode bits used to classify tree entries.
enum Mode : uint
{
    typeMask = 0xF000, // 0170000
    tree = 0x4000, // 0040000
    gitlink = 0xE000, // 0160000
}

/// Parse a commit payload.
/// Throws: `GitError` if the `tree` or a `parent` header is missing or malformed.
Commit parseCommit(const(ubyte)[] data) @safe pure
{
    Commit c;
    bool haveTree;
    const(ubyte)[] authorLine, committerLine;
    size_t pos;
    const(ubyte)[] message;
    while (pos < data.length)
    {
        size_t eol = pos;
        while (eol < data.length && data[eol] != '\n')
            ++eol;
        auto line = data[pos .. eol];
        pos = eol < data.length ? eol + 1 : eol;
        if (line.length == 0)
        {
            message = data[pos .. $];
            break;
        }
        if (line[0] == ' ')
            continue; // continuation of the previous header (e.g. gpgsig)
        size_t sp = 0;
        while (sp < line.length && line[sp] != ' ')
            ++sp;
        const key = cast(const(char)[]) line[0 .. sp];
        auto value = sp < line.length ? line[sp + 1 .. $] : line[0 .. 0];
        switch (key)
        {
        case "tree":
            if (!ObjectId.tryParse(cast(const(char)[]) value, c.tree))
                throw new GitError("malformed tree header");
            haveTree = true;
            break;
        case "parent":
            ObjectId p;
            if (!ObjectId.tryParse(cast(const(char)[]) value, p))
                throw new GitError("malformed parent header");
            c.parents ~= p;
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
    }
    if (!haveTree)
        throw new GitError("commit has no tree");
    c.author = parseIdent(authorLine);
    c.committer = parseIdent(committerLine);
    c.subject = subjectOf(message);
    return c;
}

/// Parse an ident line's value (`Name <email> 1234567890 +0000`).
Ident parseIdent(const(ubyte)[] line) @safe pure nothrow @nogc
{
    Ident r;
    size_t lt = 0;
    while (lt < line.length && line[lt] != '<')
        ++lt;
    size_t nameEnd = lt;
    while (nameEnd > 0 && isSpace(line[nameEnd - 1]))
        --nameEnd;
    r.name = line[0 .. nameEnd];
    if (lt >= line.length)
        return r;
    size_t gt = lt + 1;
    while (gt < line.length && line[gt] != '>')
        ++gt;
    if (gt >= line.length)
        return r;
    size_t i = gt + 1;
    while (i < line.length && line[i] == ' ')
        ++i;
    if (i < line.length && (line[i] == '+' || line[i] == '-'))
        ++i;
    ulong t;
    while (i < line.length && line[i] >= '0' && line[i] <= '9')
    {
        t = t * 10 + (line[i] - '0');
        ++i;
    }
    r.timestamp = t;
    return r;
}

/// A commit's subject: the first paragraph of the message (leading blank lines
/// skipped, trailing whitespace of each line stripped), its lines joined by one
/// space.
const(ubyte)[] subjectOf(const(ubyte)[] message) @safe pure nothrow
{
    ubyte[] subject;
    bool started;
    size_t pos;
    while (pos < message.length)
    {
        size_t eol = pos;
        while (eol < message.length && message[eol] != '\n')
            ++eol;
        auto line = message[pos .. eol];
        pos = eol + 1;
        while (line.length && isSpace(line[$ - 1]))
            line = line[0 .. $ - 1];
        if (line.length == 0)
        {
            if (started)
                break;
            continue;
        }
        if (started)
            subject ~= ' ';
        started = true;
        subject ~= line;
    }
    return subject;
}

/// Parse a tag payload and return the id its `object` header names (the last
/// such header wins).
/// Throws: `GitError` if there is none.
ObjectId parseTagTarget(const(ubyte)[] data) @safe pure
{
    ObjectId target;
    bool found;
    size_t pos;
    while (pos < data.length)
    {
        size_t eol = pos;
        while (eol < data.length && data[eol] != '\n')
            ++eol;
        auto line = data[pos .. eol];
        pos = eol + 1;
        if (line.length == 0)
            break;
        if (line.length > 7 && cast(const(char)[]) line[0 .. 7] == "object ")
        {
            if (!ObjectId.tryParse(cast(const(char)[]) line[7 .. $], target))
                throw new GitError("malformed tag object header");
            found = true;
        }
    }
    if (!found)
        throw new GitError("tag has no object");
    return target;
}

/// Parse a tree payload into its entries, in stored order.
/// Throws: `GitError` if the payload is malformed.
TreeEntry[] parseTree(const(ubyte)[] data) @safe pure
{
    TreeEntry[] entries;
    size_t pos;
    while (pos < data.length)
    {
        uint mode;
        size_t digits;
        while (pos < data.length && data[pos] >= '0' && data[pos] <= '7')
        {
            if (mode > (uint.max >> 3))
                throw new GitError("tree mode too large");
            mode = mode * 8 + (data[pos] - '0');
            ++pos;
            ++digits;
        }
        if (digits == 0 || pos >= data.length || data[pos] != ' ')
            throw new GitError("malformed tree entry mode");
        ++pos;
        size_t end = pos;
        while (end < data.length && data[end] != 0)
            ++end;
        if (end >= data.length || end == pos || end + 21 > data.length)
            throw new GitError("malformed tree entry name");
        TreeEntry e;
        e.mode = mode;
        e.name = data[pos .. end];
        e.id = ObjectId.fromBytes(data[end + 1 .. end + 21]);
        entries ~= e;
        pos = end + 21;
    }
    return entries;
}

private bool isSpace(ubyte c) @safe pure nothrow @nogc
{
    return c == ' ' || (c >= '\t' && c <= '\r');
}

unittest
{
    assert(cast(string) subjectOf(cast(const(ubyte)[]) "\n\nFix the thing   \nand the other\n\nbody\n")
            == "Fix the thing and the other");
    assert(subjectOf(cast(const(ubyte)[]) " \n\t\n").length == 0);
    assert(cast(string) subjectOf(cast(const(ubyte)[]) "one") == "one");
}

unittest
{
    auto i = parseIdent(cast(const(ubyte)[]) "Ada Lovelace  <ada@example.org> 1400003600 +0100");
    assert(cast(string) i.name == "Ada Lovelace" && i.timestamp == 1400003600);
    i = parseIdent(cast(const(ubyte)[]) "Nobody");
    assert(cast(string) i.name == "Nobody" && i.timestamp == 0);
    i = parseIdent(cast(const(ubyte)[]) "A <a>  -12 +0000");
    assert(i.timestamp == 12 && cast(string) i.name == "A");
    i = parseIdent(cast(const(ubyte)[]) "A <a> <b> 12 +0000"); // only the first `>` counts
    assert(i.timestamp == 0);
    i = parseIdent(cast(const(ubyte)[]) "A <a>  x");
    assert(i.timestamp == 0);
}

unittest
{
    import std.exception : assertThrown;

    enum t = "0123456789012345678901234567890123456789";
    enum p1 = "1111111111111111111111111111111111111111";
    enum p2 = "2222222222222222222222222222222222222222";
    auto text = "tree " ~ t ~ "\nparent " ~ p1 ~ "\nparent " ~ p2 ~ "\nauthor A <a@x> 10 +0000\n"
        ~ "committer C <c@x> 20 +0000\ngpgsig -----BEGIN\n \n -----END\n\nSubject\n\nBody\n";
    auto c = parseCommit(cast(const(ubyte)[]) text);
    assert(c.tree.toString == t && c.parents.length == 2 && c.parents[1].toString == p2);
    assert(c.author.timestamp == 10 && c.committer.timestamp == 20);
    assert(cast(string) c.subject == "Subject");
    assertThrown!GitError(parseCommit(cast(const(ubyte)[]) "author A <a> 1 +0\n\nx"));

    // A header-only commit with no blank line has an empty message.
    c = parseCommit(cast(const(ubyte)[]) ("tree " ~ t));
    assert(c.subject.length == 0 && c.parents.length == 0);
}

unittest
{
    ubyte[] tree = cast(ubyte[]) "40000 dir\0".dup;
    tree ~= new ubyte[](20);
    tree ~= cast(ubyte[]) "100644 f\0".dup;
    tree ~= new ubyte[](20);
    auto es = parseTree(tree);
    assert(es.length == 2);
    assert(es[0].isTree && es[0].typeName == "tree" && es[0].mode == 16384);
    assert(!es[1].isTree && es[1].typeName == "blob" && cast(string) es[1].name == "f");
    TreeEntry g;
    g.mode = 0xE000;
    assert(g.typeName == "commit");
    import std.exception : assertThrown;

    assertThrown!GitError(parseTree(tree[0 .. $ - 1]));
}
