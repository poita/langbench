/// The 132 built-in functions (SPEC.md section 15).
module langvm.builtins;

import langvm.numfmt;
import langvm.value;
import langvm.vm : VM, Panic, appendStr;

/// Every built-in function. The member names are the Vellum names; the
/// numeric value is what `CALL_BUILTIN` carries.
enum Builtin : int
{
    absF, absI, ceilF, charAt, chars, chr,
    clear, clz, cmpC, cmpF, cmpI, ctz,
    divFloor, emit, endsWith, floatBits, floatFromBits, floorF,
    fmodF, fmt, fst, gcdI, infF, insert,
    intMax, intMin, isAlnum, isAlpha, isDigit, isErr,
    isInfF, isLower, isNanF, isNone, isOk, isSome,
    isSpace, isUpper, keysOf, listAll, listAny, listConcat,
    listContains, listCopy, listFilter, listFind, listFindIndex, listFirst,
    listFlatten, listFold, listIndexOf, listLast, listLen, listMap,
    listNew, listRepeat, listZip, lower, mapClear, mapCopy,
    mapDel, mapGet, mapGetOr, mapHas, mapLen, mapNew,
    mapSet, maxF, maxI, minF, minI, modFloor,
    nanF, ord, padLeft, padRight, pairsOf, panic,
    parseFloat, parseInt, parseIntRadix, piF, pop, popCount,
    powF, powI, print, push, quoteChar, quoteStr,
    removeAt, reverseList, roundF, showBool, showChar, showFloat,
    showFloatAt, showInt, showIntRadix, signI, slice, snd,
    sortBy, sqrtF, startsWith, strCat, strCmp, strContains,
    strIndexOf, strJoin, strLastIndexOf, strLen, strOfChars, strRepeat,
    strReplace, strReverse, strSplit, substr, toFloat, toLowerC,
    toUpperC, trim, trimLeft, trimRight, truncF, truncToInt,
    unwrap, unwrapErr, unwrapOk, unwrapOr, upper, valuesOf,
}

private immutable int[string] builtinIds;

shared static this()
{
    import std.conv : to;
    import std.traits : EnumMembers;

    int[string] m;
    static foreach (b; EnumMembers!Builtin)
        m[b.to!string] = cast(int) b;
    builtinIds = cast(immutable) m;
}

/// The id of the built-in named `name`, or -1.
int builtinIdByName(string name)
{
    if (auto p = name in builtinIds)
        return *p;
    return -1;
}

private Panic panicMsg(string m)
{
    return new Panic(m);
}

private Value mkStr(dstring s)
{
    return Value.ofStr(s);
}

private Value mkStr(const(dchar)[] s)
{
    return Value.ofStr(s.idup);
}

private Value unit()
{
    return Value.init;
}

private bool isSpaceC(dchar c) @nogc nothrow
{
    return c == ' ' || (c >= 9 && c <= 13);
}

private dchar upperC(dchar c) @nogc nothrow
{
    return c >= 'a' && c <= 'z' ? cast(dchar)(c - 32) : c;
}

private dchar lowerC(dchar c) @nogc nothrow
{
    return c >= 'A' && c <= 'Z' ? cast(dchar)(c + 32) : c;
}

private dstring ascii(string s)
{
    dchar[] r = new dchar[s.length];
    foreach (i, c; s)
        r[i] = c;
    return cast(dstring) r;
}

/// Append the escape of `c` as `quoteStr` / `quoteChar` define it.
private void escapeInto(ref dchar[] o, dchar c, dchar quote)
{
    import std.format : format;

    if (c == '\\')
        o ~= "\\\\"d;
    else if (c == quote)
    {
        o ~= '\\';
        o ~= c;
    }
    else if (c == '\n')
        o ~= "\\n"d;
    else if (c == '\r')
        o ~= "\\r"d;
    else if (c == '\t')
        o ~= "\\t"d;
    else if (c < 0x20 || c == 0x7f)
    {
        o ~= "\\u{"d;
        o ~= ascii(format("%x", cast(uint) c));
        o ~= '}';
    }
    else
        o ~= c;
}

