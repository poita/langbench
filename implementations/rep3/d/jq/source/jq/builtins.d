/// Implementations of the builtin functions that work on whole values.
module jq.builtins;

import std.algorithm.sorting : sort;
import jq.arith;
import jq.buffer;
import jq.compare;
import jq.errors;
import jq.json;
import jq.number;
import jq.value;

/// `type`.
string typeName(Value v) pure nothrow @nogc @safe
{
    final switch (v.tag)
    {
    case Tag.null_: return "null";
    case Tag.false_, Tag.true_: return "boolean";
    case Tag.number: return "number";
    case Tag.string_: return "string";
    case Tag.array: return "array";
    case Tag.object: return "object";
    }
}

/// `length`.
Value lengthOf(Value v)
{
    final switch (v.tag)
    {
    case Tag.null_: return mkNum(0);
    case Tag.false_, Tag.true_: throw new JqError("boolean has no length");
    case Tag.number: return mkNum(v.num < 0 ? -v.num : v.num);
    case Tag.string_: return mkNum(cpLength(v.str));
    case Tag.array: return mkNum(v.len);
    case Tag.object: return mkNum(v.obj.length);
    }
}

/// `keys`.
Value keysOf(Value v)
{
    if (v.isObject)
    {
        auto o = v.obj;
        auto ents = o.entries;
        auto ord = o.sortedOrder();
        auto r = new Value[ents.length];
        foreach (i, p; ord)
            r[i] = mkStr(ents[p].key);
        return mkArr(r);
    }
    if (v.isArray)
    {
        auto r = new Value[v.len];
        foreach (i; 0 .. r.length)
            r[i] = mkNum(i);
        return mkArr(r);
    }
    throw new JqError("has no keys");
}

/// `has(k)`.
Value hasKey(Value v, Value k)
{
    if (v.isNull)
        return mkBool(false);
    if (v.isObject && k.isString)
        return mkBool(v.obj.find(k.str) >= 0);
    if (v.isArray && k.isNumber)
    {
        immutable d = k.num;
        return mkBool(d > -1 && d < v.len);
    }
    throw new JqError("cannot check whether it has a key");
}

/// `reverse`.
Value reverseOf(Value v)
{
    if (v.isNull)
        return mkArr(null);
    if (!v.isArray)
        throw new JqError("cannot be reversed");
    auto a = v.arr;
    auto r = new Value[a.length];
    foreach (i; 0 .. a.length)
        r[i] = a[a.length - 1 - i];
    return mkArr(r);
}

/// `tostring`.
Value toStringV(Value v)
{
    if (v.isString)
        return v;
    return mkStr(toJson(v));
}

/// `tonumber`.
Value toNumberV(Value v)
{
    if (v.isNumber)
        return v;
    if (v.isString)
    {
        double d;
        if (tryParseNumber(v.str, d))
            return mkNum(d);
    }
    throw new JqError("cannot be parsed as a number");
}

/// `min` (`wantMax == false`) or `max`.
Value minMax(Value v, bool wantMax)
{
    if (!v.isArray)
        throw new JqError("cannot take min/max");
    auto a = v.arr;
    if (a.length == 0)
        return mkNull();
    Value best = a[0];
    foreach (x; a[1 .. $])
    {
        immutable c = compare(x, best);
        if (wantMax ? c >= 0 : c < 0)
            best = x;
    }
    return best;
}

private uint[] sortedIndices(const(Value)[] keys) nothrow
{
    auto ix = new uint[keys.length];
    foreach (i; 0 .. ix.length)
        ix[i] = cast(uint) i;
    ix.sort!((a, b) {
        immutable c = compare(cast() keys[a], cast() keys[b]);
        return c < 0 || (c == 0 && a < b);
    });
    return ix;
}

/// `sort`.
Value sortValues(Value v)
{
    if (!v.isArray)
        throw new JqError("cannot be sorted");
    auto a = v.arr;
    auto ix = sortedIndices(a);
    auto r = new Value[a.length];
    foreach (i, p; ix)
        r[i] = a[p];
    return mkArr(r);
}

/// `sort_by(f)` given the precomputed key of each element.
Value sortByKeys(Value v, Value[] keys)
{
    auto a = v.arr;
    auto ix = sortedIndices(keys);
    auto r = new Value[a.length];
    foreach (i, p; ix)
        r[i] = a[p];
    return mkArr(r);
}

/// `group_by(f)` given the precomputed key of each element.
Value groupByKeys(Value v, Value[] keys)
{
    auto a = v.arr;
    auto ix = sortedIndices(keys);
    Value[] groups;
    size_t i = 0;
    while (i < ix.length)
    {
        size_t j = i + 1;
        while (j < ix.length && compare(keys[ix[j]], keys[ix[i]]) == 0)
            ++j;
        auto g = new Value[j - i];
        foreach (k; i .. j)
            g[k - i] = a[ix[k]];
        groups ~= mkArr(g);
        i = j;
    }
    return mkArr(groups);
}

/// `unique`.
Value uniqueValues(Value v)
{
    if (!v.isArray)
        throw new JqError("cannot be sorted");
    auto a = v.arr;
    auto ix = sortedIndices(a);
    Value[] r;
    r.reserve(a.length);
    foreach (i, p; ix)
        if (i == 0 || compare(a[p], r[$ - 1]) != 0)
            r ~= a[p];
    return mkArr(r);
}

/// `add`: folds the elements of an array (or values of an object) with `+`
/// using one private builder, so the whole fold is linear in the total size.
Value addAll(Value v)
{
    Value[] items;
    Value[1] holder;
    if (v.isArray)
        items = v.arr;
    else if (v.isObject)
    {
        auto ents = v.obj.entries;
        items = new Value[ents.length];
        foreach (i, e; ents)
            items[i] = e.val;
    }
    else
        throw new JqError("cannot iterate over it");

    Value first;
    size_t idx = 0;
    while (idx < items.length && items[idx].isNull)
        ++idx;
    if (idx == items.length)
        return mkNull();
    first = items[idx++];
    switch (first.tag)
    {
    case Tag.number:
        {
            double sum = first.num;
            for (; idx < items.length; ++idx)
            {
                auto x = items[idx];
                if (x.isNull)
                    continue;
                if (!x.isNumber)
                    throw new JqError("cannot be added");
                sum += x.num;
            }
            return mkNum(sum);
        }
    case Tag.string_:
        {
            Buf b;
            b.put(first.str);
            for (; idx < items.length; ++idx)
            {
                auto x = items[idx];
                if (x.isNull)
                    continue;
                if (!x.isString)
                    throw new JqError("cannot be added");
                b.put(x.str);
            }
            return mkStr(b.slice.idup);
        }
    case Tag.array:
        {
            Value[] r;
            r ~= first.arr;
            for (; idx < items.length; ++idx)
            {
                auto x = items[idx];
                if (x.isNull)
                    continue;
                if (!x.isArray)
                    throw new JqError("cannot be added");
                r ~= x.arr;
            }
            return mkArr(r);
        }
    case Tag.object:
        {
            Obj o = Obj.copyOf(first.obj, 0);
            for (; idx < items.length; ++idx)
            {
                auto x = items[idx];
                if (x.isNull)
                    continue;
                if (!x.isObject)
                    throw new JqError("cannot be added");
                foreach (e; x.obj.entries)
                    o.set(e.key, e.val);
            }
            return mkObj(o);
        }
    default:
        // booleans: only `null + x` style combinations are valid
        if (idx == items.length)
            return first;
        foreach (x; items[idx .. $])
            if (!x.isNull)
                throw new JqError("cannot be added");
        return first;
    }
}
