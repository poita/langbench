/// The six queries (`log`, `ls-tree`, `cat-file`, `diff`, `rev-parse`,
/// `count-objects`) and the command-line dispatcher that runs them.
module gitrepo.queries;

import std.algorithm.sorting : sort;
import std.array : Appender, appender;

import gitrepo.errors;
import gitrepo.objects;
import gitrepo.oid;
import gitrepo.pack : ObjectType, typeName;
import gitrepo.quote;
import gitrepo.repository;

/// The byte buffer all answers are built in.
alias OutBuf = Appender!(ubyte[]);

private void putStr(ref OutBuf o, scope const(char)[] s) @trusted
{
    o.put(cast(const(ubyte)[]) s);
}

private void putHex(ref OutBuf o, ref const ObjectId id) @safe
{
    foreach (b; id.bytes)
    {
        o.put(cast(ubyte) hexDigits[b >> 4]);
        o.put(cast(ubyte) hexDigits[b & 15]);
    }
}

private void putDecimal(ref OutBuf o, ulong v) @safe
{
    char[20] buf;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v);
    putStr(o, buf[i .. $]);
}

private void putMode(ref OutBuf o, uint mode) @safe
{
    char[16] buf;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + (mode & 7));
        mode >>= 3;
    }
    while (mode);
    while (buf.length - i < 6)
        buf[--i] = '0';
    putStr(o, buf[i .. $]);
}

/// Runs one command line (tokens separated by single spaces) and returns its output.
/// Throws `GitError` (or another `Exception`) if the command fails.
ubyte[] execute(Repository repo, string line)
{
    string[] args;
    size_t start = 0;
    foreach (i; 0 .. line.length + 1)
    {
        if (i == line.length || line[i] == ' ')
        {
            args ~= line[start .. i];
            start = i + 1;
        }
    }
    foreach (a; args)
        if (a.length == 0)
            throw new GitError("empty argument");
    switch (args[0])
    {
    case "log":
        if (args.length != 2 && args.length != 3)
            throw new GitError("usage: log <rev> [<n>]");
        return logCommand(repo, args[1], args.length == 3 ? args[2] : null);
    case "ls-tree":
        if (args.length != 2 && args.length != 3)
            throw new GitError("usage: ls-tree <rev> [<path>]");
        return lsTreeCommand(repo, args[1], args.length == 3 ? args[2] : null);
    case "cat-file":
        if (args.length != 2)
            throw new GitError("usage: cat-file <rev>");
        return catFileCommand(repo, args[1]);
    case "diff":
        if (args.length != 3)
            throw new GitError("usage: diff <rev1> <rev2>");
        return diffCommand(repo, args[1], args[2]);
    case "rev-parse":
        if (args.length != 2)
            throw new GitError("usage: rev-parse <rev>");
        return revParseCommand(repo, args[1]);
    case "count-objects":
        if (args.length != 1)
            throw new GitError("usage: count-objects");
        return countObjectsCommand(repo);
    default:
        throw new GitError("unknown command");
    }
}

/// `log <rev> [<n>]`: `limit` is the optional decimal limit (null for none).
ubyte[] logCommand(Repository repo, string rev, string limit = null)
{
    size_t n = size_t.max;
    if (limit !is null)
    {
        if (limit.length == 0)
            throw new GitError("bad limit");
        ulong v = 0;
        foreach (c; limit)
        {
            if (c < '0' || c > '9')
                throw new GitError("bad limit");
            if (v < (ulong.max >> 4))
                v = v * 10 + (c - '0');
        }
        n = v > size_t.max / 2 ? size_t.max : cast(size_t) v;
    }
    auto start = repo.peel(repo.revParse(rev), ObjectType.commit);
    auto o = appender!(ubyte[]);
    foreach (e; repo.log(start, n))
    {
        putHex(o, e.id);
        o.put(cast(ubyte) ' ');
        putStr(o, e.commit.logSuffix);
        o.put(cast(ubyte) '\n');
    }
    return o.data;
}

/// `ls-tree <rev> [<path>]`.
ubyte[] lsTreeCommand(Repository repo, string rev, string path = null)
{
    auto treeId = repo.peel(repo.revParse(rev), ObjectType.tree);
    if (path !is null)
    {
        size_t s = 0;
        foreach (i; 0 .. path.length + 1)
        {
            if (i == path.length || path[i] == '/')
            {
                immutable comp = path[s .. i];
                if (comp.length == 0 || comp == "." || comp == "..")
                    throw new GitError("bad path");
                auto e = repo.tree(treeId).find(comp);
                if (e is null || e.kind != EntryKind.tree)
                    throw new GitError("not a tree");
                treeId = e.id;
                s = i + 1;
            }
        }
    }
    auto o = appender!(ubyte[]);
    foreach (ref e; repo.tree(treeId).entries)
    {
        putMode(o, e.mode);
        o.put(cast(ubyte) ' ');
        final switch (e.kind)
        {
        case EntryKind.blob: putStr(o, "blob"); break;
        case EntryKind.tree: putStr(o, "tree"); break;
        case EntryKind.commit: putStr(o, "commit"); break;
        }
        o.put(cast(ubyte) ' ');
        putHex(o, e.id);
        o.put(cast(ubyte) '\t');
        appendQuoted(o, e.name);
        o.put(cast(ubyte) '\n');
    }
    return o.data;
}

