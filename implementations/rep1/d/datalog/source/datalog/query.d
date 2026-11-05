/// Answering queries against a computed model, and rendering answers as text.
module datalog.query;

import std.algorithm.sorting : sort;
import std.array : Appender;
import std.conv : to;

import datalog.ast;
import datalog.eval : Model;
import datalog.relation;

/// All tuples of the queried predicate matching `query`, in ascending tuple order.
///
/// Each returned slice is a full tuple (not the query pattern). A repeated
/// variable must match equal values at its positions; `_` matches anything.
const(Value)[][] answer(Model model, ref const Query query) @safe
{
    auto atom = query.atom;
    auto rel = model.relations[atom.pred];
    immutable arity = atom.args.length;

    // firstOcc[j] = position of the first occurrence of the variable at j (== j if first).
    auto firstOcc = new size_t[arity];
    uint keyMask = 0;
    Value[] key;
    foreach (j, t; atom.args)
    {
        firstOcc[j] = j;
        if (!t.isVariable)
        {
            keyMask |= 1u << j;
            key ~= t.id;
        }
        else
            foreach (k; 0 .. j)
                if (atom.args[k].isVariable && atom.args[k].id == t.id)
                {
                    firstOcc[j] = k;
                    break;
                }
    }

    bool matches(const(Value)[] tuple)
    {
        foreach (j, t; atom.args)
        {
            if (!t.isVariable)
            {
                if (tuple[j] != t.id)
                    return false;
            }
            else if (firstOcc[j] != j && tuple[j] != tuple[firstOcc[j]])
                return false;
        }
        return true;
    }

    const(Value)[][] result;
    auto idx = keyMask ? rel.findIndex(keyMask) : null;
    if (idx !is null)
    {
        idx.update();
        for (uint p = idx.first(key); p != noPos; p = idx.next[p])
            if (matches(rel[p]))
                result ~= rel[p];
    }
    else
    {
        foreach (p; 0 .. rel.length)
            if (matches(rel[p]))
                result ~= rel[p];
    }
    result.sort!((a, b) => a < b);
    return result;
}

/// Append the answer to `query` to `output` in the program's output format:
/// one `pred(v1, v2, ...)` line per tuple followed by `-- N`.
void renderAnswer(Model model, ref const Query query, ref Appender!string output) @safe
{
    auto program = model.program;
    auto name = program.predicates[query.atom.pred].name;
    auto rows = answer(model, query);
    foreach (row; rows)
    {
        output.put(name);
        output.put('(');
        foreach (j, v; row)
        {
            if (j)
                output.put(", ");
            output.put(program.constantText(v));
        }
        output.put(")\n");
    }
    output.put("-- ");
    output.put(rows.length.to!string);
    output.put('\n');
}
