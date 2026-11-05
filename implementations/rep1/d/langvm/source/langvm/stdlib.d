/// The built-in standard library (section 15 of the language specification).
module langvm.stdlib;

import core.bitop : bsf, bsr, popcnt;
import core.stdc.math : ceil, floor, fmod, round, sqrt, trunc;
import langvm.diag;
import langvm.numfmt;
import langvm.value;
import langvm.vm;
import std.utf : toUTF32, toUTF8;

private Value mkStr(dstring s)
{
    return Value.str(s);
}

private Value mkList(Value[] items)
{
    return Value.obj(VT.list, new ListObj(items));
}

private Value mkInt(long v)
{
    return Value.int_(v);
}

private Value mkBool(bool v)
{
    return Value.bool_(v);
}

private Value some(Value v)
{
    return Value.obj(VT.enum_, new AggObj(0, 0, [v]));
}

private Value none(VM vm)
{
    return vm.prog.unitVariants[0][1];
}

private Value okV(Value v)
{
    return Value.obj(VT.enum_, new AggObj(1, 0, [v]));
}

private Value errV(Value v)
{
    return Value.obj(VT.enum_, new AggObj(1, 1, [v]));
}

private dstring S(in Value v)
{
    return asStr(v).s;
}

private bool isSpaceC(dchar c) pure nothrow @nogc
{
    return c == 9 || c == 10 || c == 11 || c == 12 || c == 13 || c == 32;
}

private int cmp3(long a, long b) pure nothrow @nogc
{
    return a < b ? -1 : (a > b ? 1 : 0);
}

private int cmpFloat(double a, double b) pure nothrow @nogc
{
    bool an = a != a;
    bool bn = b != b;
    if (an || bn)
        return an && bn ? 0 : (an ? 1 : -1);
    return a < b ? -1 : (a > b ? 1 : 0);
}

private void escapeInto(ref dchar[] out_, dchar c, dchar quote)
{
    if (c == '\\')
        out_ ~= "\\\\"d;
    else if (c == quote)
    {
        out_ ~= '\\';
        out_ ~= c;
    }
    else if (c == '\n')
        out_ ~= "\\n"d;
    else if (c == '\r')
        out_ ~= "\\r"d;
    else if (c == '\t')
        out_ ~= "\\t"d;
    else if (c < 0x20 || c == 0x7F)
    {
        out_ ~= "\\u{"d;
        out_ ~= toUTF32(formatIntRadix(c, 16));
        out_ ~= '}';
    }
    else
        out_ ~= c;
}

private long checkIndex(long i, size_t len)
{
    if (cast(ulong) i >= len)
        panic("index out of bounds");
    return i;
}

private int indexOfSub(dstring s, dstring sub, size_t from = 0)
{
    if (sub.length == 0)
        return cast(int) from;
    if (sub.length > s.length)
        return -1;
    size_t last = s.length - sub.length;
    dchar first = sub[0];
    for (size_t i = from; i <= last; i++)
    {
        if (s[i] != first)
            continue;
        bool ok = true;
        foreach (k; 1 .. sub.length)
            if (s[i + k] != sub[k])
            {
                ok = false;
                break;
            }
        if (ok)
            return cast(int) i;
    }
    return -1;
}

private bool matchAt(dstring s, size_t i, dstring sub)
{
    if (i + sub.length > s.length)
        return false;
    foreach (k; 0 .. sub.length)
        if (s[i + k] != sub[k])
            return false;
    return true;
}

private double powFloat(double x, long n)
{
    if (n == long.min)
        panic("negative exponent");
    bool neg = n < 0;
    ulong k = neg ? cast(ulong)(-n) : cast(ulong) n;
    double r = 1.0;
    double b = x;
    while (k > 0)
    {
        if (k & 1)
            r = r * b;
        k >>= 1;
        if (k > 0)
            b = b * b;
    }
    return neg ? 1.0 / r : r;
}

