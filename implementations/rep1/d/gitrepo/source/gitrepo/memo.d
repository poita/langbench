/// A tiny memoising map keyed by object id (successes *and* failures).
module gitrepo.memo;

import gitrepo.errors;
import gitrepo.objectid;

/// Computes each value at most once per key. A computation that throws
/// `GitError` is remembered too, so a damaged object is decoded only once.
struct Memo(T)
{
    private T[ObjectId] values;
    private string[ObjectId] failures;

    /// Return the value for `id`, calling `compute()` the first time only.
    T get(const ObjectId id, scope T delegate() compute)
    {
        if (auto p = id in values)
            return *p;
        if (auto e = id in failures)
            throw new GitError(*e);
        try
        {
            auto v = compute();
            values[id] = v;
            return v;
        }
        catch (GitError e)
        {
            failures[id] = e.msg;
            throw e;
        }
    }
}

unittest
{
    Memo!int m;
    int calls;
    auto id = ObjectId.zero;
    assert(m.get(id, { ++calls; return 7; }) == 7);
    assert(m.get(id, { ++calls; return 8; }) == 7);
    assert(calls == 1);

    Memo!int bad;
    ObjectId other;
    other.bytes[0] = 1;
    foreach (_; 0 .. 3)
    {
        bool threw;
        try
            bad.get(other, { ++calls; throw new GitError("boom"); return 0; });
        catch (GitError)
            threw = true;
        assert(threw);
    }
    assert(calls == 2);
}
