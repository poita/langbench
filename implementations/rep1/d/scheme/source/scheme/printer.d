/**
 * Printing values in the `write` and `display` forms.
 */
module scheme.printer;

import scheme.numeric : integerToString;
import scheme.value;

/**
 * Print `v` to `sink` (anything with `put(const(char)[])`).
 *
 * In write form (`display == false`) strings are quoted and escaped; in
 * display form they are printed raw, at any depth.
 */
void printValue(Sink)(ref Sink sink, Value v, bool display)
{
    final switch (v.kind)
    {
    case Kind.nil:
        sink.put("()");
        break;
    case Kind.boolean:
        sink.put(v.i ? "#t" : "#f");
        break;
    case Kind.integer:
    case Kind.bigInteger:
        sink.put(integerToString(v));
        break;
    case Kind.string:
        if (display)
            sink.put(v.str.s);
        else
            putEscaped(sink, v.str.s);
        break;
    case Kind.symbol:
        sink.put(v.sym.name);
        break;
    case Kind.pair:
        sink.put("(");
        printValue(sink, v.pair.car, display);
        Value tail = v.pair.cdr;
        while (tail.kind == Kind.pair)
        {
            sink.put(" ");
            printValue(sink, tail.pair.car, display);
            tail = tail.pair.cdr;
        }
        if (tail.kind != Kind.nil)
        {
            sink.put(" . ");
            printValue(sink, tail, display);
        }
        sink.put(")");
        break;
    case Kind.closure:
    case Kind.primitive:
        sink.put("#<procedure>");
        break;
    case Kind.void_:
        sink.put("#<void>");
        break;
    }
}

private void putEscaped(Sink)(ref Sink sink, string s)
{
    sink.put("\"");
    size_t start = 0;
    foreach (i, c; s)
    {
        string rep;
        switch (c)
        {
        case '\\':
            rep = "\\\\";
            break;
        case '"':
            rep = "\\\"";
            break;
        case '\n':
            rep = "\\n";
            break;
        case '\t':
            rep = "\\t";
            break;
        default:
            continue;
        }
        sink.put(s[start .. i]);
        sink.put(rep);
        start = i + 1;
    }
    sink.put(s[start .. $]);
    sink.put("\"");
}

/// The `write` representation of `v` as a string.
string toWriteString(Value v)
{
    return render(v, false);
}

/// The `display` representation of `v` as a string.
string toDisplayString(Value v)
{
    return render(v, true);
}

private string render(Value v, bool display)
{
    import std.array : appender;

    auto app = appender!string();
    printValue(app, v, display);
    return app[];
}

unittest
{
    auto syms = new SymbolTable;
    auto list = Value.cons(Value.fromInt(1), Value.cons(Value.fromString("a\"b\n"), Value.fromInt(3)));
    assert(toWriteString(list) == `(1 "a\"b\n" . 3)`);
    assert(toDisplayString(list) == "(1 a\"b\n . 3)");
    assert(toWriteString(Value.void_()) == "#<void>");
    assert(toWriteString(Value.fromBool(false)) == "#f");
    assert(toWriteString(Value.nil()) == "()");
    assert(toWriteString(Value.fromSymbol(syms.intern("foo"))) == "foo");
    assert(toWriteString(Value.fromString("t\tx\\")) == `"t\tx\\"`);
}
