/// Answering queries against a computed `Database` and rendering the output.
module datalog.query;

import std.algorithm : sort;
import std.array : Appender;
import std.conv : to;
import datalog.ast;
import datalog.engine;
import datalog.relation;

/// All tuples matching `q`, in ascending tuple order, as a flat array with stride
/// equal to the query's arity.
///
/// A constant in the query must equal the tuple's component; a variable that occurs
/// several times must bind the same constant everywhere.
uint[] matchQuery(Database db, in Query q)
{
    auto rel = db.relations[q.atom.pred];
    immutable ar = rel.arity;

    uint keyMask = 0;
    uint[maxArity] key;
    size_t nk = 0;
    // For every position, the earlier position holding the same variable (or ar).
    uint[maxArity] sameAs;
    auto firstPos = new uint[q.numVars];
    firstPos[] = uint.max;
    foreach (i, t; q.atom.args)
    {
        sameAs[i] = uint.max;
        if (!t.isVar)
        {
            keyMask |= 1u << i;
            key[nk++] = t.id;
        }
        else if (firstPos[t.id] != uint.max)
            sameAs[i] = firstPos[t.id];
        else
            firstPos[t.id] = cast(uint) i;
    }

    uint[] hits;
    void consider(uint pos)
    {
        auto t = rel.tuple(pos);
        foreach (i; 0 .. ar)
            if (sameAs[i] != uint.max && t[i] != t[sameAs[i]]) return;
        hits ~= pos;
    }

    if (keyMask != 0)
    {
        auto ix = rel.index(keyMask);
        ix.update();
        for (uint pos = ix.find(key.ptr); pos != Index.none; pos = ix.next(pos))
            consider(pos);
    }
    else
        foreach (pos; 0 .. rel.length) consider(cast(uint) pos);

    hits.sort!((a, b) => rel.tuple(a) < rel.tuple(b));
    uint[] flat;
    flat.reserve(hits.length * ar);
    foreach (pos; hits) flat ~= rel.tuple(pos);
    return flat;
}

/// Append the printed answer to query `q` (its tuples followed by `-- N`) to `sink`.
void renderQuery(ref Appender!(char[]) sink, Database db, in Query q)
{
    auto prog = db.program;
    auto name = prog.predicates[q.atom.pred].name;
    immutable ar = prog.predicates[q.atom.pred].arity;
    auto flat = matchQuery(db, q);
    immutable n = flat.length / ar;
    foreach (i; 0 .. n)
    {
        sink.put(name);
        sink.put('(');
        foreach (j; 0 .. ar)
        {
            if (j) sink.put(", ");
            sink.put(prog.constants[flat[i * ar + j]]);
        }
        sink.put(")\n");
    }
    sink.put("-- ");
    sink.put(n.to!string);
    sink.put('\n');
}

/// Render the answers of every query of the program, in order.
string renderAnswers(Database db)
{
    Appender!(char[]) sink;
    sink.reserve(1 << 16);
    foreach (ref q; db.program.queries)
        renderQuery(sink, db, q);
    return cast(string) sink.data;
}
