/// Converting values to their `write` and `display` text.
module scheme.printer;

import scheme.numeric : toDecimal;
import scheme.output;
import scheme.symbols;
import scheme.value;

/// Append the printed form of `v` to `o`. Strings are quoted and escaped
/// unless `display` is true. Lists are walked iteratively along the cdr.
void print(Output o, const SymbolTable syms, Value v, bool display)
{
    final switch (v.tag)
    {
    case Tag.unbound:
        o.put("#<unbound>");
        break;
    case Tag.fixnum:
    case Tag.big:
        o.put(toDecimal(v));
        break;
    case Tag.boolean:
        o.put(v.i ? "#t" : "#f");
        break;
    case Tag.nil:
        o.put("()");
        break;
    case Tag.voidValue:
        o.put("#<void>");
        break;
    case Tag.symbol:
        o.put(syms.name(cast(int) v.i));
        break;
    case Tag.prim:
    case Tag.closure:
        o.put("#<procedure>");
        break;
    case Tag.str:
        if (display)
            o.put(v.strObj.s);
        else
            writeString(o, v.strObj.s);
        break;
    case Tag.pair:
        o.put('(');
        for (;;)
        {
            auto pr = v.pair;
            print(o, syms, pr.car, display);
            v = pr.cdr;
            if (v.tag == Tag.pair)
                o.put(' ');
            else if (v.tag == Tag.nil)
                break;
            else
            {
                o.put(" . ");
                print(o, syms, v, display);
                break;
            }
        }
        o.put(')');
        break;
    }
}

private void writeString(Output o, string s)
{
    o.put('"');
    foreach (c; s)
    {
        switch (c)
        {
        case '\\': o.put("\\\\"); break;
        case '"': o.put("\\\""); break;
        case '\n': o.put("\\n"); break;
        case '\t': o.put("\\t"); break;
        default: o.put(c);
        }
    }
    o.put('"');
}
