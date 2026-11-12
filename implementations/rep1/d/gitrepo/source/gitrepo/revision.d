/// Revision syntax: names, abbreviated ids, `^`, `~` and `^{...}`.
module gitrepo.revision;

import gitrepo.errors;
import gitrepo.hex;
import gitrepo.objectid;
import gitrepo.objecttype;
import gitrepo.repository;

/// Resolve a revision expression to an object id. Only locates the object; it
/// does not verify its content (although `^`, `~` and `^{type}` do read the
/// objects they step through).
///
/// The rules, in order:
/// $(OL
///   $(LI `<rev>^{<peel>}` — resolve `<rev>`, then peel (`{}`, `{commit}`,
///        `{tree}`, `{blob}`, `{tag}`, `{object}`).)
///   $(LI `<rev>^<n>`, `<rev>^`, `<rev>~<n>`, `<rev>~` — resolve `<rev>`,
///        peel it to a commit, then pick the n-th parent / walk first parents.)
///   $(LI a ref name, tried as `<name>`, `refs/<name>`, `refs/tags/<name>`,
///        `refs/heads/<name>`, `refs/remotes/<name>`, `refs/remotes/<name>/HEAD`.)
///   $(LI 4 to 40 hexadecimal digits: a full id that must exist, or an
///        unambiguous abbreviation.)
/// )
/// Throws: `GitError` if the revision cannot be resolved.
ObjectId resolveRevision(Repository repo, string rev)
{
    // Rule 1: <rev>^{<peel>}
    if (rev.length > 0 && rev[$ - 1] == '}')
    {
        immutable at = lastIndexOf(rev, "^{");
        if (at > 0)
        {
            auto base = resolveRevision(repo, rev[0 .. at]);
            return applyPeel(repo, base, rev[at + 2 .. $ - 1]);
        }
    }

    // Rule 2: <rev>^<n> and <rev>~<n>
    {
        size_t d = rev.length;
        while (d > 0 && rev[d - 1] >= '0' && rev[d - 1] <= '9')
            --d;
        if (d > 1 && (rev[d - 1] == '^' || rev[d - 1] == '~'))
        {
            immutable op = rev[d - 1];
            ulong n = 1;
            if (d < rev.length)
            {
                n = 0;
                foreach (c; rev[d .. $])
                    n = n > (ulong.max - 9) / 10 ? ulong.max : n * 10 + (c - '0');
            }
            auto id = peel(repo, resolveRevision(repo, rev[0 .. d - 1]), ObjectType.commit);
            if (op == '^')
            {
                if (n == 0)
                    return id;
                auto parents = repo.commit(id).parents;
                if (n > parents.length)
                    throw new GitError("no such parent");
                return parents[cast(size_t)(n - 1)];
            }
            for (ulong i = 0; i < n; ++i)
            {
                auto parents = repo.commit(id).parents;
                if (parents.length == 0)
                    throw new GitError("commit has no parent");
                id = parents[0];
            }
            return id;
        }
    }

    // Rule 3: a ref name
    {
        ObjectId id;
        foreach (pattern; [
                rev, "refs/" ~ rev, "refs/tags/" ~ rev, "refs/heads/" ~ rev,
                "refs/remotes/" ~ rev, "refs/remotes/" ~ rev ~ "/HEAD"
            ])
            if (repo.refs.resolve(pattern, id))
                return id;
    }

    // Rule 4: an object id or abbreviation
    if (rev.length >= 4 && rev.length <= 40 && isHex(rev))
    {
        if (rev.length == 40)
        {
            auto id = ObjectId.parse(rev);
            if (repo.objects.contains(id))
                return id;
            throw new GitError("no such object");
        }
        auto found = repo.objects.findByPrefix(rev, 2);
        if (found.length == 1)
            return found[0];
        throw new GitError(found.length == 0 ? "no such object" : "ambiguous abbreviation");
    }

    // Rule 5
    throw new GitError("cannot resolve revision");
}

/// Repeatedly unwrap `id` until it has type `want`: a tag is replaced by its
/// target and a commit by its tree. Anything else is an error.
ObjectId peel(Repository repo, ObjectId id, ObjectType want)
{
    while (true)
    {
        immutable type = repo.readObject(id).type;
        if (type == want)
            return id;
        switch (type)
        {
        case ObjectType.tag:
            id = repo.tagTarget(id);
            break;
        case ObjectType.commit:
            id = repo.commit(id).tree;
            break;
        default:
            throw new GitError("cannot peel to " ~ typeName(want));
        }
    }
}

/// Apply the text between the braces of `^{...}` to `id`.
private ObjectId applyPeel(Repository repo, ObjectId id, string what)
{
    switch (what)
    {
    case "":
        while (repo.readObject(id).type == ObjectType.tag)
            id = repo.tagTarget(id);
        return id;
    case "object":
        if (!repo.objects.contains(id))
            throw new GitError("no such object");
        return id;
    default:
        ObjectType t;
        if (!tryParseType(what, t))
            throw new GitError("unknown peel type");
        return peel(repo, id, t);
    }
}

private ptrdiff_t lastIndexOf(string s, string needle) @safe pure nothrow @nogc
{
    if (s.length < needle.length)
        return -1;
    for (size_t i = s.length - needle.length + 1; i-- > 0;)
        if (s[i .. i + needle.length] == needle)
            return i;
    return -1;
}

unittest
{
    assert(lastIndexOf("a^{b}^{c}", "^{") == 5);
    assert(lastIndexOf("^{x}", "^{") == 0);
    assert(lastIndexOf("abc", "^{") == -1);
}
