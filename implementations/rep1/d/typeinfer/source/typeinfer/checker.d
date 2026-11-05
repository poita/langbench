/**
 * High-level facade: source text in, per-declaration results out.
 */
module typeinfer.checker;

import std.array : Appender, appender;
import typeinfer.ast;
import typeinfer.errors;
import typeinfer.infer;
import typeinfer.lexer;
import typeinfer.parser;
import typeinfer.printer;
import typeinfer.types;

/// The outcome of checking one top-level declaration.
struct DeclResult
{
    /// Kind of declaration (`let`, `let rec` or bare expression).
    DeclKind kind;
    /// Bound name for `let` / `let rec`; empty for a bare expression.
    string name;
    /// `ErrorKind.none` on success, otherwise why it failed.
    ErrorKind error;
    /// The rendered principal type on success; empty on failure.
    string type;

    /// True if the declaration type-checked.
    bool ok() const pure nothrow @safe @nogc { return error == ErrorKind.none; }

    /// The result as one line of output, without the trailing newline.
    string toString() const
    {
        if (!ok)
            return "error: " ~ toText(error);
        return (kind == DeclKind.expr ? "-" : name) ~ " : " ~ type;
    }
}

/**
 * A type checker holding the built-in environment and every binding made by
 * the declarations checked so far. Successive calls to `check` continue in the
 * same top-level environment, like a REPL session.
 */
final class TypeChecker
{
    private Interner names;
    private Inferencer inferencer;

    ///
    this()
    {
        names = new Interner;
        inferencer = new Inferencer;
        installBuiltins();
    }

    /**
     * Check every declaration in `source`, in order.
     *
     * Throws: `SyntaxError` if `source` is malformed (nothing is checked then).
     */
    DeclResult[] check(string source)
    {
        auto program = prepare(source);
        auto results = new DeclResult[program.decls.length];
        auto scratch = appender!(char[]);
        foreach (i, d; program.decls)
        {
            TypeId t;
            auto err = inferencer.inferDecl(d, t);
            results[i].kind = d.kind;
            results[i].error = err;
            if (d.kind != DeclKind.expr)
                results[i].name = names.name(d.name);
            if (err == ErrorKind.none)
            {
                scratch.clear();
                printType(inferencer.store, t, scratch);
                results[i].type = scratch.data.idup;
            }
        }
        return results;
    }

    /**
     * Check `source` and append the program's textual output (one line per
     * declaration, each ending in `'\n'`) to `sink`.
     *
     * Throws: `SyntaxError` if `source` is malformed.
     */
    void format(string source, ref Appender!(char[]) sink)
    {
        auto program = prepare(source);
        foreach (d; program.decls)
        {
            TypeId t;
            auto err = inferencer.inferDecl(d, t);
            if (err != ErrorKind.none)
            {
                sink.put("error: ");
                sink.put(toText(err));
            }
            else
            {
                sink.put(d.kind == DeclKind.expr ? "-" : names.name(d.name));
                sink.put(" : ");
                printType(inferencer.store, t, sink);
            }
            sink.put('\n');
        }
    }

    private Program prepare(string source)
    {
        auto tokens = tokenize(source, names);
        auto program = parse(tokens);
        inferencer.reserveNames(names.length);
        inferencer.load(program);
        return program;
    }

    private void installBuiltins()
    {
        auto s = inferencer.store;
        TypeId gen() { return s.newVar(genericLevel); }
        TypeId fn(TypeId[] ts...)
        {
            auto r = ts[$ - 1];
            foreach_reverse (t; ts[0 .. $ - 1])
                r = s.newArrow(t, r);
            return r;
        }
        void def(string name, TypeId t) { inferencer.define(names.intern(name), t); }

        immutable B = TypeStore.boolType;
        immutable I = TypeStore.intType;
        def("not", fn(B, B));
        {
            auto a = gen(), b = gen();
            def("fst", fn(s.newTuple([a, b]), a));
        }
        {
            auto a = gen(), b = gen();
            def("snd", fn(s.newTuple([a, b]), b));
        }
        {
            auto a = gen();
            def("hd", fn(s.newList(a), a));
        }
        {
            auto a = gen();
            def("tl", fn(s.newList(a), s.newList(a)));
        }
        {
            auto a = gen();
            def("null", fn(s.newList(a), B));
        }
        {
            auto a = gen();
            def("length", fn(s.newList(a), I));
        }
        {
            auto a = gen(), b = gen();
            def("map", fn(fn(a, b), s.newList(a), s.newList(b)));
        }
        {
            auto a = gen(), b = gen();
            def("fold", fn(fn(a, b, a), a, s.newList(b), a));
        }
    }
}

/**
 * Check a whole program in a fresh environment and return its output text:
 * one line per declaration, exactly as the command-line tool prints it.
 *
 * Throws: `SyntaxError` if `source` is malformed.
 */
string inferProgram(string source)
{
    auto sink = appender!(char[]);
    new TypeChecker().format(source, sink);
    return sink.data.idup;
}