/// `cat-file <rev>`: type, size and payload of the verified object.
ubyte[] catFileCommand(Repository repo, string rev)
{
    auto id = repo.revParse(rev);
    auto obj = repo.readVerified(id);
    auto o = appender!(ubyte[]);
    o.reserve(obj.data.length + 32);
    putStr(o, typeName(obj.type));
    o.put(cast(ubyte) ' ');
    putDecimal(o, obj.data.length);
    o.put(cast(ubyte) '\n');
    o.put(obj.data);
    return o.data;
}

/// `rev-parse <rev>`.
ubyte[] revParseCommand(Repository repo, string rev)
{
    auto id = repo.revParse(rev);
    auto o = appender!(ubyte[]);
    putHex(o, id);
    o.put(cast(ubyte) '\n');
    return o.data;
}

/// `count-objects`.
ubyte[] countObjectsCommand(Repository repo)
{
    auto o = appender!(ubyte[]);
    putStr(o, "loose: ");
    putDecimal(o, repo.store.looseCount);
    putStr(o, "\nin-pack: ");
    putDecimal(o, repo.store.inPackCount);
    putStr(o, "\npacks: ");
    putDecimal(o, repo.store.packCount);
    o.put(cast(ubyte) '\n');
    return o.data;
}

/// A file in a flattened tree.
struct FlatEntry
{
    /// Full path from the root of the tree.
    string path;
    ///
    uint mode;
    ///
    ObjectId id;
}

/// Flattens a tree into its non-tree entries (gitlinks included), sorted by path bytes.
FlatEntry[] flattenTree(Repository repo, ObjectId treeId)
{
    FlatEntry[] result;
    void walk(ObjectId id, string prefix)
    {
        foreach (ref e; repo.tree(id).entries)
        {
            if (e.kind == EntryKind.tree)
                walk(e.id, prefix ~ e.name ~ "/");
            else
                result ~= FlatEntry(prefix ~ e.name, e.mode, e.id);
        }
    }

    walk(treeId, "");
    result.sort!((a, b) => a.path < b.path);
    return result;
}

/// One changed path between two trees.
struct DiffEntry
{
    ///
    string path;
    /// Modes and ids on each side (zero when the path is absent).
    uint mode1, mode2;
    ///
    ObjectId id1, id2;
    /// `A`, `D`, `M` or `T`.
    char status;
}

/// Compares two trees recursively. The result is sorted by path bytes.
DiffEntry[] diffTrees(Repository repo, ObjectId tree1, ObjectId tree2)
{
    auto a = flattenTree(repo, tree1);
    auto b = flattenTree(repo, tree2);
    DiffEntry[] result;
    size_t i = 0, j = 0;
    while (i < a.length || j < b.length)
    {
        if (j >= b.length || (i < a.length && a[i].path < b[j].path))
        {
            result ~= DiffEntry(a[i].path, a[i].mode, 0, a[i].id, ObjectId.init, 'D');
            ++i;
        }
        else if (i >= a.length || b[j].path < a[i].path)
        {
            result ~= DiffEntry(b[j].path, 0, b[j].mode, ObjectId.init, b[j].id, 'A');
            ++j;
        }
        else
        {
            if (a[i].mode != b[j].mode || a[i].id != b[j].id)
            {
                immutable same = (a[i].mode & octal!170000) == (b[j].mode & octal!170000);
                result ~= DiffEntry(a[i].path, a[i].mode, b[j].mode, a[i].id, b[j].id, same ? 'M' : 'T');
            }
            ++i;
            ++j;
        }
    }
    return result;
}

import std.conv : octal;

/// `diff <rev1> <rev2>`.
ubyte[] diffCommand(Repository repo, string rev1, string rev2)
{
    auto t1 = repo.peel(repo.revParse(rev1), ObjectType.tree);
    auto t2 = repo.peel(repo.revParse(rev2), ObjectType.tree);
    auto o = appender!(ubyte[]);
    foreach (ref d; diffTrees(repo, t1, t2))
    {
        o.put(cast(ubyte) ':');
        putMode(o, d.mode1);
        o.put(cast(ubyte) ' ');
        putMode(o, d.mode2);
        o.put(cast(ubyte) ' ');
        putHex(o, d.id1);
        o.put(cast(ubyte) ' ');
        putHex(o, d.id2);
        o.put(cast(ubyte) ' ');
        o.put(cast(ubyte) d.status);
        o.put(cast(ubyte) '\t');
        appendQuoted(o, d.path);
        o.put(cast(ubyte) '\n');
    }
    return o.data;
}