private size_t indexOfSub(const(dchar)[] s, const(dchar)[] sub, size_t from = 0)
{
    if (sub.length == 0)
        return from;
    if (sub.length > s.length)
        return size_t.max;
    const last = s.length - sub.length;
    for (size_t i = from; i <= last; i++)
    {
        if (s[i] != sub[0])
            continue;
        if (s[i .. i + sub.length] == sub)
            return i;
    }
    return size_t.max;
}

private Value some(VM vm, Value v)
{
    return Value.ofObj(Tag.enum_, new AggObj(vm.optionDecl, someVariant, [v]));
}

private Value none(VM vm)
{
    return vm.noneValue;
}

private Value tuple2(Value a, Value b)
{
    return Value.ofObj(Tag.tuple, new AggObj(-1, 0, [a, b]));
}

private Value mkOption(VM vm, bool has, Value v)
{
    return has ? some(vm, v) : none(vm);
}

private void checkIndex(long i, size_t len)
{
    if (i < 0 || cast(ulong) i >= len)
        throw panicMsg("index out of bounds");
}

/// Call built-in `id` with its arguments.
Value callBuiltin(VM vm, int id, Value[] a)
{
    import core.bitop : bsf, bsr, popcnt;
    import core.stdc.math : fmod;
    import std.math : ceil, fabs, floor, isInfinity, isNaN, round, sqrt, trunc;

    final switch (cast(Builtin) id)
    {
    // ---- output
    case Builtin.print:
        vm.write(a[0].str.s);
        vm.writeChar('\n');
        return unit();
    case Builtin.emit:
        vm.write(a[0].str.s);
        return unit();
    case Builtin.panic:
    {
        import std.conv : to;

        throw panicMsg(a[0].str.s.to!string);
    }

    // ---- integers
    case Builtin.intMin:
        return Value.ofInt(long.min);
    case Builtin.intMax:
        return Value.ofInt(long.max);
    case Builtin.absI:
        return Value.ofInt(a[0].i < 0 ? -a[0].i : a[0].i);
    case Builtin.minI:
        return Value.ofInt(a[0].i < a[1].i ? a[0].i : a[1].i);
    case Builtin.maxI:
        return Value.ofInt(a[0].i > a[1].i ? a[0].i : a[1].i);
    case Builtin.signI:
        return Value.ofInt(a[0].i < 0 ? -1 : (a[0].i > 0 ? 1 : 0));
    case Builtin.cmpI:
        return Value.ofInt(a[0].i < a[1].i ? -1 : (a[0].i > a[1].i ? 1 : 0));
    case Builtin.divFloor:
    {
        const x = a[0].i, y = a[1].i;
        if (y == 0)
            throw panicMsg("divide by zero");
        if (y == -1)
            return Value.ofInt(-x);
        long q = x / y;
        if ((x % y != 0) && ((x < 0) != (y < 0)))
            q--;
        return Value.ofInt(q);
    }
    case Builtin.modFloor:
    {
        const x = a[0].i, y = a[1].i;
        if (y == 0)
            throw panicMsg("modulo by zero");
        if (y == -1)
            return Value.ofInt(0);
        long r = x % y;
        if (r != 0 && ((r < 0) != (y < 0)))
            r += y;
        return Value.ofInt(r);
    }
    case Builtin.powI:
    {
        long base = a[0].i, e = a[1].i;
        if (e < 0)
            throw panicMsg("negative exponent");
        long r = 1;
        while (e > 0)
        {
            if (e & 1)
                r *= base;
            e >>= 1;
            if (e > 0)
                base *= base;
        }
        return Value.ofInt(r);
    }
    case Builtin.gcdI:
    {
        ulong x = a[0].i < 0 ? -cast(ulong) a[0].i : cast(ulong) a[0].i;
        ulong y = a[1].i < 0 ? -cast(ulong) a[1].i : cast(ulong) a[1].i;
        while (y != 0)
        {
            const t = x % y;
            x = y;
            y = t;
        }
        return Value.ofInt(cast(long) x);
    }
    case Builtin.popCount:
        return Value.ofInt(popcnt(cast(ulong) a[0].i));
    case Builtin.clz:
        return Value.ofInt(a[0].i == 0 ? 64 : 63 - bsr(cast(ulong) a[0].i));
    case Builtin.ctz:
        return Value.ofInt(a[0].i == 0 ? 64 : bsf(cast(ulong) a[0].i));
    case Builtin.toFloat:
        return Value.ofFloat(cast(double) a[0].i);
    case Builtin.showInt:
    {
        import std.conv : to;

        return mkStr(ascii(a[0].i.to!string));
    }
    case Builtin.showIntRadix:
        if (a[1].i < 2 || a[1].i > 36)
            throw panicMsg("radix out of range");
        return mkStr(ascii(formatRadix(a[0].i, cast(int) a[1].i)));
    case Builtin.parseInt:
    {
        long v;
        const ok = parseRadix(a[0].str.s, 10, v);
        return mkOption(vm, ok, Value.ofInt(v));
    }
    case Builtin.parseIntRadix:
    {
        if (a[1].i < 2 || a[1].i > 36)
            throw panicMsg("radix out of range");
        long v;
        const ok = parseRadix(a[0].str.s, cast(int) a[1].i, v);
        return mkOption(vm, ok, Value.ofInt(v));
    }

    // ---- floats
    case Builtin.sqrtF:
        return Value.ofFloat(sqrt(a[0].f));
    case Builtin.absF:
        return Value.ofFloat(fabs(a[0].f));
    case Builtin.floorF:
        return Value.ofFloat(floor(a[0].f));
    case Builtin.ceilF:
        return Value.ofFloat(ceil(a[0].f));
    case Builtin.truncF:
        return Value.ofFloat(trunc(a[0].f));
    case Builtin.roundF:
        return Value.ofFloat(round(a[0].f));
    case Builtin.minF:
        return a[cmpFloats(a[0].f, a[1].f) <= 0 ? 0 : 1];
    case Builtin.maxF:
        return a[cmpFloats(a[0].f, a[1].f) >= 0 ? 0 : 1];
    case Builtin.fmodF:
        return Value.ofFloat(fmod(a[0].f, a[1].f));
    case Builtin.powF:
        return Value.ofFloat(powFloat(a[0].f, a[1].i));
    case Builtin.isNanF:
        return Value.ofBool(isNaN(a[0].f));
    case Builtin.isInfF:
        return Value.ofBool(isInfinity(a[0].f));
    case Builtin.cmpF:
        return Value.ofInt(cmpFloats(a[0].f, a[1].f));
    case Builtin.truncToInt:
    {
        const t = a[0].f;
        if (isNaN(t) || t >= 9223372036854775808.0 || t < -9223372036854775808.0)
            throw panicMsg("float out of integer range");
        return Value.ofInt(cast(long) t);
    }
    case Builtin.showFloat:
        return mkStr(ascii(formatFixed(a[0].f, 6)));
    case Builtin.showFloatAt:
        if (a[1].i < 0 || a[1].i > 17)
            throw panicMsg("digits out of range");
        return mkStr(ascii(formatFixed(a[0].f, cast(int) a[1].i)));
    case Builtin.floatBits:
        return Value.ofInt(*cast(long*)&a[0].f);
    case Builtin.floatFromBits:
        return Value.ofFloat(*cast(double*)&a[0].i);
    case Builtin.parseFloat:
    {
        double v;
        const ok = parseFloatText(a[0].str.s, v);
        return mkOption(vm, ok, Value.ofFloat(v));
    }
    case Builtin.infF:
        return Value.ofFloat(double.infinity);
    case Builtin.nanF:
    {
        const long bits = 0x7ff8000000000000;
        return Value.ofFloat(*cast(double*)&bits);
    }
    case Builtin.piF:
    {
        const long bits = 4614256656552045848;
        return Value.ofFloat(*cast(double*)&bits);
    }

    // ---- bools and chars
    case Builtin.showBool:
        return mkStr(a[0].i ? "true"d : "false"d);
    case Builtin.ord:
        return Value.ofInt(a[0].i);
    case Builtin.chr:
        if (a[0].i < 0 || a[0].i > 0x10FFFF || (a[0].i >= 0xD800 && a[0].i <= 0xDFFF))
            throw panicMsg("invalid char code");
        return Value.ofChar(a[0].i);
    case Builtin.isDigit:
        return Value.ofBool(a[0].i >= '0' && a[0].i <= '9');
    case Builtin.isAlpha:
        return Value.ofBool((a[0].i >= 'a' && a[0].i <= 'z') || (a[0].i >= 'A' && a[0].i <= 'Z'));
    case Builtin.isAlnum:
        return Value.ofBool((a[0].i >= '0' && a[0].i <= '9') || (a[0].i >= 'a' && a[0].i <= 'z')
                || (a[0].i >= 'A' && a[0].i <= 'Z'));
    case Builtin.isSpace:
        return Value.ofBool(isSpaceC(cast(dchar) a[0].i));
    case Builtin.isUpper:
        return Value.ofBool(a[0].i >= 'A' && a[0].i <= 'Z');
    case Builtin.isLower:
        return Value.ofBool(a[0].i >= 'a' && a[0].i <= 'z');
    case Builtin.toUpperC:
        return Value.ofChar(upperC(cast(dchar) a[0].i));
    case Builtin.toLowerC:
        return Value.ofChar(lowerC(cast(dchar) a[0].i));
    case Builtin.cmpC:
        return Value.ofInt(a[0].i < a[1].i ? -1 : (a[0].i > a[1].i ? 1 : 0));
    case Builtin.showChar:
        return mkStr([cast(dchar) a[0].i].idup);
    case Builtin.quoteChar:
    {
        dchar[] o = ['\''];
        escapeInto(o, cast(dchar) a[0].i, '\'');
        o ~= '\'';
        return mkStr(cast(dstring) o);
    }

    // ---- strings
    case Builtin.strLen:
        return Value.ofInt(a[0].str.s.length);
    case Builtin.charAt:
    {
        auto s = a[0].str.s;
        checkIndex(a[1].i, s.length);
        return Value.ofChar(s[cast(size_t) a[1].i]);
    }
    case Builtin.substr:
    {
        auto s = a[0].str.s;
        const from = a[1].i, to = a[2].i;
        if (from < 0 || from > to || cast(ulong) to > s.length)
            throw panicMsg("index out of bounds");
        return mkStr(s[cast(size_t) from .. cast(size_t) to]);
    }
    case Builtin.strCat:
        return mkStr(appendStr(a[0].str.s, a[1].str.s));
    case Builtin.strRepeat:
    {
        if (a[1].i < 0)
            throw panicMsg("negative count");
        dchar[] r;
        auto s = a[0].str.s;
        r.reserve(s.length * cast(size_t) a[1].i);
        foreach (_; 0 .. a[1].i)
            r ~= s;
        return mkStr(cast(dstring) r);
    }
    case Builtin.strIndexOf:
    {
        const r = indexOfSub(a[0].str.s, a[1].str.s);
        return Value.ofInt(r == size_t.max ? -1 : cast(long) r);
    }
    case Builtin.strLastIndexOf:
    {
        auto s = a[0].str.s, sub = a[1].str.s;
        if (sub.length > s.length)
            return Value.ofInt(-1);
        for (size_t i = s.length - sub.length + 1; i-- > 0;)
            if (s[i .. i + sub.length] == sub)
                return Value.ofInt(cast(long) i);
        return Value.ofInt(-1);
    }
    case Builtin.strContains:
        return Value.ofBool(indexOfSub(a[0].str.s, a[1].str.s) != size_t.max);
    case Builtin.startsWith:
    {
        auto s = a[0].str.s, p = a[1].str.s;
        return Value.ofBool(s.length >= p.length && s[0 .. p.length] == p);
    }
    case Builtin.endsWith:
    {
        auto s = a[0].str.s, p = a[1].str.s;
        return Value.ofBool(s.length >= p.length && s[$ - p.length .. $] == p);
    }
    case Builtin.strSplit:
    {
        auto s = a[0].str.s, sep = a[1].str.s;
        if (sep.length == 0)
            throw panicMsg("empty separator");
        auto res = new ListObj();
        size_t start = 0;
        while (true)
        {
            const i = indexOfSub(s, sep, start);
            if (i == size_t.max)
                break;
            res.push(mkStr(s[start .. i]));
            start = i + sep.length;
        }
        res.push(mkStr(s[start .. $]));
        return Value.ofObj(Tag.list, res);
    }
    case Builtin.strJoin:
    {
        auto parts = a[0].list;
        auto sep = a[1].str.s;
        dchar[] r;
        foreach (i; 0 .. parts.len)
        {
            if (i)
                r ~= sep;
            r ~= parts.buf[i].str.s;
        }
        return mkStr(cast(dstring) r);
    }
    case Builtin.strReplace:
    {
        auto s = a[0].str.s, from = a[1].str.s, to = a[2].str.s;
        if (from.length == 0)
            throw panicMsg("empty separator");
        dchar[] r;
        size_t i = 0;
        while (i < s.length)
        {
            if (i + from.length <= s.length && s[i .. i + from.length] == from)
            {
                r ~= to;
                i += from.length;
            }
            else
                r ~= s[i++];
        }
        return mkStr(cast(dstring) r);
    }
    case Builtin.trim, Builtin.trimLeft, Builtin.trimRight:
    {
        auto s = a[0].str.s;
        size_t lo = 0, hi = s.length;
        if (id != Builtin.trimRight)
            while (lo < hi && isSpaceC(s[lo]))
                lo++;
        if (id != Builtin.trimLeft)
            while (hi > lo && isSpaceC(s[hi - 1]))
                hi--;
        return mkStr(s[lo .. hi]);
    }
    case Builtin.upper:
    {
        auto s = a[0].str.s;
        auto r = new dchar[s.length];
        foreach (i, c; s)
            r[i] = upperC(c);
        return mkStr(cast(dstring) r);
    }
    case Builtin.lower:
    {
        auto s = a[0].str.s;
        auto r = new dchar[s.length];
        foreach (i, c; s)
            r[i] = lowerC(c);
        return mkStr(cast(dstring) r);
    }
    case Builtin.strCmp:
    {
        const c = compareValues(a[0], a[1]);
        return Value.ofInt(c);
    }
    case Builtin.chars:
    {
        auto s = a[0].str.s;
        auto items = new Value[s.length];
        foreach (i, c; s)
            items[i] = Value.ofChar(c);
        return Value.ofList(items);
    }
    case Builtin.strOfChars:
    {
        auto l = a[0].list;
        auto r = new dchar[l.len];
        foreach (i; 0 .. l.len)
            r[i] = cast(dchar) l.buf[i].i;
        return mkStr(cast(dstring) r);
    }
    case Builtin.strReverse:
    {
        auto s = a[0].str.s;
        auto r = new dchar[s.length];
        foreach (i, c; s)
            r[s.length - 1 - i] = c;
        return mkStr(cast(dstring) r);
    }
    case Builtin.quoteStr:
    {
        dchar[] o = ['"'];
        foreach (c; a[0].str.s)
            escapeInto(o, c, '"');
        o ~= '"';
        return mkStr(cast(dstring) o);
    }
    case Builtin.padLeft, Builtin.padRight:
    {
        auto s = a[0].str.s;
        const width = a[1].i;
        if (width < 0)
            throw panicMsg("negative count");
        if (s.length >= cast(ulong) width)
            return a[0];
        auto pad = new dchar[cast(size_t) width - s.length];
        pad[] = cast(dchar) a[2].i;
        return mkStr(id == Builtin.padLeft ? cast(dstring)(pad ~ s) : cast(dstring)(s ~ pad));
    }

    // ---- lists
    case Builtin.listNew:
        return Value.ofObj(Tag.list, new ListObj());
    case Builtin.listLen:
        return Value.ofInt(a[0].list.len);
    case Builtin.push:
        a[0].list.push(a[1]);
        return unit();
    case Builtin.pop:
        if (a[0].list.len == 0)
            throw panicMsg("empty list");
        return a[0].list.pop();
    case Builtin.insert:
    {
        auto l = a[0].list;
        if (a[1].i < 0 || cast(ulong) a[1].i > l.len)
            throw panicMsg("index out of bounds");
        l.insert(cast(size_t) a[1].i, a[2]);
        return unit();
    }
    case Builtin.removeAt:
    {
        auto l = a[0].list;
        checkIndex(a[1].i, l.len);
        return l.removeAt(cast(size_t) a[1].i);
    }
    case Builtin.clear:
        a[0].list.clear();
        return unit();
    case Builtin.listRepeat:
    {
        if (a[1].i < 0)
            throw panicMsg("negative count");
        auto items = new Value[cast(size_t) a[1].i];
        items[] = a[0];
        return Value.ofList(items);
    }
    case Builtin.listConcat:
        return Value.ofList(a[0].list.items ~ a[1].list.items);
    case Builtin.slice:
    {
        auto l = a[0].list;
        const from = a[1].i, to = a[2].i;
        if (from < 0 || from > to || cast(ulong) to > l.len)
            throw panicMsg("index out of bounds");
        return Value.ofList(l.items[cast(size_t) from .. cast(size_t) to].dup);
    }
    case Builtin.listCopy:
        return Value.ofList(a[0].list.items.dup);
    case Builtin.reverseList:
    {
        auto src = a[0].list.items;
        auto items = new Value[src.length];
        foreach (i, v; src)
            items[src.length - 1 - i] = v;
        return Value.ofList(items);
    }
    case Builtin.listFirst:
        if (a[0].list.len == 0)
            throw panicMsg("empty list");
        return a[0].list.buf[0];
    case Builtin.listLast:
        if (a[0].list.len == 0)
            throw panicMsg("empty list");
        return a[0].list.buf[a[0].list.len - 1];
    case Builtin.listMap:
    {
        auto l = a[0].list;
        auto f = a[1];
        auto res = new ListObj();
        for (size_t i = 0; i < l.len; i++)
            res.push(vm.call1(f, l.buf[i]));
        return Value.ofObj(Tag.list, res);
    }
    case Builtin.listFilter:
    {
        auto l = a[0].list;
        auto f = a[1];
        auto res = new ListObj();
        for (size_t i = 0; i < l.len; i++)
        {
            auto x = l.buf[i];
            if (vm.call1(f, x).i)
                res.push(x);
        }
        return Value.ofObj(Tag.list, res);
    }
    case Builtin.listFold:
    {
        auto l = a[0].list;
        auto acc = a[1];
        auto f = a[2];
        for (size_t i = 0; i < l.len; i++)
            acc = vm.call2(f, acc, l.buf[i]);
        return acc;
    }
    case Builtin.listAny:
    {
        auto l = a[0].list;
        for (size_t i = 0; i < l.len; i++)
            if (vm.call1(a[1], l.buf[i]).i)
                return Value.ofBool(true);
        return Value.ofBool(false);
    }
    case Builtin.listAll:
    {
        auto l = a[0].list;
        for (size_t i = 0; i < l.len; i++)
            if (!vm.call1(a[1], l.buf[i]).i)
                return Value.ofBool(false);
        return Value.ofBool(true);
    }
    case Builtin.listFind:
    {
        auto l = a[0].list;
        for (size_t i = 0; i < l.len; i++)
        {
            auto x = l.buf[i];
            if (vm.call1(a[1], x).i)
                return some(vm, x);
        }
        return none(vm);
    }
    case Builtin.listFindIndex:
    {
        auto l = a[0].list;
        for (size_t i = 0; i < l.len; i++)
            if (vm.call1(a[1], l.buf[i]).i)
                return Value.ofInt(cast(long) i);
        return Value.ofInt(-1);
    }
    case Builtin.listIndexOf, Builtin.listContains:
    {
        auto l = a[0].list;
        long found = -1;
        foreach (i; 0 .. l.len)
            if (valuesEqual(l.buf[i], a[1]))
            {
                found = cast(long) i;
                break;
            }
        return id == Builtin.listIndexOf ? Value.ofInt(found) : Value.ofBool(found >= 0);
    }
    case Builtin.listZip:
    {
        auto x = a[0].list, y = a[1].list;
        const n = x.len < y.len ? x.len : y.len;
        auto items = new Value[n];
        foreach (i; 0 .. n)
            items[i] = tuple2(x.buf[i], y.buf[i]);
        return Value.ofList(items);
    }
    case Builtin.listFlatten:
    {
        auto res = new ListObj();
        auto outer = a[0].list;
        foreach (i; 0 .. outer.len)
            foreach (v; outer.buf[i].list.items)
                res.push(v);
        return Value.ofObj(Tag.list, res);
    }
    case Builtin.sortBy:
        return sortList(vm, a[0], a[1]);

    // ---- maps
    case Builtin.mapNew:
        return Value.ofObj(Tag.map, new MapObj());
    case Builtin.mapLen:
        return Value.ofInt(a[0].map.length);
    case Builtin.mapHas:
        return Value.ofBool(a[0].map.find(a[1]) >= 0);
    case Builtin.mapGet:
    {
        auto p = a[0].map.get(a[1]);
        return p is null ? none(vm) : some(vm, *p);
    }
    case Builtin.mapGetOr:
    {
        auto p = a[0].map.get(a[1]);
        return p is null ? a[2] : *p;
    }
    case Builtin.mapSet:
        a[0].map.set(a[1], a[2]);
        return unit();
    case Builtin.mapDel:
        return Value.ofBool(a[0].map.remove(a[1]));
    case Builtin.keysOf:
    {
        auto res = new ListObj();
        foreach (ref k, ref v; a[0].map)
            res.push(k);
        return Value.ofObj(Tag.list, res);
    }
    case Builtin.valuesOf:
    {
        auto res = new ListObj();
        foreach (ref k, ref v; a[0].map)
            res.push(v);
        return Value.ofObj(Tag.list, res);
    }
    case Builtin.pairsOf:
    {
        auto res = new ListObj();
        foreach (ref k, ref v; a[0].map)
            res.push(tuple2(k, v));
        return Value.ofObj(Tag.list, res);
    }
    case Builtin.mapClear:
        a[0].map.clear();
        return unit();
    case Builtin.mapCopy:
    {
        auto res = new MapObj();
        foreach (ref k, ref v; a[0].map)
            res.set(k, v);
        return Value.ofObj(Tag.map, res);
    }

    // ---- Option, Result, tuples
    case Builtin.isSome:
        return Value.ofBool(a[0].agg.variant == someVariant);
    case Builtin.isNone:
        return Value.ofBool(a[0].agg.variant == noneVariant);
    case Builtin.unwrap:
        if (a[0].agg.variant != someVariant)
            throw panicMsg("unwrap of None");
        return a[0].agg.f[0];
    case Builtin.unwrapOr:
        return a[0].agg.variant == someVariant ? a[0].agg.f[0] : a[1];
    case Builtin.isOk:
        return Value.ofBool(a[0].agg.variant == okVariant);
    case Builtin.isErr:
        return Value.ofBool(a[0].agg.variant == errVariant);
    case Builtin.unwrapOk:
        if (a[0].agg.variant != okVariant)
            throw panicMsg("unwrap of Err");
        return a[0].agg.f[0];
    case Builtin.unwrapErr:
        if (a[0].agg.variant != errVariant)
            throw panicMsg("unwrap of Ok");
        return a[0].agg.f[0];
    case Builtin.fst:
        return a[0].agg.f[0];
    case Builtin.snd:
        return a[0].agg.f[1];

    // ---- formatting
    case Builtin.fmt:
        return formatTemplate(a[0].str.s, a[1].list);
    }
}

