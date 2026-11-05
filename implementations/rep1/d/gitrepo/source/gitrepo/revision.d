/// Revision syntax: names, abbreviated ids, `^`, `~` and `^{...}`.
module gitrepo.revision;

import gitrepo.errors;
import gitrepo.oid;
import gitrepo.pack : ObjectType;
import gitrepo.repository;

/// Resolves `rev` (see SPEC.md, "Revision syntax"). Throws `GitError` on failure.
ObjectId resolveRevision(Repository repo, string rev)
{
    // 1. `<rev>^{<peel>}`
    if (rev.length > 0 && rev[$ - 1] == '}')
    {
        for (size_t i = rev.length - 1; i-- > 0;)
        {
            if (rev[i] == '^' && rev[i + 1] == '{')
            {
                if (i != 0)
                {
                    immutable what = rev[i + 2 .. $ - 1];
                    auto base = resolveRevision(repo, rev[0 .. i]);
                    return applyPeel(repo, base, what);
                }
                break;
            }
        }
    }
    // 2. `<rev>^<n>` / `<rev>~<n>`
    {
        size_t i = rev.length;
        while (i > 0 && rev[i - 1] >= '0' && rev[i - 1] <= '9')
            --i;
        if (i > 1 && (rev[i - 1] == '^' || rev[i - 1] == '~'))
        {
            immutable op = rev[i - 1];
            ulong n = 1;
            if (i < rev.length)
            {
                n = 0;
                foreach (c; rev[i .. $])
                {
                    if (n < (ulong.max >> 4))
                        n = n * 10 + (c - '0');
                }
            }
            auto id = repo.peel(resolveRevision(repo, rev[0 .. i - 1]), ObjectType.commit);
            if (n == 0)
                return id;
            if (op == '^')
            {
                auto c = repo.commit(id);
                if (n > c.parents.length)
                    throw new GitError("no such parent");
                return c.parents[cast(size_t) n - 1];
            }
            foreach (_; 0 .. n)
            {
                auto c = repo.commit(id);
                if (c.parents.length == 0)
                    throw new GitError("no parent");
                id = c.parents[0];
            }
            return id;
        }
    }
    // 3. names
    ObjectId id;
    foreach (pattern; ["", "refs/", "refs/tags/", "refs/heads/", "refs/remotes/"])
    {
        if (repo.refs.resolve(pattern ~ rev, id))
            return id;
    }
    if (repo.refs.resolve("refs/remotes/" ~ rev ~ "/HEAD", id))
        return id;
    // 4. object ids
    if (rev.length >= 4 && rev.length <= 40)
    {
        foreach (c; rev)
            if (hexValue(c) < 0)
                goto notHex;
        return findByPrefix(repo, rev);
    }
notHex:
    throw new GitError("cannot resolve revision");
}

private ObjectId findByPrefix(Repository repo, string hex)
{
    ObjectId lo, hi;
    foreach (i; 0 .. 20)
    {
        lo.bytes[i] = 0x00;
        hi.bytes[i] = 0xff;
    }
    foreach (i, c; hex)
    {
        immutable v = cast(ubyte) hexValue(c);
        if (i % 2 == 0)
        {
            lo.bytes[i / 2] = cast(ubyte)(v << 4);
            hi.bytes[i / 2] = cast(ubyte)(v << 4 | 0xf);
        }
        else
        {
            lo.bytes[i / 2] |= v;
            hi.bytes[i / 2] = cast(ubyte)((hi.bytes[i / 2] & 0xf0) | v);
        }
    }
    if (hex.length == 40)
    {
        if (!repo.store.has(lo))
            throw new GitError("object not found");
        return lo;
    }
    auto ids = repo.store.allIds();
    size_t a = 0, b = ids.length;
    while (a < b)
    {
        immutable m = a + (b - a) / 2;
        if (ids[m] < lo)
            a = m + 1;
        else
            b = m;
    }
    if (a >= ids.length || ids[a] > hi)
        throw new GitError("unknown abbreviated id");
    if (a + 1 < ids.length && !(ids[a + 1] > hi))
        throw new GitError("ambiguous abbreviated id");
    return ids[a];
}

private ObjectId applyPeel(Repository repo, ObjectId id, string what)
{
    switch (what)
    {
    case "":
        for (;;)
        {
            auto o = repo.readObject(id);
            if (o.type != ObjectType.tag)
                return id;
            id = repo.tagTarget(id);
        }
    case "commit":
        return peelTo(repo, id, ObjectType.commit);
    case "tree":
        return peelTo(repo, id, ObjectType.tree);
    case "blob":
        return peelTo(repo, id, ObjectType.blob);
    case "tag":
        return peelTo(repo, id, ObjectType.tag);
    case "object":
        if (!repo.store.has(id))
            throw new GitError("object not found");
        return id;
    default:
        throw new GitError("unknown peel");
    }
}

/// Repeatedly: stop at an object of type `want`; tags give their target, commits their tree; anything else fails.
ObjectId peelTo(Repository repo, ObjectId id, ObjectType want)
{
    for (;;)
    {
        auto o = repo.readObject(id);
        if (o.type == want)
            return id;
        if (o.type == ObjectType.tag)
            id = repo.tagTarget(id);
        else if (o.type == ObjectType.commit)
        {
            auto c = repo.commit(id);
            if (!c.hasTree)
                throw new GitError("commit without tree");
            id = c.tree;
        }
        else
            throw new GitError("cannot peel");
    }
}
