/// The six queries: `log`, `ls-tree`, `cat-file`, `diff`, `rev-parse` and
/// `count-objects`. Each returns the complete answer as bytes, or throws
/// `GitError` — never a partial answer.
module gitrepo.commands;

import std.algorithm : sort, SwapStrategy;
import std.array : Appender, appender;
import std.container.binaryheap : BinaryHeap;
import std.format : formattedWrite;

import gitrepo.errors;
import gitrepo.hex;
import gitrepo.objectid;
import gitrepo.objecttype;
import gitrepo.parse;
import gitrepo.quote;
import gitrepo.repository;
import gitrepo.revision;
import gitrepo.sha1;

/// Run one command line (as it appears in `commands.txt`) and return its output.
/// The line is split on single spaces, so empty tokens make the command invalid.
/// Throws: `GitError` for an unknown command, wrong arguments, or any failure.
ubyte[] execute(Repository repo, const(char)[] line)
{
    string[] tokens;
    size_t start;
    foreach (i; 0 .. line.length + 1)
        if (i == line.length || line[i] == ' ')
        {
            tokens ~= line[start .. i].idup;
            start = i + 1;
        }
    const args = tokens[1 .. $];
    switch (tokens[0])
    {
    case "log":
        if (args.length < 1 || args.length > 2)
            throw new GitError("usage: log <rev> [<n>]");
        return log(repo, args[0], args.length == 2 ? args[1] : null, args.length == 2);
    case "ls-tree":
        if (args.length < 1 || args.length > 2)
            throw new GitError("usage: ls-tree <rev> [<path>]");
        return lsTree(repo, args[0], args.length == 2 ? args[1] : null, args.length == 2);
    case "cat-file":
        if (args.length != 1)
            throw new GitError("usage: cat-file <rev>");
        return catFile(repo, args[0]);
    case "diff":
        if (args.length != 2)
            throw new GitError("usage: diff <rev1> <rev2>");
        return diff(repo, args[0], args[1]);
    case "rev-parse":
        if (args.length != 1)
            throw new GitError("usage: rev-parse <rev>");
        return revParse(repo, args[0]);
    case "count-objects":
        if (args.length != 0)
            throw new GitError("usage: count-objects");
        return countObjects(repo);
    default:
        throw new GitError("unknown command");
    }
}

/// `rev-parse <rev>`: the object id `rev` resolves to, plus a newline.
ubyte[] revParse(Repository repo, string rev)
{
    return cast(ubyte[])(resolveRevision(repo, rev).toString() ~ "\n");
}

/// `count-objects`: the three-line summary.
ubyte[] countObjects(Repository repo)
{
    immutable c = repo.counts();
    auto a = appender!(ubyte[]);
    formattedWrite(a, "loose: %d\nin-pack: %d\npacks: %d\n", c.loose, c.inPack, c.packs);
    return a[];
}

/// `cat-file <rev>`: `<type> <size>\n` then the payload, after verifying that
/// the SHA-1 of the stored form equals the object's id.
ubyte[] catFile(Repository repo, string rev)
{
    immutable id = resolveRevision(repo, rev);
    auto obj = repo.readObject(id);
    immutable header = typeName(obj.type) ~ " " ~ decimal(obj.data.length);
    Sha1 h;
    h.put(header);
    h.put(cast(const(ubyte)[]) "\0");
    h.put(obj.data);
    if (h.finish() != id.bytes)
        throw new GitError("object content does not match its id");
    auto a = appender!(ubyte[]);
    a.reserve(header.length + 1 + obj.data.length);
    a.put(cast(const(ubyte)[]) header);
    a.put('\n');
    a.put(obj.data);
    return a[];
}

/// `log <rev> [<n>]`: commits reachable from `rev`, newest committer date
/// first (ties: discovered first), at most `n` of them. `hasLimit` says
/// whether `limit` (a string of decimal digits) was given.
ubyte[] log(Repository repo, string rev, string limit, bool hasLimit)
{
    ulong maxCount = ulong.max;
    if (hasLimit)
    {
        if (limit.length == 0)
            throw new GitError("bad count");
        maxCount = 0;
        foreach (c; limit)
        {
            if (c < '0' || c > '9')
                throw new GitError("bad count");
            maxCount = maxCount > (ulong.max - 9) / 10 ? ulong.max : maxCount * 10 + (c - '0');
        }
    }
    immutable start = peel(repo, resolveRevision(repo, rev), ObjectType.commit);

    static struct Pending
    {
        ObjectId id;
        ulong date;
        ulong seq;
    }

    // Max-heap on (date, -seq): the newest date first, the earliest discovered among equals.
    alias Heap = BinaryHeap!(Pending[], (a, b) => a.date < b.date || (a.date == b.date && a.seq > b.seq));
    Pending[] store;
    auto heap = Heap(store);
    bool[ObjectId] seen;
    ulong seq;
    seen[start] = true;
    heap.insert(Pending(start, repo.commit(start).committer.timestamp, seq++));

    auto out_ = appender!(ubyte[]);
    ulong emitted;
    while (!heap.empty && emitted < maxCount)
    {
        immutable cur = heap.front;
        heap.popFront();
        auto c = repo.commit(cur.id);
        out_.put(cast(const(ubyte)[]) cur.id.toString());
        out_.put(' ');
        out_.put(c.author.name);
        out_.put(' ');
        out_.put(cast(const(ubyte)[]) decimal(c.author.timestamp));
        out_.put(' ');
        out_.put(c.subject);
        out_.put('\n');
        ++emitted;
        if (emitted >= maxCount)
            break;
        foreach (p; c.parents)
        {
            if (p in seen)
                continue;
            seen[p] = true;
            heap.insert(Pending(p, repo.commit(p).committer.timestamp, seq++));
        }
    }
    return out_[];
}

