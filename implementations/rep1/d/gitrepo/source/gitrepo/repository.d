/// The repository facade: object store, refs and the parsed-object caches.
module gitrepo.repository;

import std.exception : assumeUnique;

import gitrepo.errors;
import gitrepo.objects;
import gitrepo.odb;
import gitrepo.oid;
import gitrepo.pack : ObjectType, typeName;
import gitrepo.refs;
import gitrepo.revision;
import gitrepo.sha1;

/// One commit of a history walk.
struct LogEntry
{
    ///
    ObjectId id;
    ///
    Commit commit;
}

/// A git repository opened for reading. Everything decoded is cached for the
/// lifetime of the object, so keep one `Repository` for many queries.
final class Repository
{
    private ObjectStore store_;
    private RefDb refs_;
    private Commit[ObjectId] commits;
    private Tree[ObjectId] trees;
    private ObjectId[ObjectId] tagTargets;

    /// Opens the repository whose `.git` directory (or bare repository) is `gitDir`.
    this(string gitDir)
    {
        store_ = new ObjectStore(gitDir);
        refs_ = new RefDb(gitDir);
    }

    /// The object store (loose objects and packs).
    ObjectStore store() @safe pure nothrow @nogc
    {
        return store_;
    }

    /// The ref database.
    RefDb refs() @safe pure nothrow @nogc
    {
        return refs_;
    }

    /// Resolves a revision such as `HEAD~2`, `v1.0^{tree}` or `a1b2c3d` to an object id.
    /// Throws `GitError` if it does not resolve.
    ObjectId revParse(string rev)
    {
        return resolveRevision(this, rev);
    }

    /// Reads an object (type and payload). Throws `GitError` if missing or damaged.
    RawObject readObject(const ObjectId id)
    {
        return store_.read(id);
    }

    /// Reads an object and verifies that the SHA-1 of its stored form equals `id`.
    RawObject readVerified(const ObjectId id)
    {
        auto o = store_.read(id);
        Sha1 h;
        h.put(typeName(o.type));
        h.put(" ");
        h.put(decimal(o.data.length));
        h.put("\0");
        h.put(o.data);
        if (h.finish() != id.bytes)
            throw new GitError("object hash mismatch");
        return o;
    }

    /// The parsed commit with the given id (cached). Throws if it is not a readable commit.
    Commit commit(const ObjectId id)
    {
        if (auto c = id in commits)
            return *c;
        auto o = store_.read(id);
        if (o.type != ObjectType.commit)
            throw new GitError("not a commit");
        auto c = parseCommit(o.data);
        commits[id] = c;
        return c;
    }

    /// The parsed tree with the given id (cached). Throws if it is not a readable tree.
    Tree tree(const ObjectId id)
    {
        if (auto t = id in trees)
            return *t;
        auto o = store_.read(id);
        if (o.type != ObjectType.tree)
            throw new GitError("not a tree");
        auto t = parseTree(o.data);
        trees[id] = t;
        return t;
    }

    /// The object a tag points at (cached). Throws if `id` is not a readable tag.
    ObjectId tagTarget(const ObjectId id)
    {
        if (auto t = id in tagTargets)
            return *t;
        auto o = store_.read(id);
        if (o.type != ObjectType.tag)
            throw new GitError("not a tag");
        auto t = parseTagTarget(o.data);
        tagTargets[id] = t;
        return t;
    }

    /// Peels `id` until it has type `want` (see `^{commit}`, `^{tree}`, ...).
    ObjectId peel(ObjectId id, ObjectType want)
    {
        return peelTo(this, id, want);
    }

    /// Walks history from `start` in git's default order (committer date, newest
    /// first, ties broken by discovery order) and returns at most `limit` commits.
    LogEntry[] log(ObjectId start, size_t limit = size_t.max)
    {
        LogEntry[] result;
        auto first = commit(start);
        if (limit == 0)
            return result;

        struct Item
        {
            ulong date;
            size_t seq;
            ObjectId id;
            Commit c;
        }

        Item[] heap;
        // a is "better" (popped earlier) than b: later date first, then lower sequence number
        static bool before(ref const Item a, ref const Item b)
        {
            return a.date > b.date || (a.date == b.date && a.seq < b.seq);
        }

        void push(Item it)
        {
            heap ~= it;
            size_t i = heap.length - 1;
            while (i > 0)
            {
                immutable parent = (i - 1) / 2;
                if (!before(heap[i], heap[parent]))
                    break;
                auto tmp = heap[i];
                heap[i] = heap[parent];
                heap[parent] = tmp;
                i = parent;
            }
        }

        Item pop()
        {
            auto top = heap[0];
            heap[0] = heap[$ - 1];
            heap.length = heap.length - 1;
            size_t i = 0;
            for (;;)
            {
                size_t best = i;
                immutable l = 2 * i + 1, r = 2 * i + 2;
                if (l < heap.length && before(heap[l], heap[best]))
                    best = l;
                if (r < heap.length && before(heap[r], heap[best]))
                    best = r;
                if (best == i)
                    break;
                auto tmp = heap[i];
                heap[i] = heap[best];
                heap[best] = tmp;
                i = best;
            }
            return top;
        }

        bool[ObjectId] seen;
        size_t seq = 0;
        seen[start] = true;
        push(Item(first.committerTime, seq++, start, first));
        while (heap.length)
        {
            auto it = pop();
            result ~= LogEntry(it.id, it.c);
            foreach (ref p; it.c.parents)
            {
                if (p in seen)
                    continue;
                seen[p] = true;
                auto pc = commit(p);
                push(Item(pc.committerTime, seq++, p, pc));
            }
            if (result.length >= limit)
                break;
        }
        return result;
    }
}

private string decimal(size_t v) @safe pure nothrow
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
