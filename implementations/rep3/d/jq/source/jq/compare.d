/// The total order on values (and equality derived from it).
module jq.compare;

import jq.value;

/// Three-way comparison: null < false < true < numbers < strings < arrays <
/// objects; arrays element-wise; objects by sorted key list, then by the
/// values in sorted key order. Allocates nothing (beyond memoising an
/// object's sorted key order).
int compare(Value a, Value b) pure nothrow @trusted
{
    if (a.tag != b.tag)
        return a.tag < b.tag ? -1 : 1;
    final switch (a.tag)
    {
    case Tag.null_:
    case Tag.false_:
    case Tag.true_:
        return 0;
    case Tag.number:
        return a.num_ < b.num_ ? -1 : (a.num_ > b.num_ ? 1 : 0);
    case Tag.string_:
        return cmpStr(a.str, b.str);
    case Tag.array:
        {
            if (a.ap is b.ap && a.len == b.len)
                return 0;
            auto x = a.arr, y = b.arr;
            immutable m = x.length < y.length ? x.length : y.length;
            foreach (i; 0 .. m)
            {
                immutable c = compare(x[i], y[i]);
                if (c)
                    return c;
            }
            return x.length < y.length ? -1 : (x.length > y.length ? 1 : 0);
        }
    case Tag.object:
        {
            if (a.op is b.op)
                return 0;
            auto oa = a.op, ob = b.op;
            auto sa = oa.sortedOrder(), sb = ob.sortedOrder();
            auto ea = oa.entries, eb = ob.entries;
            immutable m = ea.length < eb.length ? ea.length : eb.length;
            foreach (i; 0 .. m)
            {
                immutable c = cmpStr(ea[sa[i]].key, eb[sb[i]].key);
                if (c)
                    return c;
            }
            if (ea.length != eb.length)
                return ea.length < eb.length ? -1 : 1;
            foreach (i; 0 .. ea.length)
            {
                immutable c = compare(ea[sa[i]].val, eb[sb[i]].val);
                if (c)
                    return c;
            }
            return 0;
        }
    }
}

/// Equality under the total order.
bool equals(Value a, Value b) pure nothrow @trusted
{
    return compare(a, b) == 0;
}