/// `ls-tree <rev> [<path>]`: the entries of a tree, one per line.
ubyte[] lsTree(Repository repo, string rev, string path, bool hasPath)
{
    auto id = peel(repo, resolveRevision(repo, rev), ObjectType.tree);
    if (hasPath)
    {
        // Validate the whole path before touching the repository further.
        string[] parts;
        size_t start;
        foreach (i; 0 .. path.length + 1)
            if (i == path.length || path[i] == '/')
            {
                immutable part = path[start .. i];
                if (part.length == 0 || part == "." || part == "..")
                    throw new GitError("bad path");
                parts ~= part;
                start = i + 1;
            }
        foreach (part; parts)
        {
            bool found;
            foreach (ref e; repo.tree(id))
                if (e.name == cast(const(ubyte)[]) part)
                {
                    if (!e.isTree)
                        throw new GitError("not a tree: " ~ path);
                    id = e.id;
                    found = true;
                    break;
                }
            if (!found)
                throw new GitError("no such path");
        }
    }
    auto a = appender!(ubyte[]);
    foreach (ref e; repo.tree(id))
    {
        formattedWrite(a, "%06o %s %s\t", e.mode, e.typeName, e.id.toString());
        appendQuoted(a, e.name);
        a.put('\n');
    }
    return a[];
}

private struct FlatEntry
{
    const(ubyte)[] path;
    uint mode;
    ObjectId id;
}

private void flatten(Repository repo, ObjectId treeId, const(ubyte)[] prefix, ref FlatEntry[] sink)
{
    foreach (ref e; repo.tree(treeId))
    {
        const full = prefix ~ e.name;
        if (e.isTree)
            flatten(repo, e.id, full ~ cast(const(ubyte)[]) "/", sink);
        else
            sink ~= FlatEntry(full, e.mode, e.id);
    }
}

private FlatEntry[] flatTree(Repository repo, ObjectId treeId)
{
    FlatEntry[] list;
    flatten(repo, treeId, null, list);
    list.sort!((a, b) => a.path < b.path, SwapStrategy.stable);
    // A map keyed by path: the last of any duplicate names wins.
    size_t n;
    foreach (i, ref e; list)
    {
        if (n > 0 && list[n - 1].path == e.path)
            list[n - 1] = e;
        else
            list[n++] = e;
    }
    return list[0 .. n];
}

/// `diff <rev1> <rev2>`: raw, recursive, rename-free comparison of two trees.
ubyte[] diff(Repository repo, string rev1, string rev2)
{
    immutable t1 = peel(repo, resolveRevision(repo, rev1), ObjectType.tree);
    immutable t2 = peel(repo, resolveRevision(repo, rev2), ObjectType.tree);
    auto left = flatTree(repo, t1);
    auto right = flatTree(repo, t2);

    auto a = appender!(ubyte[]);
    void emit(const(FlatEntry)* l, const(FlatEntry)* r)
    {
        char status;
        if (l is null)
            status = 'A';
        else if (r is null)
            status = 'D';
        else if ((l.mode & Mode.typeMask) == (r.mode & Mode.typeMask))
            status = 'M';
        else
            status = 'T';
        immutable id1 = l is null ? ObjectId.zero : l.id;
        immutable id2 = r is null ? ObjectId.zero : r.id;
        formattedWrite(a, ":%06o %06o %s %s %s\t", l is null ? 0 : l.mode, r is null ? 0 : r.mode,
                id1.toString(), id2.toString(), status);
        appendQuoted(a, l is null ? r.path : l.path);
        a.put('\n');
    }

    size_t i, j;
    while (i < left.length || j < right.length)
    {
        if (j >= right.length || (i < left.length && left[i].path < right[j].path))
            emit(&left[i++], null);
        else if (i >= left.length || right[j].path < left[i].path)
            emit(null, &right[j++]);
        else
        {
            if (left[i].mode != right[j].mode || left[i].id != right[j].id)
                emit(&left[i], &right[j]);
            ++i;
            ++j;
        }
    }
    return a[];
}

private string decimal(ulong v) @safe pure nothrow
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
