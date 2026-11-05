/**
 * Rendering of types in the specified concrete syntax.
 */
module typeinfer.printer;

import std.array : Appender;
import typeinfer.types;

/// Syntactic position of a type being printed; decides parentheses.
private enum Ctx : ubyte
{
    top,       /// top level or right of an arrow
    arrowLeft, /// left of an arrow
    component, /// tuple component or list element
}

/**
 * Append the rendering of type `t` to `sink`.
 *
 * Type variables are named `'a`, `'b`, ... in order of first appearance,
 * numbering restarting at every call.
 */
void printType(TypeStore s, TypeId t, ref Appender!(char[]) sink)
{
    int next = 0;
    printRec(s, t, Ctx.top, s.newStamp(), next, sink);
}

/// Render type `t` as a string (convenience wrapper around `printType`).
string typeToString(TypeStore s, TypeId t)
{
    import std.array : appender;

    auto sink = appender!(char[]);
    printType(s, t, sink);
    return sink.data.idup;
}

private void putVarName(int index, ref Appender!(char[]) sink)
{
    sink.put('\'');
    sink.put(cast(char)('a' + index % 26));
    int q = index / 26;
    if (q != 0)
    {
        char[10] digits;
        size_t i = digits.length;
        while (q != 0)
        {
            digits[--i] = cast(char)('0' + q % 10);
            q /= 10;
        }
        sink.put(digits[i .. $]);
    }
}

private void printRec(TypeStore s, TypeId t, Ctx ctx, ulong stamp, ref int next,
        ref Appender!(char[]) sink)
{
    t = s.find(t);
    final switch (s.nodes[t].kind)
    {
    case NodeKind.variable:
        if (s.nodes[t].stamp != stamp)
        {
            s.nodes[t].stamp = stamp;
            s.nodes[t].memo = next++;
        }
        putVarName(s.nodes[t].memo, sink);
        return;
    case NodeKind.int_:
        sink.put("int");
        return;
    case NodeKind.bool_:
        sink.put("bool");
        return;
    case NodeKind.unit:
        sink.put("unit");
        return;
    case NodeKind.arrow:
    {
        immutable paren = ctx != Ctx.top;
        if (paren)
            sink.put('(');
        printRec(s, s.nodes[t].a, Ctx.arrowLeft, stamp, next, sink);
        sink.put(" -> ");
        printRec(s, s.nodes[t].b, Ctx.top, stamp, next, sink);
        if (paren)
            sink.put(')');
        return;
    }
    case NodeKind.list:
        printRec(s, s.nodes[t].a, Ctx.component, stamp, next, sink);
        sink.put(" list");
        return;
    case NodeKind.tuple:
    {
        immutable paren = ctx == Ctx.component;
        if (paren)
            sink.put('(');
        immutable n = s.nodes[t].b;
        foreach (i; 0 .. n)
        {
            if (i != 0)
                sink.put(" * ");
            printRec(s, s.pool[s.nodes[t].a + i], Ctx.component, stamp, next, sink);
        }
        if (paren)
            sink.put(')');
        return;
    }
    }
}