private Value[] sortValues(VM vm, Value[] input, Value cmp)
{
    size_t n = input.length;
    auto src = input.dup;
    if (n <= 1)
        return src;
    auto dst = new Value[n];
    size_t width = 1;
    Value[2] args = void;
    while (width < n)
    {
        size_t i = 0;
        while (i < n)
        {
            size_t lo = i;
            size_t mid = i + width < n ? i + width : n;
            size_t hi = i + 2 * width < n ? i + 2 * width : n;
            size_t a = lo, b = mid, k = lo;
            while (a < mid && b < hi)
            {
                args[0] = src[a];
                args[1] = src[b];
                if (vm.callClosure(cmp, args[]).i <= 0)
                    dst[k++] = src[a++];
                else
                    dst[k++] = src[b++];
            }
            while (a < mid)
                dst[k++] = src[a++];
            while (b < hi)
                dst[k++] = src[b++];
            i += 2 * width;
        }
        auto t = src;
        src = dst;
        dst = t;
        width *= 2;
    }
    return src;
}

private dstring doFmt(dstring t, ListObj args)
{
    dchar[] r;
    size_t used = 0;
    size_t i = 0;
    while (i < t.length)
    {
        dchar c = t[i];
        if (c == '{')
        {
            if (i + 1 >= t.length)
                panic("bad format");
            if (t[i + 1] == '{')
            {
                r ~= '{';
                i += 2;
            }
            else if (t[i + 1] == '}')
            {
                if (used < args.len)
                    r ~= S(args.buf[used]);
                used++;
                i += 2;
            }
            else
                panic("bad format");
        }
        else if (c == '}')
        {
            if (i + 1 < t.length && t[i + 1] == '}')
            {
                r ~= '}';
                i += 2;
            }
            else
                panic("bad format");
        }
        else
        {
            r ~= c;
            i++;
        }
    }
    if (used != args.len)
        panic("bad format");
    return cast(dstring) r;
}

