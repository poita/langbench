/// Compiler: converts datums into `Node` trees, once per top-level form.
module scheme.compiler;

import scheme.node;
import scheme.symbols;
import scheme.value;

/// Compiles datums to nodes. Special forms are recognised by the ids in
/// `Known`; they are reserved and never treated as variables.
struct Compiler
{
    /// Compile one top-level datum.
    Node compile(Value d)
    {
        switch (d.tag)
        {
        case Tag.symbol:
        {
            auto n = new Node(Kind.variable);
            n.sym = cast(int) d.i;
            return n;
        }
        case Tag.pair:
            return compilePair(d);
        default:
            return constant(d);
        }
    }

private:
    static Node constant(Value v)
    {
        auto n = new Node(Kind.constant);
        n.val = v;
        return n;
    }

    static Value first(Value v) { return v.tag == Tag.pair ? v.pair.car : Value.nil; }
    static Value rest(Value v) { return v.tag == Tag.pair ? v.pair.cdr : Value.nil; }
    static Value second(Value v) { return first(rest(v)); }

    Node compilePair(Value d)
    {
        Value head = d.pair.car;
        Value args = d.pair.cdr;
        if (head.tag == Tag.symbol && head.i < Known.count)
        {
            switch (cast(Known) head.i)
            {
            case Known.quote:
                return constant(first(args));
            case Known.if_:
            {
                auto n = new Node(Kind.if_);
                n.a = compile(first(args));
                n.b = compile(second(args));
                if (rest(rest(args)).tag == Tag.pair)
                    n.c = compile(first(rest(rest(args))));
                return n;
            }
            case Known.define:
                return compileDefine(args);
            case Known.set:
            {
                auto n = new Node(Kind.set);
                n.sym = cast(int) first(args).i;
                n.a = compile(second(args));
                return n;
            }
            case Known.lambda:
                return compileLambda(first(args), rest(args));
            case Known.let:
                return compileLet(args);
            case Known.letStar:
                return compileLetLike(Kind.letStar, args);
            case Known.letrec:
                return compileLetLike(Kind.letrec, args);
            case Known.begin:
                return compileSeq(args);
            case Known.cond:
                return compileCond(args);
            case Known.and:
                return compileLogic(Kind.and, args);
            case Known.or:
                return compileLogic(Kind.or, args);
            default:
                break;
            }
        }
        auto n = new Node(Kind.app);
        n.a = compile(head);
        n.kids = compileList(args);
        return n;
    }

    Node[] compileList(Value forms)
    {
        Node[] r;
        for (; forms.tag == Tag.pair; forms = forms.pair.cdr)
            r ~= compile(forms.pair.car);
        return r;
    }

    /// A body: one node, wrapping several forms in a `begin`.
    Node compileSeq(Value forms)
    {
        auto kids = compileList(forms);
        if (kids.length == 0)
            return constant(Value.voidValue);
        if (kids.length == 1)
            return kids[0];
        auto n = new Node(Kind.begin);
        n.kids = kids;
        return n;
    }

    Node compileLogic(Kind kind, Value forms)
    {
        auto kids = compileList(forms);
        if (kids.length == 0)
            return constant(Value.boolean(kind == Kind.and));
        if (kids.length == 1)
            return kids[0];
        auto n = new Node(kind);
        n.kids = kids;
        return n;
    }

    Node compileDefine(Value args)
    {
        Value target = first(args);
        auto n = new Node(Kind.define);
        if (target.tag == Tag.pair)
        {
            n.sym = cast(int) target.pair.car.i;
            n.a = compileLambda(target.pair.cdr, rest(args));
        }
        else
        {
            n.sym = cast(int) target.i;
            n.a = rest(args).tag == Tag.pair ? compile(second(args)) : constant(Value.voidValue);
        }
        return n;
    }

    Proc makeProc(Value params, Value body)
    {
        auto p = new Proc;
        int[] ids;
        for (; params.tag == Tag.pair; params = params.pair.cdr)
            ids ~= cast(int) params.pair.car.i;
        p.nfixed = cast(int) ids.length;
        if (params.tag == Tag.symbol)
        {
            ids ~= cast(int) params.i;
            p.rest = true;
        }
        p.ids = ids;
        p.body = compileSeq(body);
        return p;
    }

    Node compileLambda(Value params, Value body)
    {
        auto n = new Node(Kind.lambda);
        n.proc = makeProc(params, body);
        return n;
    }

    void compileBindings(Value bindings, ref int[] names, ref Node[] inits)
    {
        for (; bindings.tag == Tag.pair; bindings = bindings.pair.cdr)
        {
            Value b = bindings.pair.car;
            names ~= cast(int) first(b).i;
            inits ~= rest(b).tag == Tag.pair ? compile(second(b)) : constant(Value.voidValue);
        }
    }

    Node compileLet(Value args)
    {
        if (first(args).tag == Tag.symbol)
        {
            // named let
            auto n = new Node(Kind.namedLet);
            n.names = [cast(int) first(args).i];
            Value bindings = second(args);
            int[] params;
            compileBindings(bindings, params, n.inits);
            auto p = new Proc;
            p.ids = params;
            p.nfixed = cast(int) params.length;
            p.body = compileSeq(rest(rest(args)));
            n.proc = p;
            return n;
        }
        return compileLetLike(Kind.let, args);
    }

    Node compileLetLike(Kind kind, Value args)
    {
        auto n = new Node(kind);
        compileBindings(first(args), n.names, n.inits);
        n.body = compileSeq(rest(args));
        return n;
    }

    Node compileCond(Value clauses)
    {
        auto n = new Node(Kind.cond);
        for (; clauses.tag == Tag.pair; clauses = clauses.pair.cdr)
        {
            Value cl = clauses.pair.car;
            Clause c;
            Value test = first(cl);
            if (test.tag == Tag.symbol && test.i == Known.else_)
                c.isElse = true;
            else
                c.test = compile(test);
            if (rest(cl).tag == Tag.pair)
                c.body = compileSeq(rest(cl));
            n.clauses ~= c;
        }
        return n;
    }
}
