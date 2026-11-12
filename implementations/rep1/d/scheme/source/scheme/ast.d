/**
 * The analysed form of a program.
 *
 * Each datum is converted exactly once (by `scheme.analyzer`) into a tree of
 * $(LREF Node)s, which the evaluator then runs without looking at the
 * original s-expressions again.
 */
module scheme.ast;

import scheme.value;

/// What a $(LREF Node) does.
enum NodeKind : ubyte
{
    constant, /// `val`
    ref_, /// variable reference: `sym`
    set, /// `(set! sym a)`
    define, /// `(define sym a)`
    if_, /// `(if a b c)`; `c` is null for a one-armed if
    lambda, /// closure creation from `lambda`
    seq, /// `kids`, the last in tail position
    app, /// application: operator `a`, operands `kids`
    let, /// `syms` bound to `kids`, body `a`
    namedLet, /// name `sym`, procedure `lambda`, inits `kids`
    letrec, /// `syms` bound to `kids` in a fresh frame, body `a`
    and, /// `kids`
    or, /// `kids`
}

/// Parameters and body of a `lambda`.
final class LambdaInfo
{
    /// Parameter names; if `variadic`, the last one collects the extra arguments.
    Symbol[] params;
    /// Number of required parameters.
    size_t required;
    bool variadic;
    Node body_;
}

/// A node of the analysed program tree.
final class Node
{
    NodeKind kind;
    Value val;
    Symbol sym;
    Node a, b, c;
    Node[] kids;
    Symbol[] syms;
    LambdaInfo lambda;

    this(NodeKind kind) pure nothrow @nogc @safe
    {
        this.kind = kind;
    }
}
