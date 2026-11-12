/**
 * The analyzer: datums to `Node` trees.
 *
 * Every form (including every `lambda` body) is analysed exactly once, before
 * it first runs. `cond`, `let*` and one-armed `if` are lowered to simpler
 * nodes here, keeping tail positions intact.
 */
module scheme.analyzer;

import scheme.ast;
import scheme.value;

/// Converts datums into analysed `Node` trees.
final class Analyzer
{
    private SymbolTable symbols;

    this(SymbolTable symbols)
    {
        this.symbols = symbols;
    }

    /// Analyse one top-level datum. Throws `SyntaxError` for malformed special forms.
    Node analyze(Value x)
    {
        switch (x.kind)
        {
        case Kind.symbol:
            auto n = new Node(NodeKind.ref_);
            n.sym = x.sym;
            return n;
        case Kind.pair:
            return analyzePair(x);
        default:
            return constant(x);
        }
    }

    private static Node constant(Value v)
    {
        auto n = new Node(NodeKind.constant);
        n.val = v;
        return n;
    }

    private static Value[] toArray(Value list)
    {
        Value[] r;
        while (list.kind == Kind.pair)
        {
            r ~= list.pair.car;
            list = list.pair.cdr;
        }
        if (list.kind != Kind.nil)
            throw new SyntaxError("improper list in special form");
        return r;
    }

    private static Symbol asSymbol(Value v)
    {
        if (v.kind != Kind.symbol)
            throw new SyntaxError("expected a symbol");
        return v.sym;
    }

    private static void need(bool ok, string what)
    {
        if (!ok)
            throw new SyntaxError("malformed " ~ what);
    }

    private Node analyzePair(Value x)
    {
        Value head = x.pair.car;
        if (head.kind == Kind.symbol && head.sym.special != SpecialForm.none)
        {
            auto parts = toArray(x.pair.cdr);
            final switch (head.sym.special)
            {
            case SpecialForm.quote:
                need(parts.length == 1, "quote");
                return constant(parts[0]);
            case SpecialForm.if_:
                need(parts.length == 2 || parts.length == 3, "if");
                auto n = new Node(NodeKind.if_);
                n.a = analyze(parts[0]);
                n.b = analyze(parts[1]);
                if (parts.length == 3)
                    n.c = analyze(parts[2]);
                return n;
            case SpecialForm.define:
                return analyzeDefine(parts);
            case SpecialForm.set:
                need(parts.length == 2, "set!");
                auto n = new Node(NodeKind.set);
                n.sym = asSymbol(parts[0]);
                n.a = analyze(parts[1]);
                return n;
            case SpecialForm.lambda:
                need(parts.length >= 2, "lambda");
                return makeLambda(parts[0], parts[1 .. $]);
            case SpecialForm.let:
                return analyzeLet(parts);
            case SpecialForm.letStar:
                return analyzeLetStar(parts);
            case SpecialForm.letrec:
                need(parts.length >= 2, "letrec");
                Symbol[] names;
                Node[] inits;
                bindings(parts[0], names, inits);
                auto n = new Node(NodeKind.letrec);
                n.syms = names;
                n.kids = inits;
                n.a = body_(parts[1 .. $]);
                return n;
            case SpecialForm.begin:
                need(parts.length >= 1, "begin");
                return body_(parts);
            case SpecialForm.cond:
                return analyzeCond(parts);
            case SpecialForm.and:
                return analyzeJunction(NodeKind.and, parts);
            case SpecialForm.or:
                return analyzeJunction(NodeKind.or, parts);
            case SpecialForm.else_:
                throw new SyntaxError("else outside cond");
            case SpecialForm.none:
                assert(false);
            }
        }
        auto n = new Node(NodeKind.app);
        n.a = analyze(head);
        foreach (operand; toArray(x.pair.cdr))
            n.kids ~= analyze(operand);
        return n;
    }

    private Node body_(Value[] forms)
    {
        need(forms.length >= 1, "body");
        if (forms.length == 1)
            return analyze(forms[0]);
        auto n = new Node(NodeKind.seq);
        foreach (f; forms)
            n.kids ~= analyze(f);
        return n;
    }

