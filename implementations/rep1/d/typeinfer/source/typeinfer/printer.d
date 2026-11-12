/**
 * Rendering types as text.
 *
 * Variables are named in order of first appearance, reading left to right:
 * `'a`, `'b`, ..., `'z`, `'a1`, `'b1`, ...
 */
module typeinfer.printer;

import std.array : Appender, appender;
import typeinfer.types;

/// Renders `t` in the concrete syntax of the specification, naming its variables from `'a`.
string typeToString(Type t) @safe 
{
    auto p = Printer();
    p.out_ = appender!string();
    p.put(t, Ctx.top);
    return p.out_[];
}

/// The name of the `i`-th (from 0) distinct type variable: `'a` .. `'z`, `'a1`, `'b1`, ...
string varName(size_t i) @safe nothrow
{
    char[24] buf;
    size_t n = 0;
    buf[n++] = '\'';
    buf[n++] = cast(char)('a' + i % 26);
    size_t k = i / 26;
    if (k)
    {
        char[20] digits;
        size_t d = digits.length;
        while (k) { digits[--d] = cast(char)('0' + k % 10); k /= 10; }
        buf[n .. n + digits.length - d] = digits[d .. $];
        n += digits.length - d;
    }
    return buf[0 .. n].idup;
}

private enum Ctx : ubyte { top, funLeft, tupleElem, listElem }

private struct Printer
{
    Appender!string out_;
    size_t[Type] names;

    void put(Type t, Ctx ctx) @safe 
    {
        t = prune(t);
        final switch (t.kind)
        {
            case Kind.int_: out_ ~= "int"; break;
            case Kind.bool_: out_ ~= "bool"; break;
            case Kind.unit: out_ ~= "unit"; break;
            case Kind.var:
            {
                auto p = t in names;
                size_t i;
                if (p is null) { i = names.length; names[t] = i; }
                else i = *p;
                out_ ~= varName(i);
                break;
            }
            case Kind.fun:
            {
                immutable paren = ctx != Ctx.top;
                if (paren) out_ ~= '(';
                put(t.args[0], Ctx.funLeft);
                out_ ~= " -> ";
                put(t.args[1], Ctx.top);
                if (paren) out_ ~= ')';
                break;
            }
            case Kind.tuple:
            {
                immutable paren = ctx == Ctx.tupleElem || ctx == Ctx.listElem;
                if (paren) out_ ~= '(';
                foreach (i, c; t.args)
                {
                    if (i) out_ ~= " * ";
                    put(c, Ctx.tupleElem);
                }
                if (paren) out_ ~= ')';
                break;
            }
            case Kind.list:
                put(t.args[0], Ctx.listElem);
                out_ ~= " list";
                break;
        }
    }
}

@safe unittest
{
    assert(varName(0) == "'a" && varName(25) == "'z");
    assert(varName(26) == "'a1" && varName(27) == "'b1" && varName(52) == "'a2");
    assert(varName(26 * 315 + 2) == "'c315");
}

@safe unittest
{
    auto a = Type.newVar(0), b = Type.newVar(0);
    alias I = Type.int_;
    assert(typeToString(Type.fun(Type.fun(a, b), Type.list(a))) == "('a -> 'b) -> 'a list");
    assert(typeToString(Type.fun(a, Type.fun(b, a))) == "'a -> 'b -> 'a");
    assert(typeToString(Type.tuple([Type.fun(I, I), Type.tuple([I, I]), I]))
            == "(int -> int) * (int * int) * int");
    assert(typeToString(Type.fun(Type.tuple([a, b]), Type.tuple([b, a]))) == "'a * 'b -> 'b * 'a");
    assert(typeToString(Type.list(Type.list(I))) == "int list list");
    assert(typeToString(Type.list(Type.tuple([I, Type.bool_]))) == "(int * bool) list");
    assert(typeToString(Type.list(Type.fun(a, a))) == "('a -> 'a) list");
    assert(typeToString(Type.tuple([Type.list(I), Type.unit])) == "int list * unit");
}
