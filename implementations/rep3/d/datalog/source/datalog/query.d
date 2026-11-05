/**
 * Answering queries against a computed model and formatting the output.
 */
module datalog.query;

import std.algorithm.sorting : sort;
import std.array : Appender;

import datalog.ast;
import datalog.engine;
import datalog.relation;

/**
 * Appends the answer to `query` to `output`: the matching tuples of the
 * predicate in ascending tuple order, one `p(v1, v2)` per line, then `-- N`.
 *
 * Params:
 *   texts = printed form of every constant, indexed by constant id
 */
void answerQuery(const ref Program program, ref Database db, const ref Query query,
                 const(string)[] texts, ref Appender!(char[]) output)
{
    const atom = query.atom;
    auto rel = db.relations[atom.predicate];

    uint mask;
    foreach (i, t; atom.args)
        if (!t.isVar) mask |= 1u << i;

    uint[] matches;
    auto firstSeen = new uint[query.numVars];
    auto seen = new bool[query.numVars];

    bool matchesTuple(const(uint)[] t)
    {
        seen[] = false;
        foreach (i, a; atom.args)
        {
            if (!a.isVar)
            {
                if (t[i] != a.id) return false;
            }
            else if (!seen[a.id])
            {
                seen[a.id] = true;
                firstSeen[a.id] = t[i];
            }
            else if (firstSeen[a.id] != t[i])
                return false;
        }
        return true;
    }

    if (mask != 0)
    {
        auto ix = rel.indexOn(mask);
        ix.update();
        uint[] key;
        foreach (c; ix.columns)
            key ~= atom.args[c].id;
        const nx = ix.next;
        for (uint p = ix.find(key); p != none; p = nx[p])
            if (matchesTuple(rel[p]))
                matches ~= p;
    }
    else
    {
        foreach (p; 0 .. rel.length)
            if (matchesTuple(rel[p]))
                matches ~= p;
    }

    matches.sort!((a, b) => rel[a] < rel[b]);

    const name = program.predicates[atom.predicate].name;
    foreach (p; matches)
    {
        output.put(name);
        output.put('(');
        foreach (i, v; rel[p])
        {
            if (i) output.put(", ");
            output.put(texts[v]);
        }
        output.put(")\n");
    }
    output.put("-- ");
    putNumber(output, matches.length);
    output.put('\n');
}

private void putNumber(ref Appender!(char[]) output, size_t n)
{
    char[20] buf;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + n % 10);
        n /= 10;
    } while (n);
    output.put(buf[i .. $]);
}