    private Node makeLambda(Value params, Value[] bodyForms)
    {
        auto info = new LambdaInfo;
        Value p = params;
        while (p.kind == Kind.pair)
        {
            info.params ~= asSymbol(p.pair.car);
            p = p.pair.cdr;
        }
        info.required = info.params.length;
        if (p.kind == Kind.symbol)
        {
            info.params ~= p.sym;
            info.variadic = true;
        }
        else
            need(p.kind == Kind.nil, "parameter list");
        info.body_ = body_(bodyForms);
        auto n = new Node(NodeKind.lambda);
        n.lambda = info;
        return n;
    }

    private Node analyzeDefine(Value[] parts)
    {
        need(parts.length >= 2, "define");
        auto n = new Node(NodeKind.define);
        if (parts[0].kind == Kind.pair)
        {
            // (define (name . params) body...)
            n.sym = asSymbol(parts[0].pair.car);
            n.a = makeLambda(parts[0].pair.cdr, parts[1 .. $]);
        }
        else
        {
            need(parts.length == 2, "define");
            n.sym = asSymbol(parts[0]);
            n.a = analyze(parts[1]);
        }
        return n;
    }

    private void bindings(Value list, out Symbol[] names, out Node[] inits)
    {
        foreach (b; toArray(list))
        {
            auto pr = toArray(b);
            need(pr.length == 2, "binding");
            names ~= asSymbol(pr[0]);
            inits ~= analyze(pr[1]);
        }
    }

    private Node analyzeLet(Value[] parts)
    {
        need(parts.length >= 2, "let");
        if (parts[0].kind == Kind.symbol)
        {
            need(parts.length >= 3, "named let");
            Symbol[] names;
            Node[] inits;
            bindings(parts[1], names, inits);
            auto info = new LambdaInfo;
            info.params = names;
            info.required = names.length;
            info.body_ = body_(parts[2 .. $]);
            auto n = new Node(NodeKind.namedLet);
            n.sym = parts[0].sym;
            n.lambda = info;
            n.kids = inits;
            return n;
        }
        Symbol[] names;
        Node[] inits;
        bindings(parts[0], names, inits);
        auto n = new Node(NodeKind.let);
        n.syms = names;
        n.kids = inits;
        n.a = body_(parts[1 .. $]);
        return n;
    }

    private Node analyzeLetStar(Value[] parts)
    {
        need(parts.length >= 2, "let*");
        Symbol[] names;
        Node[] inits;
        bindings(parts[0], names, inits);
        Node inner = body_(parts[1 .. $]);
        if (names.length == 0)
        {
            auto n = new Node(NodeKind.let);
            n.a = inner;
            return n;
        }
        foreach_reverse (i; 0 .. names.length)
        {
            auto n = new Node(NodeKind.let);
            n.syms = [names[i]];
            n.kids = [inits[i]];
            n.a = inner;
            inner = n;
        }
        return inner;
    }

    private Node analyzeJunction(NodeKind kind, Value[] parts)
    {
        if (parts.length == 0)
            return constant(Value.fromBool(kind == NodeKind.and));
        if (parts.length == 1)
            return analyze(parts[0]);
        auto n = new Node(kind);
        foreach (p; parts)
            n.kids ~= analyze(p);
        return n;
    }

    /// `(cond c1 c2 ...)` becomes nested `if`/`or` nodes, built from the last clause.
    private Node analyzeCond(Value[] clauses)
    {
        Node rest = constant(Value.void_());
        foreach_reverse (clause; clauses)
        {
            auto items = toArray(clause);
            need(items.length >= 1, "cond clause");
            if (items[0].kind == Kind.symbol && items[0].sym.special == SpecialForm.else_)
            {
                rest = body_(items[1 .. $]);
                continue;
            }
            auto test = analyze(items[0]);
            if (items.length == 1)
            {
                auto n = new Node(NodeKind.or);
                n.kids = [test, rest];
                rest = n;
            }
            else
            {
                auto n = new Node(NodeKind.if_);
                n.a = test;
                n.b = body_(items[1 .. $]);
                n.c = rest;
                rest = n;
            }
        }
        return rest;
    }
}