/// Returns the table of built-in implementations keyed by name.
BuiltinFn[string] builtinImplementations()
{
    BuiltinFn[string] t;
    // ---- output and panicking
    t["print"] = (vm, a) { vm.write(S(a[0])); vm.writeText("\n"); return Value.unit; };
    t["emit"] = (vm, a) { vm.write(S(a[0])); return Value.unit; };
    t["panic"] = (vm, a) { panic(toUTF8(S(a[0]))); return Value.unit; };
    // ---- integers
    t["intMin"] = (vm, a) => mkInt(long.min);
    t["intMax"] = (vm, a) => mkInt(long.max);
    t["absI"] = (vm, a) => mkInt(a[0].i < 0 ? cast(long)(0UL - cast(ulong) a[0].i) : a[0].i);
    t["minI"] = (vm, a) => mkInt(a[0].i < a[1].i ? a[0].i : a[1].i);
    t["maxI"] = (vm, a) => mkInt(a[0].i > a[1].i ? a[0].i : a[1].i);
    t["signI"] = (vm, a) => mkInt(a[0].i < 0 ? -1 : (a[0].i > 0 ? 1 : 0));
    t["cmpI"] = (vm, a) => mkInt(cmp3(a[0].i, a[1].i));
    t["divFloor"] = (vm, a) {
        long x = a[0].i, y = a[1].i;
        if (y == 0)
            panic("divide by zero");
        if (y == -1)
            return mkInt(cast(long)(0UL - cast(ulong) x));
        long q = x / y;
        if (x % y != 0 && ((x < 0) != (y < 0)))
            q--;
        return mkInt(q);
    };
    t["modFloor"] = (vm, a) {
        long x = a[0].i, y = a[1].i;
        if (y == 0)
            panic("modulo by zero");
        if (y == -1)
            return mkInt(0);
        long r = x % y;
        if (r != 0 && ((r < 0) != (y < 0)))
            r += y;
        return mkInt(r);
    };
    t["powI"] = (vm, a) {
        long e = a[1].i;
        if (e < 0)
            panic("negative exponent");
        ulong r = 1, b = cast(ulong) a[0].i;
        ulong k = cast(ulong) e;
        while (k > 0)
        {
            if (k & 1)
                r *= b;
            b *= b;
            k >>= 1;
        }
        return mkInt(cast(long) r);
    };
    t["gcdI"] = (vm, a) {
        ulong x = a[0].i < 0 ? 0UL - cast(ulong) a[0].i : cast(ulong) a[0].i;
        ulong y = a[1].i < 0 ? 0UL - cast(ulong) a[1].i : cast(ulong) a[1].i;
        while (y != 0)
        {
            ulong tmp = x % y;
            x = y;
            y = tmp;
        }
        return mkInt(cast(long) x);
    };
    t["popCount"] = (vm, a) => mkInt(popcnt(cast(ulong) a[0].i));
    t["clz"] = (vm, a) => mkInt(a[0].i == 0 ? 64 : 63 - bsr(cast(ulong) a[0].i));
    t["ctz"] = (vm, a) => mkInt(a[0].i == 0 ? 64 : bsf(cast(ulong) a[0].i));
    t["toFloat"] = (vm, a) => Value.float_(cast(double) a[0].i);
    t["showInt"] = (vm, a) => mkStr(toUTF32(formatIntRadix(a[0].i, 10)));
    t["showIntRadix"] = (vm, a) {
        if (a[1].i < 2 || a[1].i > 36)
            panic("radix out of range");
        return mkStr(toUTF32(formatIntRadix(a[0].i, cast(int) a[1].i)));
    };
    t["parseInt"] = (vm, a) {
        long v;
        if (parseIntRadix(S(a[0]), 10, v))
            return some(mkInt(v));
        return none(vm);
    };
    t["parseIntRadix"] = (vm, a) {
        if (a[1].i < 2 || a[1].i > 36)
            panic("radix out of range");
        long v;
        if (parseIntRadix(S(a[0]), cast(int) a[1].i, v))
            return some(mkInt(v));
        return none(vm);
    };
    // ---- floats
    t["sqrtF"] = (vm, a) => Value.float_(sqrt(a[0].f));
    t["absF"] = (vm, a) {
        ulong bits = *cast(ulong*)&a[0].f & 0x7FFFFFFFFFFFFFFFUL;
        return Value.float_(*cast(double*)&bits);
    };
    t["floorF"] = (vm, a) => Value.float_(floor(a[0].f));
    t["ceilF"] = (vm, a) => Value.float_(ceil(a[0].f));
    t["truncF"] = (vm, a) => Value.float_(trunc(a[0].f));
    t["roundF"] = (vm, a) => Value.float_(round(a[0].f));
    t["minF"] = (vm, a) => cmpFloat(a[0].f, a[1].f) <= 0 ? a[0] : a[1];
    t["maxF"] = (vm, a) => cmpFloat(a[0].f, a[1].f) >= 0 ? a[0] : a[1];
    t["fmodF"] = (vm, a) => Value.float_(fmod(a[0].f, a[1].f));
    t["powF"] = (vm, a) => Value.float_(powFloat(a[0].f, a[1].i));
    t["isNanF"] = (vm, a) => mkBool(a[0].f != a[0].f);
    t["isInfF"] = (vm, a) => mkBool(a[0].f == double.infinity || a[0].f == -double.infinity);
    t["cmpF"] = (vm, a) => mkInt(cmpFloat(a[0].f, a[1].f));
    t["truncToInt"] = (vm, a) {
        double x = trunc(a[0].f);
        if (!(x >= -9223372036854775808.0 && x < 9223372036854775808.0))
            panic("float out of integer range");
        return mkInt(cast(long) x);
    };
    t["showFloat"] = (vm, a) => mkStr(toUTF32(formatFloatAt(a[0].f, 6)));
    t["showFloatAt"] = (vm, a) {
        if (a[1].i < 0 || a[1].i > 17)
            panic("digits out of range");
        return mkStr(toUTF32(formatFloatAt(a[0].f, cast(int) a[1].i)));
    };
    t["floatBits"] = (vm, a) => mkInt(*cast(long*)&a[0].f);
    t["floatFromBits"] = (vm, a) => Value.float_(*cast(double*)&a[0].i);
    t["parseFloat"] = (vm, a) {
        double d;
        if (parseFloatText(S(a[0]), d))
            return some(Value.float_(d));
        return none(vm);
    };
    t["infF"] = (vm, a) => Value.float_(double.infinity);
    t["nanF"] = (vm, a) {
        ulong bits = 0x7ff8000000000000UL;
        return Value.float_(*cast(double*)&bits);
    };
    t["piF"] = (vm, a) {
        long bits = 4614256656552045848L;
        return Value.float_(*cast(double*)&bits);
    };
    // ---- bools and chars
    t["showBool"] = (vm, a) => mkStr(a[0].i ? "true"d : "false"d);
    t["ord"] = (vm, a) => mkInt(a[0].i);
    t["chr"] = (vm, a) {
        long n = a[0].i;
        if (n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF))
            panic("invalid char code");
        return Value.char_(cast(dchar) n);
    };
    t["isDigit"] = (vm, a) => mkBool(a[0].i >= '0' && a[0].i <= '9');
    t["isAlpha"] = (vm, a) => mkBool((a[0].i >= 'a' && a[0].i <= 'z') || (a[0].i >= 'A' && a[0].i <= 'Z'));
    t["isAlnum"] = (vm, a) => mkBool((a[0].i >= 'a' && a[0].i <= 'z') || (a[0].i >= 'A' && a[0].i <= 'Z')
            || (a[0].i >= '0' && a[0].i <= '9'));
    t["isSpace"] = (vm, a) => mkBool(isSpaceC(cast(dchar) a[0].i));
    t["isUpper"] = (vm, a) => mkBool(a[0].i >= 'A' && a[0].i <= 'Z');
    t["isLower"] = (vm, a) => mkBool(a[0].i >= 'a' && a[0].i <= 'z');
    t["toUpperC"] = (vm, a) => Value.char_(a[0].i >= 'a' && a[0].i <= 'z' ? cast(dchar)(a[0].i - 32) : cast(dchar) a[0].i);
    t["toLowerC"] = (vm, a) => Value.char_(a[0].i >= 'A' && a[0].i <= 'Z' ? cast(dchar)(a[0].i + 32) : cast(dchar) a[0].i);
    t["cmpC"] = (vm, a) => mkInt(cmp3(a[0].i, a[1].i));
    t["showChar"] = (vm, a) => mkStr([cast(dchar) a[0].i].idup);
    t["quoteChar"] = (vm, a) {
        dchar[] r = ['\''];
        escapeInto(r, cast(dchar) a[0].i, '\'');
        r ~= '\'';
        return mkStr(cast(dstring) r);
    };
    // ---- strings
    t["strLen"] = (vm, a) => mkInt(S(a[0]).length);
    t["charAt"] = (vm, a) {
        auto s = S(a[0]);
        return Value.char_(s[checkIndex(a[1].i, s.length)]);
    };
    t["substr"] = (vm, a) {
        auto s = S(a[0]);
        long f = a[1].i, e = a[2].i;
        if (f < 0 || f > e || e > cast(long) s.length)
            panic("index out of bounds");
        return mkStr(s[f .. e]);
    };
    t["strCat"] = (vm, a) => mkStr(S(a[0]) ~ S(a[1]));
    t["strRepeat"] = (vm, a) {
        if (a[1].i < 0)
            panic("negative count");
        auto s = S(a[0]);
        dchar[] r;
        r.reserve(s.length * a[1].i);
        foreach (_; 0 .. a[1].i)
            r ~= s;
        return mkStr(cast(dstring) r);
    };
    t["strIndexOf"] = (vm, a) => mkInt(indexOfSub(S(a[0]), S(a[1])));
    t["strLastIndexOf"] = (vm, a) {
        auto s = S(a[0]);
        auto sub = S(a[1]);
        if (sub.length > s.length)
            return mkInt(-1);
        for (long i = cast(long)(s.length - sub.length); i >= 0; i--)
            if (matchAt(s, i, sub))
                return mkInt(i);
        return mkInt(-1);
    };
    t["strContains"] = (vm, a) => mkBool(indexOfSub(S(a[0]), S(a[1])) >= 0);
    t["startsWith"] = (vm, a) => mkBool(matchAt(S(a[0]), 0, S(a[1])));
    t["endsWith"] = (vm, a) {
        auto s = S(a[0]);
        auto p = S(a[1]);
        return mkBool(p.length <= s.length && matchAt(s, s.length - p.length, p));
    };
    t["strSplit"] = (vm, a) {
        auto s = S(a[0]);
        auto sep = S(a[1]);
        if (sep.length == 0)
            panic("empty separator");
        Value[] parts;
        size_t start = 0;
        size_t i = 0;
        while (i + sep.length <= s.length)
        {
            if (matchAt(s, i, sep))
            {
                parts ~= mkStr(s[start .. i]);
                i += sep.length;
                start = i;
            }
            else
                i++;
        }
        parts ~= mkStr(s[start .. $]);
        return mkList(parts);
    };
    t["strJoin"] = (vm, a) {
        auto l = asList(a[0]);
        auto sep = S(a[1]);
        dchar[] r;
        foreach (i; 0 .. l.len)
        {
            if (i > 0)
                r ~= sep;
            r ~= S(l.buf[i]);
        }
        return mkStr(cast(dstring) r);
    };
    t["strReplace"] = (vm, a) {
        auto s = S(a[0]);
        auto from = S(a[1]);
        auto to = S(a[2]);
        if (from.length == 0)
            panic("empty separator");
        dchar[] r;
        size_t i = 0;
        while (i < s.length)
        {
            if (matchAt(s, i, from))
            {
                r ~= to;
                i += from.length;
            }
            else
                r ~= s[i++];
        }
        return mkStr(cast(dstring) r);
    };
    t["trim"] = (vm, a) {
        auto s = S(a[0]);
        size_t b = 0, e = s.length;
        while (b < e && isSpaceC(s[b]))
            b++;
        while (e > b && isSpaceC(s[e - 1]))
            e--;
        return mkStr(s[b .. e]);
    };
    t["trimLeft"] = (vm, a) {
        auto s = S(a[0]);
        size_t b = 0;
        while (b < s.length && isSpaceC(s[b]))
            b++;
        return mkStr(s[b .. $]);
    };
    t["trimRight"] = (vm, a) {
        auto s = S(a[0]);
        size_t e = s.length;
        while (e > 0 && isSpaceC(s[e - 1]))
            e--;
        return mkStr(s[0 .. e]);
    };
    t["upper"] = (vm, a) {
        auto s = S(a[0]).dup;
        foreach (ref c; s)
            if (c >= 'a' && c <= 'z')
                c -= 32;
        return mkStr(cast(dstring) s);
    };
    t["lower"] = (vm, a) {
        auto s = S(a[0]).dup;
        foreach (ref c; s)
            if (c >= 'A' && c <= 'Z')
                c += 32;
        return mkStr(cast(dstring) s);
    };
    t["strCmp"] = (vm, a) => mkInt(compareStr(S(a[0]), S(a[1])));
    t["chars"] = (vm, a) {
        auto s = S(a[0]);
        auto items = new Value[s.length];
        foreach (i, c; s)
            items[i] = Value.char_(c);
        return mkList(items);
    };
    t["strOfChars"] = (vm, a) {
        auto l = asList(a[0]);
        auto r = new dchar[l.len];
        foreach (i; 0 .. l.len)
            r[i] = cast(dchar) l.buf[i].i;
        return mkStr(cast(dstring) r);
    };
    t["strReverse"] = (vm, a) {
        auto s = S(a[0]);
        auto r = new dchar[s.length];
        foreach (i, c; s)
            r[s.length - 1 - i] = c;
        return mkStr(cast(dstring) r);
    };
    t["quoteStr"] = (vm, a) {
        dchar[] r = ['"'];
        foreach (c; S(a[0]))
            escapeInto(r, c, '"');
        r ~= '"';
        return mkStr(cast(dstring) r);
    };
    t["padLeft"] = (vm, a) {
        if (a[1].i < 0)
            panic("negative count");
        auto s = S(a[0]);
        if (cast(long) s.length >= a[1].i)
            return a[0];
        auto r = new dchar[a[1].i];
        size_t pad = a[1].i - s.length;
        r[0 .. pad] = cast(dchar) a[2].i;
        r[pad .. $] = s[];
        return mkStr(cast(dstring) r);
    };
    t["padRight"] = (vm, a) {
        if (a[1].i < 0)
            panic("negative count");
        auto s = S(a[0]);
        if (cast(long) s.length >= a[1].i)
            return a[0];
        auto r = new dchar[a[1].i];
        r[0 .. s.length] = s[];
        r[s.length .. $] = cast(dchar) a[2].i;
        return mkStr(cast(dstring) r);
    };
    // ---- lists
    t["listNew"] = (vm, a) => Value.obj(VT.list, new ListObj);
    t["listLen"] = (vm, a) => mkInt(asList(a[0]).len);
    t["push"] = (vm, a) { asList(a[0]).push(a[1]); return Value.unit; };
    t["pop"] = (vm, a) {
        auto l = asList(a[0]);
        if (l.len == 0)
            panic("empty list");
        return l.pop();
    };
    t["insert"] = (vm, a) {
        auto l = asList(a[0]);
        long i = a[1].i;
        if (i < 0 || i > cast(long) l.len)
            panic("index out of bounds");
        l.insertAt(i, a[2]);
        return Value.unit;
    };
    t["removeAt"] = (vm, a) {
        auto l = asList(a[0]);
        return l.removeAt(checkIndex(a[1].i, l.len));
    };
    t["clear"] = (vm, a) { asList(a[0]).clear(); return Value.unit; };
    t["listRepeat"] = (vm, a) {
        if (a[1].i < 0)
            panic("negative count");
        auto items = new Value[a[1].i];
        items[] = a[0];
        return mkList(items);
    };
    t["listConcat"] = (vm, a) {
        auto x = asList(a[0]);
        auto y = asList(a[1]);
        auto items = new Value[x.len + y.len];
        items[0 .. x.len] = x.buf[0 .. x.len];
        items[x.len .. $] = y.buf[0 .. y.len];
        return mkList(items);
    };
    t["slice"] = (vm, a) {
        auto l = asList(a[0]);
        long f = a[1].i, e = a[2].i;
        if (f < 0 || f > e || e > cast(long) l.len)
            panic("index out of bounds");
        return mkList(l.buf[f .. e].dup);
    };
    t["listCopy"] = (vm, a) => mkList(asList(a[0]).items.dup);
    t["reverseList"] = (vm, a) {
        auto l = asList(a[0]);
        auto items = new Value[l.len];
        foreach (i; 0 .. l.len)
            items[l.len - 1 - i] = l.buf[i];
        return mkList(items);
    };
    t["listFirst"] = (vm, a) {
        auto l = asList(a[0]);
        if (l.len == 0)
            panic("empty list");
        return l.buf[0];
    };
    t["listLast"] = (vm, a) {
        auto l = asList(a[0]);
        if (l.len == 0)
            panic("empty list");
        return l.buf[l.len - 1];
    };
    t["listMap"] = (vm, a) {
        auto l = asList(a[0]);
        auto r = new ListObj;
        Value[1] arg = void;
        for (size_t i = 0; i < l.len; i++)
        {
            arg[0] = l.buf[i];
            r.push(vm.callClosure(a[1], arg[]));
        }
        return Value.obj(VT.list, r);
    };
    t["listFilter"] = (vm, a) {
        auto l = asList(a[0]);
        auto r = new ListObj;
        Value[1] arg = void;
        for (size_t i = 0; i < l.len; i++)
        {
            arg[0] = l.buf[i];
            if (vm.callClosure(a[1], arg[]).i != 0)
                r.push(arg[0]);
        }
        return Value.obj(VT.list, r);
    };
    t["listFold"] = (vm, a) {
        auto l = asList(a[0]);
        Value acc = a[1];
        Value[2] arg = void;
        for (size_t i = 0; i < l.len; i++)
        {
            arg[0] = acc;
            arg[1] = l.buf[i];
            acc = vm.callClosure(a[2], arg[]);
        }
        return acc;
    };
    t["listAny"] = (vm, a) {
        auto l = asList(a[0]);
        Value[1] arg = void;
        for (size_t i = 0; i < l.len; i++)
        {
            arg[0] = l.buf[i];
            if (vm.callClosure(a[1], arg[]).i != 0)
                return mkBool(true);
        }
        return mkBool(false);
    };
    t["listAll"] = (vm, a) {
        auto l = asList(a[0]);
        Value[1] arg = void;
        for (size_t i = 0; i < l.len; i++)
        {
            arg[0] = l.buf[i];
            if (vm.callClosure(a[1], arg[]).i == 0)
                return mkBool(false);
        }
        return mkBool(true);
    };
    t["listFind"] = (vm, a) {
        auto l = asList(a[0]);
        Value[1] arg = void;
        for (size_t i = 0; i < l.len; i++)
        {
            arg[0] = l.buf[i];
            if (vm.callClosure(a[1], arg[]).i != 0)
                return some(arg[0]);
        }
        return none(vm);
    };
    t["listFindIndex"] = (vm, a) {
        auto l = asList(a[0]);
        Value[1] arg = void;
        for (size_t i = 0; i < l.len; i++)
        {
            arg[0] = l.buf[i];
            if (vm.callClosure(a[1], arg[]).i != 0)
                return mkInt(i);
        }
        return mkInt(-1);
    };
    t["listIndexOf"] = (vm, a) {
        auto l = asList(a[0]);
        for (size_t i = 0; i < l.len; i++)
            if (valuesEqual(l.buf[i], a[1]))
                return mkInt(i);
        return mkInt(-1);
    };
    t["listContains"] = (vm, a) {
        auto l = asList(a[0]);
        for (size_t i = 0; i < l.len; i++)
            if (valuesEqual(l.buf[i], a[1]))
                return mkBool(true);
        return mkBool(false);
    };
    t["listZip"] = (vm, a) {
        auto x = asList(a[0]);
        auto y = asList(a[1]);
        size_t n = x.len < y.len ? x.len : y.len;
        auto items = new Value[n];
        foreach (i; 0 .. n)
            items[i] = Value.obj(VT.tuple, new AggObj(-1, 0, [x.buf[i], y.buf[i]]));
        return mkList(items);
    };
    t["listFlatten"] = (vm, a) {
        auto l = asList(a[0]);
        auto r = new ListObj;
        foreach (i; 0 .. l.len)
        {
            auto inner = asList(l.buf[i]);
            foreach (j; 0 .. inner.len)
                r.push(inner.buf[j]);
        }
        return Value.obj(VT.list, r);
    };
    t["sortBy"] = (vm, a) => mkList(sortValues(vm, asList(a[0]).items, a[1]));
    // ---- maps
    t["mapNew"] = (vm, a) => Value.obj(VT.map, new MapObj);
    t["mapLen"] = (vm, a) => mkInt(asMap(a[0]).count);
    t["mapHas"] = (vm, a) => mkBool(asMap(a[0]).find(a[1]) >= 0);
    t["mapGet"] = (vm, a) {
        auto m = asMap(a[0]);
        int e = m.find(a[1]);
        return e >= 0 ? some(m.vals[e]) : none(vm);
    };
    t["mapGetOr"] = (vm, a) {
        auto m = asMap(a[0]);
        int e = m.find(a[1]);
        return e >= 0 ? m.vals[e] : a[2];
    };
    t["mapSet"] = (vm, a) { asMap(a[0]).set(a[1], a[2]); return Value.unit; };
    t["mapDel"] = (vm, a) => mkBool(asMap(a[0]).remove(a[1]));
    t["keysOf"] = (vm, a) {
        auto m = asMap(a[0]);
        auto items = new Value[m.count];
        size_t k = 0;
        foreach (i; 0 .. m.used)
            if (m.keys[i].t != VT.unit)
                items[k++] = m.keys[i];
        return mkList(items);
    };
    t["valuesOf"] = (vm, a) {
        auto m = asMap(a[0]);
        auto items = new Value[m.count];
        size_t k = 0;
        foreach (i; 0 .. m.used)
            if (m.keys[i].t != VT.unit)
                items[k++] = m.vals[i];
        return mkList(items);
    };
    t["pairsOf"] = (vm, a) {
        auto m = asMap(a[0]);
        auto items = new Value[m.count];
        size_t k = 0;
        foreach (i; 0 .. m.used)
            if (m.keys[i].t != VT.unit)
                items[k++] = Value.obj(VT.tuple, new AggObj(-1, 0, [m.keys[i], m.vals[i]]));
        return mkList(items);
    };
    t["mapClear"] = (vm, a) { asMap(a[0]).clear(); return Value.unit; };
    t["mapCopy"] = (vm, a) => Value.obj(VT.map, asMap(a[0]).copy());
    // ---- option, result, tuples
    t["isSome"] = (vm, a) => mkBool(asAgg(a[0]).variant == 0);
    t["isNone"] = (vm, a) => mkBool(asAgg(a[0]).variant == 1);
    t["unwrap"] = (vm, a) {
        auto o = asAgg(a[0]);
        if (o.variant != 0)
            panic("unwrap of None");
        return o.f[0];
    };
    t["unwrapOr"] = (vm, a) {
        auto o = asAgg(a[0]);
        return o.variant == 0 ? o.f[0] : a[1];
    };
    t["isOk"] = (vm, a) => mkBool(asAgg(a[0]).variant == 0);
    t["isErr"] = (vm, a) => mkBool(asAgg(a[0]).variant == 1);
    t["unwrapOk"] = (vm, a) {
        auto o = asAgg(a[0]);
        if (o.variant != 0)
            panic("unwrap of Err");
        return o.f[0];
    };
    t["unwrapErr"] = (vm, a) {
        auto o = asAgg(a[0]);
        if (o.variant != 1)
            panic("unwrap of Ok");
        return o.f[0];
    };
    t["fst"] = (vm, a) => asAgg(a[0]).f[0];
    t["snd"] = (vm, a) => asAgg(a[0]).f[1];
    // ---- formatting
    t["fmt"] = (vm, a) => mkStr(doFmt(S(a[0]), asList(a[1])));
    return t;
}