/// `cmpF`: -1, 0, 1 by IEEE comparison, NaN sorting last.
private int cmpFloats(double x, double y) @nogc nothrow
{
    const nx = x != x, ny = y != y;
    if (nx || ny)
        return nx && ny ? 0 : (nx ? 1 : -1);
    return x < y ? -1 : (x > y ? 1 : 0);
}

private double powFloat(double x, long n)
{
    if (n == long.min)
        throw panicMsg("negative exponent");
    if (n < 0)
        return 1.0 / powFloat(x, -n);
    double r = 1.0, b = x;
    long k = n;
    while (k > 0)
    {
        if ((k & 1) == 1)
            r = r * b;
        k = k >> 1;
        if (k > 0)
            b = b * b;
    }
    return r;
}

private Value formatTemplate(const(dchar)[] t, ListObj args)
{
    dchar[] r;
    size_t used = 0;
    size_t i = 0;
    while (i < t.length)
    {
        const c = t[i];
        if (c == '{')
        {
            if (i + 1 < t.length && t[i + 1] == '{')
            {
                r ~= '{';
                i += 2;
            }
            else if (i + 1 < t.length && t[i + 1] == '}')
            {
                if (used < args.len)
                    r ~= args.buf[used].str.s;
                used++;
                i += 2;
            }
            else
                throw panicMsg("bad format");
        }
        else if (c == '}')
        {
            if (i + 1 < t.length && t[i + 1] == '}')
            {
                r ~= '}';
                i += 2;
            }
            else
                throw panicMsg("bad format");
        }
        else
        {
            r ~= c;
            i++;
        }
    }
    if (used != args.len)
        throw panicMsg("bad format");
    return mkStr(cast(dstring) r);
}

/// `sortBy`: the bottom-up merge sort of SPEC.md section 15.6.
private Value sortList(VM vm, Value listV, Value cmp)
{
    auto l = listV.list;
    const n = l.len;
    Value[] src = l.items.dup;
    if (n <= 1)
        return Value.ofList(src);
    Value[] dst = new Value[n];
    for (size_t width = 1; width < n; width *= 2)
    {
        for (size_t i = 0; i < n; i += 2 * width)
        {
            const lo = i;
            const mid = i + width < n ? i + width : n;
            const hi = i + 2 * width < n ? i + 2 * width : n;
            size_t x = lo, y = mid, k = lo;
            while (x < mid && y < hi)
            {
                if (vm.call2(cmp, src[x], src[y]).i <= 0)
                    dst[k++] = src[x++];
                else
                    dst[k++] = src[y++];
            }
            while (x < mid)
                dst[k++] = src[x++];
            while (y < hi)
                dst[k++] = src[y++];
        }
        auto tmp = src;
        src = dst;
        dst = tmp;
    }
    return Value.ofList(src);
}
